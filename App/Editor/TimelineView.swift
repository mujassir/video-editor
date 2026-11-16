import UIKit
import SwiftUI
import EditorKit

/// UIKit timeline: fixed centre playhead, scrolling tracks, filmstrip thumbnails,
/// waveforms, trim handles and pinch-to-zoom. UIKit keeps scrolling at 120 Hz
/// on ProMotion displays even with long edits.
final class TimelineUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    struct Layout {
        static let rulerHeight: CGFloat = 18
        static let mainTop: CGFloat = 24
        static let mainHeight: CGFloat = 58
        static let textTop: CGFloat = 90
        static let laneHeight: CGFloat = 24
        static let captionTop: CGFloat = 118
        static let audioTop: CGFloat = 146
        static let audioHeight: CGFloat = 30
    }

    var onScrub: ((MediaTime) -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSelect: ((EditSession.Selection) -> Void)?
    var onTrim: ((UUID, Project.TrimEdge, MediaTime, UIGestureRecognizer.State) -> Void)?
    var onTransitionTap: ((UUID) -> Void)?
    var onAddMedia: (() -> Void)?
    /// A music / audio bar was dragged to a new timeline start.
    var onAudioMove: ((UUID, MediaTime) -> Void)?
    /// A main-track clip was dragged and dropped at a new index (TML-13).
    var onClipDrop: ((UUID, Int) -> Void)?
    fileprivate var reorderHold: UILongPressGestureRecognizer!
    fileprivate let reorderBand = UIView()
    fileprivate let reorderStrip = UIView()
    fileprivate var reorder: ReorderState?
    fileprivate var autoScrollLink: CADisplayLink?
    private var audioDragOrigin: CGFloat = 0

    private let scrollView = TimelineScrollView()
    private let content = UIView()
    private let ruler = RulerView()
    private let playhead = UIView()
    private let addButton = UIButton(type: .system)
    private var clipViews: [UUID: ClipStripView] = [:]
    private var overlayViews: [UIView] = []
    private let selectionView = SelectionFrameView()

    private(set) var pointsPerSecond: CGFloat = 64
    private var project: Project?
    private var layout: TimelineLayout?
    private var selection: EditSession.Selection = .none
    private var revision = -1
    private var waveformVersion = -1
    private var waveforms: [UUID: [Float]] = [:]
    private var thumbnails: ThumbnailProvider?
    private var resolver: MediaResolver?
    private var isProgrammaticScroll = false
    private var pinchStartPPS: CGFloat = 64
    private var trimClipID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.background)
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .normal
        scrollView.accessibilityIdentifier = "timeline"
        addSubview(scrollView)
        scrollView.addSubview(content)
        content.addSubview(ruler)

        playhead.backgroundColor = .white
        playhead.layer.cornerRadius = 1
        playhead.layer.shadowColor = UIColor.black.cgColor
        playhead.layer.shadowOpacity = 0.6
        playhead.layer.shadowRadius = 2
        playhead.isUserInteractionEnabled = false
        addSubview(playhead)

        addButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)), for: .normal)
        addButton.tintColor = .black
        addButton.backgroundColor = .white
        addButton.layer.cornerRadius = 8
        addButton.accessibilityIdentifier = "timeline.add"
        addButton.addAction(UIAction { [weak self] _ in self?.onAddMedia?() }, for: .touchUpInside)
        content.addSubview(addButton)

        selectionView.isHidden = true
        content.addSubview(selectionView)
        selectionView.onTrim = { [weak self] edge, translation, state in
            guard let self, let id = self.trimClipID else { return }
            let delta = MediaTime(seconds: Double(translation / self.pointsPerSecond))
            self.onTrim?(id, edge, delta, state)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        // Press and hold a clip, then drag, to reorder it in a thumbnail strip (TML-13).
        reorderHold = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
        reorderHold.minimumPressDuration = 0.3
        reorderHold.delegate = self
        scrollView.addGestureRecognizer(reorderHold)
        tap.require(toFail: reorderHold)
        reorderBand.backgroundColor = UIColor(Theme.background)
        reorderBand.isHidden = true
        reorderBand.accessibilityIdentifier = "reorder.strip"
        reorderBand.addSubview(reorderStrip)
        addSubview(reorderBand)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Updates from the model

    func update(project: Project, revision: Int, selection: EditSession.Selection, time: MediaTime,
                waveforms: [UUID: [Float]], waveformVersion: Int, thumbnails: ThumbnailProvider, resolver: MediaResolver,
                followPlayhead: Bool) {
        self.thumbnails = thumbnails
        self.resolver = resolver
        let structureChanged = revision != self.revision || waveformVersion != self.waveformVersion
        let selectionChanged = selection != self.selection
        self.project = project
        self.selection = selection
        self.waveforms = waveforms
        if structureChanged {
            self.revision = revision
            self.waveformVersion = waveformVersion
            self.layout = project.layout
            rebuild()
        } else if selectionChanged {
            layoutSelection()
            updateHighlights()
        }
        if followPlayhead { scroll(to: time) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let inset = bounds.width / 2
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        playhead.frame = CGRect(x: bounds.midX - 1, y: 4, width: 2, height: bounds.height - 8)
        rebuild()
    }

    private func x(for time: MediaTime) -> CGFloat { CGFloat(time.seconds) * pointsPerSecond }

    func scroll(to time: MediaTime) {
        guard !scrollView.isTracking, !scrollView.isDecelerating else { return }
        isProgrammaticScroll = true
        scrollView.contentOffset = CGPoint(x: x(for: time) - scrollView.contentInset.left, y: 0)
        isProgrammaticScroll = false
    }

    var timeAtPlayhead: MediaTime {
        MediaTime(seconds: Double(max(0, (scrollView.contentOffset.x + scrollView.contentInset.left) / pointsPerSecond)))
    }

    // MARK: Layout

    private func rebuild() {
        guard let project, let layout else { return }
        // Music longer than the video is shown in full; the part past the video end is dimmed.
        let videoEnd = project.duration
        let width = max(x(for: project.timelineDuration), 1)
        let audioLanes = (project.audioClips.map(\.lane).max() ?? -1) + 1
        let height = max(bounds.height, Layout.audioTop + CGFloat(max(audioLanes, 1)) * (Layout.audioHeight + 4) + 8)
        content.frame = CGRect(x: 0, y: 0, width: width + 80, height: height)
        scrollView.contentSize = CGSize(width: width, height: bounds.height)
        ruler.frame = CGRect(x: 0, y: 0, width: width, height: Layout.rulerHeight)
        ruler.pointsPerSecond = pointsPerSecond
        ruler.duration = project.timelineDuration.seconds
        ruler.setNeedsDisplay()
        addButton.frame = CGRect(x: max(x(for: layout.duration), 1) + 12, y: Layout.mainTop + 13, width: 32, height: 32)

        // Main-track clips (reuse views by id).
        var seen = Set<UUID>()
        for entry in layout.entries {
            let clip = project.clips[entry.index]
            seen.insert(clip.id)
            let view = clipViews[clip.id] ?? {
                let v = ClipStripView()
                content.insertSubview(v, belowSubview: selectionView)
                clipViews[clip.id] = v
                return v
            }()
            let frame = CGRect(x: x(for: entry.range.start) + 1, y: Layout.mainTop,
                               width: max(4, x(for: entry.range.duration) - 2), height: Layout.mainHeight)
            view.accessibilityIdentifier = "clip.\(entry.index)"
            view.configure(clip: clip, media: project.mediaItem(clip.mediaID), frame: frame,
                           pointsPerSecond: pointsPerSecond, thumbnails: thumbnails, resolver: resolver)
        }
        for (id, view) in clipViews where !seen.contains(id) {
            view.removeFromSuperview()
            clipViews[id] = nil
        }

        // Overlay rows are cheap: rebuild them.
        overlayViews.forEach { $0.removeFromSuperview() }
        overlayViews.removeAll()

        // Transition buttons at each cut.
        for entry in layout.entries.dropLast() {
            let clip = project.clips[entry.index]
            let cutX = x(for: entry.range.end - MediaTime(ticks: entry.overlapOut.ticks / 2))
            let b = UIButton(type: .custom)
            let symbol = clip.transitionOut == nil ? "square.split.2x1" : "sparkles.rectangle.stack.fill"
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)), for: .normal)
            b.tintColor = clip.transitionOut == nil ? .black : .white
            b.backgroundColor = clip.transitionOut == nil ? .white : UIColor(Theme.accent)
            b.layer.cornerRadius = 5
            b.frame = CGRect(x: cutX - 11, y: Layout.mainTop + Layout.mainHeight / 2 - 11, width: 22, height: 22)
            b.accessibilityIdentifier = "transition.\(entry.index)"
            let id = clip.id
            b.addAction(UIAction { [weak self] _ in self?.onTransitionTap?(id) }, for: .touchUpInside)
            content.addSubview(b)
            overlayViews.append(b)
        }

        for (i, text) in project.textOverlays.enumerated() {
            let v = LabelBar(color: UIColor(Theme.clipText), title: text.text, systemImage: "textformat")
            v.frame = CGRect(x: x(for: text.range.start), y: Layout.textTop, width: max(8, x(for: text.range.duration)), height: Layout.laneHeight)
            v.accessibilityIdentifier = "text.\(i)"
            v.tag = 1
            content.addSubview(v)
            overlayViews.append(v)
        }

        if !project.captions.segments.isEmpty {
            for (i, seg) in project.captions.segments.enumerated() {
                let v = LabelBar(color: UIColor(Theme.clipCaption), title: seg.text, systemImage: nil)
                v.frame = CGRect(x: x(for: seg.range.start), y: Layout.captionTop, width: max(6, x(for: seg.range.duration)), height: Layout.laneHeight)
                v.accessibilityIdentifier = "caption.\(i)"
                content.addSubview(v)
                overlayViews.append(v)
            }
        }

        for (i, audio) in project.audioClips.enumerated() {
            let v = AudioBarView()
            let peaks = waveforms[audio.mediaID] ?? []
            let mediaDuration = project.mediaItem(audio.mediaID)?.duration.seconds ?? audio.sourceRange.duration.seconds
            v.configure(clip: audio, peaks: peaks, mediaDuration: mediaDuration, pointsPerSecond: pointsPerSecond,
                        exportedSeconds: max(0, (videoEnd - audio.start).seconds))
            v.frame = CGRect(x: x(for: audio.start), y: Layout.audioTop + CGFloat(audio.lane) * (Layout.audioHeight + 4),
                             width: max(8, x(for: audio.timelineRange.duration)), height: Layout.audioHeight)
            v.accessibilityIdentifier = "audio.\(i)"
            v.clipID = audio.id
            // Press and hold, then slide, to move the track. Quick swipes still scroll.
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleAudioDrag(_:)))
            hold.minimumPressDuration = 0.25
            hold.allowableMovement = .greatestFiniteMagnitude
            v.addGestureRecognizer(hold)
            content.addSubview(v)
            overlayViews.append(v)
        }
        content.bringSubviewToFront(selectionView)
        layoutSelection()
        updateHighlights()
    }

    private func layoutSelection() {
        guard case .clip(let id) = selection, let layout, let entry = layout.entry(for: id) else {
            selectionView.isHidden = true
            trimClipID = nil
            return
        }
        trimClipID = id
        selectionView.isHidden = false
        selectionView.frame = CGRect(x: x(for: entry.range.start) - SelectionFrameView.handleWidth, y: Layout.mainTop - 2,
                                     width: x(for: entry.range.duration) + SelectionFrameView.handleWidth * 2,
                                     height: Layout.mainHeight + 4)
        selectionView.setNeedsLayout()
    }

    private func updateHighlights() {
        guard let project else { return }
        for v in overlayViews {
            guard let bar = v as? LabelBar, let ident = bar.accessibilityIdentifier else { continue }
            var selected = false
            if ident.hasPrefix("text."), case .text(let id) = selection,
               let i = Int(ident.dropFirst(5)), i < project.textOverlays.count { selected = project.textOverlays[i].id == id }
            if ident.hasPrefix("caption."), case .captions = selection { selected = true }
            bar.isSelectedBar = selected
        }
        for v in overlayViews {
            guard let bar = v as? AudioBarView, let ident = bar.accessibilityIdentifier,
                  let i = Int(ident.dropFirst(6)), i < project.audioClips.count else { continue }
            if case .audio(let id) = selection { bar.isSelectedBar = project.audioClips[i].id == id } else { bar.isSelectedBar = false }
        }
    }

    // MARK: Gestures

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isProgrammaticScroll, scrollView.isTracking || scrollView.isDecelerating || scrollView.isDragging else { return }
        onScrub?(timeAtPlayhead)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onScrubEnded?() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onScrubEnded?() }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let project, let layout else { return }
        let p = g.location(in: content)
        let time = MediaTime(seconds: Double(p.x / pointsPerSecond))
        if p.y >= Layout.mainTop, p.y <= Layout.mainTop + Layout.mainHeight, let entry = layout.entry(at: time) {
            let id = project.clips[entry.index].id
            onSelect?(selection == .clip(id) ? .none : .clip(id))
            return
        }
        if p.y >= Layout.textTop, p.y < Layout.textTop + Layout.laneHeight,
           let t = project.textOverlays.last(where: { $0.range.contains(time) }) {
            onSelect?(.text(t.id)); return
        }
        if p.y >= Layout.captionTop, p.y < Layout.captionTop + Layout.laneHeight, !project.captions.segments.isEmpty {
            onSelect?(.captions); return
        }
        if p.y >= Layout.audioTop {
            let lane = Int((p.y - Layout.audioTop) / (Layout.audioHeight + 4))
            if let a = project.audioClips.first(where: { $0.lane == lane && $0.timelineRange.contains(time) }) {
                onSelect?(.audio(a.id)); return
            }
        }
        onSelect?(.none)
    }

    /// Moves the bar visually while dragging (no edits mid-gesture, so the view isn't
    /// rebuilt under the finger), then reports the new start once on release.
    @objc private func handleAudioDrag(_ g: UILongPressGestureRecognizer) {
        guard let bar = g.view as? AudioBarView, let id = bar.clipID else { return }
        let x = g.location(in: content).x
        scrollView.accessibilityValue = "audioDrag state=\(g.state.rawValue) x=\(Int(x)) bar=\(Int(bar.frame.minX))"
        switch g.state {
        case .began:
            scrollView.isDraggingItem = true
            scrollView.panGestureRecognizer.isEnabled = false   // cancel any pan that already started
            scrollView.panGestureRecognizer.isEnabled = true
            audioDragOrigin = x - bar.frame.minX
            onSelect?(.audio(id))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            bar.alpha = 0.85
            bar.transform = CGAffineTransform(scaleX: 1, y: 1.08)
        case .changed:
            bar.frame.origin.x = max(0, x - audioDragOrigin)
        case .ended:
            scrollView.isDraggingItem = false
            bar.alpha = 1
            bar.transform = .identity
            let start = MediaTime(seconds: Double(max(0, bar.frame.minX) / pointsPerSecond))
            onAudioMove?(id, start.snappedToFrame(fps: 30))
        default:
            scrollView.isDraggingItem = false
            bar.alpha = 1
            bar.transform = .identity
            rebuild()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Let buttons (transitions, add) handle their own taps.
        !(touch.view is UIButton) && !(touch.view is TrimHandle)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStartPPS = pointsPerSecond
        case .changed:
            let time = timeAtPlayhead
            pointsPerSecond = min(400, max(12, pinchStartPPS * g.scale))
            rebuild()
            isProgrammaticScroll = true
            scrollView.contentOffset.x = x(for: time) - scrollView.contentInset.left
            isProgrammaticScroll = false
        default: break
        }
    }
}

// MARK: - Drag to reorder (TML-13)

/// One drag in the thumbnail strip. `slot` is the landing index after removing the clip.
fileprivate final class ReorderState {
    let clipID: UUID
    let originalIndex: Int
    let movable: Range<Int>
    let count: Int
    var others: [UUID]                 // every other clip, in project order
    var tiles: [UUID: UIView] = [:]
    var lifted: UIView!
    var stripStart: CGFloat = 0        // strip's left edge, in the timeline view
    var fingerX: CGFloat = 0
    var slot: Int

    init(clipID: UUID, project: Project) {
        self.clipID = clipID
        originalIndex = project.clipIndex(clipID) ?? 0
        movable = project.movableClipIndices
        count = project.clips.count
        others = project.clips.map(\.id).filter { $0 != clipID }
        slot = originalIndex
    }
}

extension TimelineUIView {
    static let autoScrollEdge: CGFloat = 60
    static let autoScrollMaxSpeed: CGFloat = 600   // pt/s
    private static let tile = CGFloat(ReorderStrip.tileSize)
    private static let liftScale: CGFloat = 1.25

    /// The draggable main-track clip under `point` (content coordinates); slides can't be dragged.
    fileprivate func movableClip(at point: CGPoint) -> VideoClip? {
        guard let project, let layout, point.y >= Layout.mainTop, point.y <= Layout.mainTop + Layout.mainHeight,
              let entry = layout.entry(at: MediaTime(seconds: Double(point.x / pointsPerSecond))) else { return nil }
        let clip = project.clips[entry.index]
        return project.canReorder(clip.id) ? clip : nil
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === reorderHold { return movableClip(at: g.location(in: content)) != nil }
        return super.gestureRecognizerShouldBegin(g)
    }

    @objc fileprivate func handleReorder(_ g: UILongPressGestureRecognizer) {
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            guard let clip = movableClip(at: g.location(in: content)) else { return }
            scrollView.isDraggingItem = true
            scrollView.panGestureRecognizer.isEnabled = false   // cancel any pan that already started
            scrollView.panGestureRecognizer.isEnabled = true
            beginReorder(clip, fingerX: x)
        case .changed:
            reorder?.fingerX = x
            updateReorder()
            updateAutoScroll()
        case .ended:
            endReorder(commit: true)
        default:
            endReorder(commit: false)
        }
    }

    private func makeTile(for clip: VideoClip, project: Project) -> UIView {
        let t = Self.tile
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: t, height: t))
        wrapper.layer.shadowColor = UIColor.black.cgColor
        wrapper.layer.shadowOpacity = 0
        wrapper.layer.shadowRadius = 8
        wrapper.layer.shadowOffset = CGSize(width: 0, height: 4)
        let image = UIImageView(frame: wrapper.bounds)
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 8
        image.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        image.layer.borderWidth = 1
        image.backgroundColor = UIColor(Theme.clipVideo).withAlphaComponent(0.35)
        if let cg = clipViews[clip.id]?.representativeImage { image.image = UIImage(cgImage: cg) }
        wrapper.addSubview(image)
        if clip.titleCard != nil { wrapper.alpha = 0.5 }
        // A sharper frame from the middle of the clip (the timeline's filmstrip is small).
        if let media = project.mediaItem(clip.mediaID), let resolver, let thumbnails {
            let url = resolver.url(for: media)
            if media.kind == .photo {
                if let cg = MediaImporter.loadImage(url, maxPixelSize: 320) { image.image = UIImage(cgImage: cg) }
            } else {
                let mid = clip.sourceTime(atClipTime: MediaTime(seconds: clip.timelineDuration.seconds / 2))
                Task { @MainActor [weak image] in
                    let images = await thumbnails.thumbnails(url, times: [mid], height: 320)
                    if let cg = images[mid] { image?.image = UIImage(cgImage: cg) }
                }
            }
        }
        return wrapper
    }

    private var bandMidY: CGFloat { reorderBand.bounds.midY }

    private func clampedStripStart(_ start: CGFloat, count: Int) -> CGFloat {
        let width = CGFloat(ReorderStrip.width(count: count))
        return min(bounds.width / 2, max(bounds.width / 2 - width, start))
    }

    private func beginReorder(_ clip: VideoClip, fingerX: CGFloat) {
        guard let project else { return }
        let state = ReorderState(clipID: clip.id, project: project)
        reorder = state
        reorderBand.frame = CGRect(x: 0, y: Layout.mainTop - 8, width: bounds.width, height: Layout.mainHeight + 16)
        reorderBand.isHidden = false
        reorderStrip.subviews.forEach { $0.removeFromSuperview() }
        reorderBand.subviews.filter { $0 !== reorderStrip }.forEach { $0.removeFromSuperview() }
        for c in project.clips {
            let tile = makeTile(for: c, project: project)
            if c.id == clip.id {
                tile.accessibilityIdentifier = "reorder.lifted"
                state.lifted = tile
            } else {
                state.tiles[c.id] = tile
                reorderStrip.addSubview(tile)
            }
        }
        reorderBand.addSubview(state.lifted)
        state.fingerX = fingerX
        let pickedCentre = CGFloat(ReorderStrip.tileX(state.originalIndex)) + Self.tile / 2
        state.stripStart = clampedStripStart(fingerX - pickedCentre, count: state.count)
        layoutStrip(animated: false)
        state.lifted.center = CGPoint(x: state.stripStart + pickedCentre, y: bandMidY)
        // Lift: grow, shadow, then glide under the finger.
        UIView.animate(withDuration: 0.2) {
            self.scrollView.alpha = 0.4
            self.playhead.alpha = 0
            state.lifted.transform = CGAffineTransform(scaleX: Self.liftScale, y: Self.liftScale)
            state.lifted.layer.shadowOpacity = 0.6
            state.lifted.center = CGPoint(x: fingerX, y: self.bandMidY - 2)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Places the other tiles around the gap at `slot`; the strip itself moves with auto-scroll.
    private func layoutStrip(animated: Bool) {
        guard let state = reorder else { return }
        reorderStrip.frame = CGRect(x: state.stripStart, y: 0, width: CGFloat(ReorderStrip.width(count: state.count)),
                                    height: reorderBand.bounds.height)
        let place = {
            for (k, id) in state.others.enumerated() {
                let slot = k < state.slot ? k : k + 1
                state.tiles[id]?.center = CGPoint(x: CGFloat(ReorderStrip.tileX(slot)) + Self.tile / 2, y: self.bandMidY)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: place)
        } else {
            place()
        }
    }

    private func updateReorder() {
        guard let state = reorder else { return }
        state.lifted.center = CGPoint(x: state.fingerX, y: bandMidY - 2)
        reorderStrip.frame.origin.x = state.stripStart
        let slot = ReorderStrip.slot(centreX: Double(state.fingerX - state.stripStart), movable: state.movable)
        guard slot != state.slot else { return }
        state.slot = slot
        UISelectionFeedbackGenerator().selectionChanged()
        layoutStrip(animated: true)
    }

    /// Scrolls the strip while the finger is within `autoScrollEdge` of either side, faster nearer the edge.
    private func updateAutoScroll() {
        guard let state = reorder,
              state.fingerX < Self.autoScrollEdge || state.fingerX > bounds.width - Self.autoScrollEdge else {
            autoScrollLink?.invalidate()
            autoScrollLink = nil
            return
        }
        guard autoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
        link.add(to: .main, forMode: .common)
        autoScrollLink = link
    }

    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard let state = reorder else { return }
        let edge = Self.autoScrollEdge
        let x = state.fingerX
        let depth = x < edge ? (edge - x) / edge : -(x - (bounds.width - edge)) / edge
        let speed = max(-1, min(1, depth)) * Self.autoScrollMaxSpeed
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        state.stripStart = clampedStripStart(state.stripStart + speed * dt, count: state.count)
        updateReorder()
    }

    private func endReorder(commit: Bool) {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        scrollView.isDraggingItem = false
        guard let state = reorder else { return }
        reorder = nil
        let slot = commit ? state.slot : state.originalIndex
        if !commit { state.slot = slot }
        let landing = CGPoint(x: state.stripStart + CGFloat(ReorderStrip.tileX(slot)) + Self.tile / 2, y: bandMidY)
        UIView.animate(withDuration: 0.18, animations: {
            state.lifted.transform = .identity
            state.lifted.layer.shadowOpacity = 0
            state.lifted.center = landing
        }, completion: { _ in
            UIView.animate(withDuration: 0.15, animations: {
                self.scrollView.alpha = 1
                self.playhead.alpha = 1
                self.reorderBand.alpha = 0
            }, completion: { _ in
                self.reorderBand.isHidden = true
                self.reorderBand.alpha = 1
            })
            if commit, slot != state.originalIndex { self.onClipDrop?(state.clipID, slot) }
        })
    }
}

// MARK: - Subviews

final class RulerView: UIView {
    var pointsPerSecond: CGFloat = 64
    var duration: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let step: Double = pointsPerSecond > 120 ? 0.5 : (pointsPerSecond > 40 ? 1 : (pointsPerSecond > 18 ? 2 : 5))
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                                                    .foregroundColor: UIColor.white.withAlphaComponent(0.45)]
        var t = 0.0
        while t <= duration + 0.001 {
            let x = CGFloat(t) * pointsPerSecond
            if x >= rect.minX - 40 && x <= rect.maxX + 40 {
                let isMajor = Int((t / step).rounded()) % 2 == 0
                UIColor.white.withAlphaComponent(isMajor ? 0.35 : 0.18).setFill()
                UIRectFill(CGRect(x: x, y: isMajor ? 10 : 13, width: 1, height: isMajor ? 8 : 5))
                if isMajor {
                    let label = t < 60 ? String(format: "%.0fs", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                    (label as NSString).draw(at: CGPoint(x: x + 2, y: 0), withAttributes: attrs)
                }
            }
            t += step
        }
    }
}

final class ClipStripView: UIView {
    private var tiles: [CALayer] = []
    /// The frame from the middle of the filmstrip, for the reorder strip (TML-13).
    var representativeImage: CGImage? {
        guard !tiles.isEmpty, let c = tiles[tiles.count / 2].contents else { return nil }
        return (c as! CGImage)
    }
    private let badge = UILabel()
    private var configuredKey = ""
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.masksToBounds = true
        backgroundColor = UIColor(Theme.clipVideo).withAlphaComponent(0.35)
        isAccessibilityElement = true
        accessibilityTraits = .button
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badge.layer.cornerRadius = 3
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(clip: VideoClip, media: MediaItem?, frame: CGRect, pointsPerSecond: CGFloat,
                   thumbnails: ThumbnailProvider?, resolver: MediaResolver?) {
        self.frame = frame
        var badges: [String] = []
        if clip.speed != 1 { badges.append(String(format: "%.1g×", clip.speed)) }
        if clip.isReversed { badges.append("◀︎") }
        if clip.freezeAt != nil { badges.append("❄︎") }
        if let motion = clip.photoMotion, motion != .none { badges.append("↗︎") }
        if let anim = clip.animation, !anim.isEmpty { badges.append("✦") }
        if clip.filter != nil { badges.append("FX") }
        if clip.backgroundRemoval != nil { badges.append("BG") }
        if !clip.reframe.isEmpty { badges.append("⌖") }
        if clip.isMuted { badges.append("🔇") }
        badge.text = badges.isEmpty ? nil : " " + badges.joined(separator: " ") + " "
        badge.isHidden = badges.isEmpty
        badge.sizeToFit()
        badge.frame.origin = CGPoint(x: 4, y: bounds.height - badge.frame.height - 4)
        accessibilityLabel = "Clip \(media?.displayName ?? "")"

        guard let media, let thumbnails, let resolver else { return }
        let tileWidth = bounds.height * CGFloat(max(0.5, min(2, media.naturalSize.width / max(media.naturalSize.height, 1))))
        let count = max(1, Int(ceil(bounds.width / tileWidth)))
        let key = "\(clip.sourceRange)-\(clip.speed)-\(clip.isReversed)-\(clip.freezeAt?.ticks ?? -1)-\(count)-\(Int(bounds.width))"
        guard key != configuredKey else { return }
        configuredKey = key
        tiles.forEach { $0.removeFromSuperlayer() }
        tiles = (0..<count).map { i in
            let l = CALayer()
            l.frame = CGRect(x: CGFloat(i) * tileWidth, y: 0, width: tileWidth, height: bounds.height)
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            layer.insertSublayer(l, below: badge.layer)
            return l
        }
        let duration = clip.timelineDuration
        let times: [MediaTime] = (0..<count).map { i in
            let local = MediaTime(seconds: duration.seconds * (Double(i) + 0.5) / Double(count))
            return clip.sourceTime(atClipTime: local)
        }
        let url = resolver.url(for: media)
        loadTask?.cancel()
        if media.kind == .photo {
            let image = MediaImporter.loadImage(url, maxPixelSize: 240)
            tiles.forEach { $0.contents = image }
            return
        }
        let tiles = self.tiles
        loadTask = Task { @MainActor in
            let images = await thumbnails.thumbnails(url, times: times, height: 120)
            guard !Task.isCancelled else { return }
            for (i, t) in times.enumerated() where i < tiles.count {
                tiles[i].contents = images[t]
            }
        }
    }
}

final class TrimHandle: UIView {}

final class SelectionFrameView: UIView {
    static let handleWidth: CGFloat = 16
    var onTrim: ((Project.TrimEdge, CGFloat, UIGestureRecognizer.State) -> Void)?
    private let left = TrimHandle(), right = TrimHandle()
    private let border = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        border.strokeColor = UIColor.white.cgColor
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = 2.5
        layer.addSublayer(border)
        for (h, edge) in [(left, Project.TrimEdge.leading), (right, .trailing)] {
            h.backgroundColor = .white
            h.layer.cornerRadius = 4
            let grip = UIView()
            grip.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            grip.layer.cornerRadius = 1
            grip.frame = CGRect(x: 7, y: 20, width: 2, height: 22)
            grip.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin]
            h.addSubview(grip)
            h.accessibilityIdentifier = edge == .leading ? "trim.leading" : "trim.trailing"
            h.isAccessibilityElement = true
            let pan = UIPanGestureRecognizer(target: self, action: edge == .leading ? #selector(panLeft(_:)) : #selector(panRight(_:)))
            h.addGestureRecognizer(pan)
            addSubview(h)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = Self.handleWidth
        left.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        right.frame = CGRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: w - 2, dy: 1), cornerRadius: 6).cgPath
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only the handles are interactive; taps in the middle reach the timeline.
        left.frame.insetBy(dx: -8, dy: 0).contains(point) || right.frame.insetBy(dx: -8, dy: 0).contains(point)
    }

    @objc private func panLeft(_ g: UIPanGestureRecognizer) { onTrim?(.leading, g.translation(in: self).x, g.state) }
    @objc private func panRight(_ g: UIPanGestureRecognizer) { onTrim?(.trailing, g.translation(in: self).x, g.state) }
}

final class LabelBar: UIView {
    private let label = UILabel()
    private let color: UIColor
    var isSelectedBar = false { didSet { layer.borderWidth = isSelectedBar ? 2 : 0 } }

    init(color: UIColor, title: String, systemImage: String?) {
        self.color = color
        super.init(frame: .zero)
        backgroundColor = color.withAlphaComponent(0.85)
        layer.cornerRadius = 5
        layer.borderColor = UIColor.white.cgColor
        layer.masksToBounds = true
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.text = title
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 6, dy: 0)
    }
}

final class AudioBarView: UIView {
    var clipID: UUID?
    private var peaks: [Float] = []
    private var visibleRange: ClosedRange<Double> = 0...1
    private var title = ""
    private var beats: [Double] = []
    /// Seconds of this clip that end up in the export (the rest runs past the video).
    private var exportedSeconds: Double = .infinity
    var isSelectedBar = false { didSet { layer.borderWidth = isSelectedBar ? 2 : 0 } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.clipAudio).withAlphaComponent(0.3)
        layer.cornerRadius = 5
        layer.borderColor = UIColor.white.cgColor
        layer.masksToBounds = true
        contentMode = .redraw
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(clip: AudioClip, peaks: [Float], mediaDuration: Double, pointsPerSecond: CGFloat,
                   exportedSeconds: Double = .infinity) {
        self.peaks = peaks
        self.exportedSeconds = exportedSeconds
        let d = max(mediaDuration, 0.001)
        visibleRange = (clip.sourceRange.start.seconds / d)...(clip.sourceRange.end.seconds / d)
        title = clip.name.isEmpty ? clip.role.rawValue.capitalized : clip.name
        beats = clip.beats.map { ($0 - clip.sourceRange.start).seconds }.filter { $0 >= 0 && $0 <= clip.sourceRange.duration.seconds }
        self.pps = pointsPerSecond
        accessibilityLabel = title
        setNeedsDisplay()
    }
    private var pps: CGFloat = 64

    override func draw(_ rect: CGRect) {
        let green = UIColor(Theme.clipAudio)
        if !peaks.isEmpty {
            green.setFill()
            let lo = Int(visibleRange.lowerBound * Double(peaks.count))
            let hi = max(lo + 1, Int(visibleRange.upperBound * Double(peaks.count)))
            let slice = peaks[max(0, lo)..<min(peaks.count, hi)]
            let barW = max(1, bounds.width / CGFloat(max(slice.count, 1)))
            for (i, p) in slice.enumerated() {
                let h = max(1.5, CGFloat(p) * (bounds.height - 6))
                UIRectFill(CGRect(x: CGFloat(i) * barW, y: bounds.midY - h / 2, width: max(1, barW - 0.5), height: h))
            }
        }
        // Past the end of the video: dimmed, since preview and export stop there.
        let endX = CGFloat(exportedSeconds) * pps
        if endX < bounds.width {
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIRectFill(CGRect(x: max(0, endX), y: 0, width: bounds.width - max(0, endX), height: bounds.height))
            if endX > 0 {
                UIColor.white.withAlphaComponent(0.7).setFill()
                UIRectFill(CGRect(x: endX - 0.5, y: 0, width: 1, height: bounds.height))
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: UIColor.white]
        ("♪ " + title as NSString).draw(at: CGPoint(x: 6, y: 2), withAttributes: attrs)
    }
}

// MARK: - SwiftUI bridge

struct TimelineRepresentable: UIViewRepresentable {
    let model: EditorModel
    var onAddMedia: () -> Void

    func makeUIView(context: Context) -> TimelineUIView {
        let view = TimelineUIView()
        view.onScrub = { [weak model] time in
            guard let model else { return }
            model.isScrubbing = true
            model.pause()
            model.seek(to: time, exact: false)
        }
        view.onScrubEnded = { [weak model] in
            guard let model else { return }
            model.isScrubbing = false
            model.seek(to: model.currentTime, exact: true)
        }
        view.onSelect = { [weak model] sel in model?.select(sel) }
        view.onTrim = { [weak model] id, edge, delta, state in model?.trimDrag(id, edge: edge, delta: delta, state: state) }
        view.onAudioMove = { [weak model] id, start in
            model?.edit("Move audio") { try $0.moveAudio(id, toTimelineStart: start) }
        }
        view.onClipDrop = { [weak model] id, index in model?.dropClip(id, to: index) }
        view.onTransitionTap = { [weak model] id in
            model?.select(.clip(id))
            model?.panel = .transition(id)
        }
        view.onAddMedia = onAddMedia
        return view
    }

    func updateUIView(_ view: TimelineUIView, context: Context) {
        view.update(project: model.session.project, revision: model.session.revision, selection: model.session.selection,
                    time: model.currentTime, waveforms: model.waveforms, waveformVersion: model.timelineVersion,
                    thumbnails: model.thumbnails, resolver: model.resolver, followPlayhead: !model.isScrubbing)
    }
}

/// Doesn't start scrolling when a drag begins on a trim handle, so the handle's own pan wins.
final class TimelineScrollView: UIScrollView {
    /// True while a music bar is being held / dragged: scrolling must not steal the finger.
    var isDraggingItem = false

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer {
            if isDraggingItem { return false }
            let p = g.location(in: self)
            if let hit = hitTest(p, with: nil), hit is TrimHandle || hit.superview is TrimHandle { return false }
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}
