import SwiftUI
import AVFoundation
import CoreImage
import EditorKit

enum EditorPanel: Equatable {
    case canvas, trim, duration, motion, filters, adjust, speed, duck, denoise, transition(UUID), text(UUID?), music, captions, captionText, crop, background, export
    case textDuration(UUID), textAnimate(UUID), textPosition(UUID), watermark, titleCard(TitleCard.Placement)
}

/// Drives one editing session: project state, preview player, analysis jobs.
@Observable
final class EditorModel {
    let store: ProjectStore
    let session: EditSession
    let resolver: MediaResolver
    let thumbnails = ThumbnailProvider()
    let player = AVPlayer()
    private let autosaver: Autosaver

    var currentTime: MediaTime = .zero
    /// Animations (clip In/Out/Combo, photo motion, text entrances) are drawn only
    /// while playing; paused or scrubbing, the preview shows clips at rest for editing.
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            renderToggles.animationsEnabled = isPlaying
            if !isPlaying {
                // Redraw the paused frame without animation.
                let t = currentTime
                player.seek(to: t.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
    /// Shared with every preview composition; the compositor reads it per frame.
    let renderToggles = RenderToggles(animations: false)
    var isScrubbing = false
    var panel: EditorPanel? {
        didSet {
            guard let panel, panel != oldValue else { return }
            switch panel {
            case .filters, .adjust, .crop, .background, .speed, .duration:
                showCleanFrameOfSelection()
            case .textPosition(let id), .text(.some(let id)):
                // Text panels: pause on a frame where that text is visible.
                pause()
                if let t = project.textOverlays.first(where: { $0.id == id }), !t.range.contains(currentTime) {
                    seek(to: t.range.start + MediaTime(seconds: min(0.5, t.range.duration.seconds / 2)))
                }
            default:
                break
            }
        }
    }

    /// Moves the playhead to a frame of the selected clip where no In/Out animation,
    /// transition or fade is active, so filters and adjustments can be judged.
    func showCleanFrameOfSelection() {
        guard let id = selectedClipID, let index = project.clipIndex(id),
              let entry = project.layout.entry(for: id) else { return }
        let clip = project.clips[index]
        let duration = entry.range.duration.seconds
        var restStart = entry.overlapIn.seconds
        var restEnd = duration - entry.overlapOut.seconds
        if let anim = clip.animation {
            if anim.entrance != nil { restStart = max(restStart, min(anim.inDuration, duration / 2)) }
            if anim.exit != nil { restEnd = min(restEnd, duration - min(anim.outDuration, duration / 2)) }
        }
        let local = restEnd > restStart ? (restStart + restEnd) / 2 : duration / 2
        let target = entry.range.start + MediaTime(seconds: local)
        // Already looking at a clean frame of this clip? Leave the playhead alone.
        if currentTime >= entry.range.start + MediaTime(seconds: restStart),
           currentTime <= entry.range.start + MediaTime(seconds: max(restStart, restEnd)) { return }
        pause()
        seek(to: target)
    }
    var toast: Toast?
    var busyMessage: String?
    var busyProgress: Double?
    var lastError: String?
    var previewReady = false
    /// The single Files picker on the editor screen and what it was opened for.
    /// SwiftUI presents only one `.fileImporter` per screen, so panels request it here.
    var showFileImporter = false
    private(set) var fileImportPurpose: FileImportPurpose = .media

    func openFiles(for purpose: FileImportPurpose) {
        fileImportPurpose = purpose
        showFileImporter = true
    }
    /// Last displayed frame, shown over the preview while a rebuilt player item warms up
    /// (avoids a black flash after every edit).
    var holdFrame: UIImage?
    private var frameOutput: AVPlayerItemVideoOutput?
    /// Incremented when the timeline must redraw (thumbnails, waveforms loaded).
    var timelineVersion = 0
    var waveforms: [UUID: [Float]] = [:]
    /// The 5 audio tracks used most recently, in any project (MUS-10).
    let recentAudio = RecentAudioStore.defaultStore()
    var recentTracks: [RecentAudioStore.Entry] = []

    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var builtRevision = -1
    private var toastTask: Task<Void, Never>?

    init(project: Project, store: ProjectStore) {
        self.store = store
        self.resolver = MediaResolver(store: store, projectID: project.id)
        let autosaver = Autosaver(store: store)
        self.autosaver = autosaver
        self.session = EditSession(project: project) { p in
            Task { await autosaver.schedule(p) }
        }
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = MediaTime(time)
                let playing = self.player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
                // PRV-8: past the end of the video, playback only continues while music is selected.
                if playing, !self.isAuditioningMusic, self.currentTime >= self.duration {
                    self.player.pause()
                    self.isPlaying = false
                    // Just reached the end: land exactly on it. Already further (music was
                    // deselected while playing past it): stay where the playhead is.
                    if self.currentTime - self.duration < MediaTime(seconds: 0.25) { self.seek(to: self.duration) }
                }
            }
        }
        if LaunchOptions.isUITesting {
            NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.debugRate = self.player.rate } }
            }
        }
        scheduleRebuild(immediate: true)
        loadWaveforms()
    }

    var project: Project { session.project }
    var duration: MediaTime { project.duration }

    /// PRV-8: with an audio clip selected, Play goes on past the end of the video to the end
    /// of the music, so the whole song can be heard (and cut with Start Here / ✂︎).
    var isAuditioningMusic: Bool { selectedAudioID != nil }

    /// Where Play stops: the end of the video, or the end of the music while auditioning.
    var playbackEnd: MediaTime { isAuditioningMusic ? project.timelineDuration : duration }

    /// The playhead is past the end of the video (over music only); not exported.
    var isPastVideoEnd: Bool { duration > .zero && currentTime > duration + MediaTime(seconds: 0.02) }

    // MARK: Preview

    /// Rebuilds the player item after edits (debounced so slider drags stay smooth).
    func scheduleRebuild(immediate: Bool = false) {
        rebuildTask?.cancel()
        let revision = session.revision
        let project = session.project
        rebuildTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(60)) }
            guard let self, !Task.isCancelled, revision != self.builtRevision else { return }
            await self.rebuild(project: project, revision: revision)
        }
    }

    private func rebuild(project: Project, revision: Int) async {
        guard !project.clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            previewReady = false
            builtRevision = revision
            return
        }
        let size = project.aspectRatio.renderSize(shortEdge: 720)
        do {
            // The preview runs to the end of the music too (PRV-8); export stays at the video's length.
            let built = try await CompositionBuilder().build(project: project, resolver: resolver, renderSize: size,
                                                             toggles: renderToggles, minimumLength: project.timelineDuration)
            guard !Task.isCancelled else { return }
            // Grab what's on screen now so the swap is seamless.
            if let output = frameOutput, let pb = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                let ci = CIImage(cvPixelBuffer: pb)
                if let cg = CIContext().createCGImage(ci, from: ci.extent) { holdFrame = UIImage(cgImage: cg) }
            }
            let item = AVPlayerItem(asset: built.composition)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            frameOutput = output
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = isPlaying
            let resume = min(currentTime, built.duration)
            player.replaceCurrentItem(with: item)
            await player.seek(to: resume.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            // Safety net: never leave a stale frame up if the layer never reports readiness.
            Task { try? await Task.sleep(for: .seconds(1.5)); self.holdFrame = nil }
            builtRevision = revision
            previewReady = true
        } catch {
            lastError = "Preview failed: \(error.localizedDescription)"
        }
    }

    /// PRV-9: preview play speeds. Editor state only: not saved, not undoable, not exported.
    static let previewRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// How fast the preview plays (PRV-9). Starts at 1× for each editor session.
    var previewRate: Float = 1 {
        didSet {
            player.defaultRate = previewRate
            // While playing, restart at the new rate the same way Play does. Setting `rate` on
            // the running player didn't take effect on the device.
            if isPlaying {
                player.pause()
                player.playImmediately(atRate: previewRate)
            }
        }
    }

    /// UI tests: the player's actual rate, refreshed on every rate change (PRV-9).
    var debugRate: Float = 0

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            // At (or past) the end, Play starts again from 0:00. With music selected the end is the
            // end of the music, so Play from a point after the video keeps playing from there.
            if currentTime >= playbackEnd - MediaTime(seconds: 0.05) { seek(to: .zero) }
            isPlaying = true          // enable animations before the first frame plays
            player.play()
        }
    }

    /// Starts playback with animations on (used by panels to preview an effect).
    func play() {
        isPlaying = true
        player.play()
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: MediaTime, exact: Bool = true) {
        // The playhead can go past the video over music that runs longer (to cut it there);
        // the preview stays on the last frame.
        let t = time.clamped(to: .zero...max(project.timelineDuration, .zero))
        currentTime = t
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 30)
        // The preview composition runs to the end of the music (PRV-8), so seek there directly.
        player.seek(to: t.cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: Editing

    func edit(_ label: String, _ change: (inout Project) throws -> Void) {
        do {
            try session.apply(label, change)
            scheduleRebuild()
        } catch EditError.tooShort {
            showToast("Too close to the clip edge", systemImage: "exclamationmark.triangle")
        } catch {
            showToast("Couldn't \(label.lowercased())", systemImage: "exclamationmark.triangle")
        }
    }

    func editCoalescing(_ label: String, key: String, _ change: @escaping (inout Project) -> Void) {
        session.applyCoalescing(label, key: key, change)
        scheduleRebuild()
    }

    func undo() { session.undo(); scheduleRebuild(); showToast("Undo", systemImage: "arrow.uturn.backward") }
    func redo() { session.redo(); scheduleRebuild(); showToast("Redo", systemImage: "arrow.uturn.forward") }

    var selectedClipID: UUID? {
        if case .clip(let id) = session.selection { return id }
        return nil
    }

    var selectedClip: VideoClip? { session.selectedClip }

    func select(_ selection: EditSession.Selection) {
        session.selection = selection
        if selection == .none, case .some(let p) = panel, p != .canvas, p != .music, p != .captions { panel = nil }
    }

    private var trimBase: Project?

    /// Live trimming from the timeline handles: each change re-applies the total
    /// drag to the project as it was when the drag began (one undo step).
    var trimDebug = ""

    func trimDrag(_ id: UUID, edge: Project.TrimEdge, delta: MediaTime, state: UIGestureRecognizer.State) {
        trimDebug = "\(state.rawValue) \(delta)"
        switch state {
        case .began:
            pause()
            trimBase = session.project
        case .changed:
            guard var p = trimBase else { return }
            guard (try? p.trim(clipID: id, edge: edge, by: delta)) != nil else { return }
            session.applyCoalescing("Trim", key: "trim-\(id)-\(edge)") { $0 = p }
            if let entry = p.layout.entry(for: id) {
                let t = edge == .leading ? entry.range.start : entry.range.end - MediaTime(seconds: 0.03)
                seek(to: t, exact: false)
            }
            scheduleRebuild()
        default:
            trimBase = nil
            scheduleRebuild(immediate: true)
        }
    }

    func split() {
        edit("Split") { try $0.split(at: currentTime) }
        showToast("Split at \(currentTime.timecode)", systemImage: "scissors")
    }

    func deleteSelection() {
        switch session.selection {
        case .clip(let id): edit("Delete clip") { try $0.deleteClip(id) }
        case .text(let id): edit("Delete text") { $0.deleteText(id) }
        case .audio(let id): edit("Delete audio") { $0.deleteAudio(id) }
        case .captions: edit("Delete captions") { $0.captions.segments = [] }
        case .none: break
        }
        session.selection = .none
        panel = nil
    }

    func duplicateSelected() {
        guard let id = selectedClipID else { return }
        edit("Duplicate") { try $0.duplicateClip(id) }
    }

    /// Drag-to-reorder drop on the timeline (TML-13). One undo step; the moved clip is
    /// selected and the playhead goes to its start.
    func dropClip(_ id: UUID, to index: Int) {
        guard project.canReorder(id), project.clipIndex(id) != index else { return }
        pause()
        edit("Move clip") { try $0.moveClip(id, to: index) }
        session.selection = .clip(id)
        if let entry = project.layout.entry(for: id) { seek(to: entry.range.start) }
        let range = project.movableClipIndices
        showToast("Moved to position \(index - range.lowerBound + 1) of \(range.count)", systemImage: "arrow.left.and.right")
    }

    func freezeFrame() {
        edit("Freeze frame") { try $0.insertFreezeFrame(at: currentTime) }
        showToast("Freeze frame added", systemImage: "snowflake")
    }

    func reverseSelected() {
        guard let clip = selectedClip, let media = project.mediaItem(clip.mediaID) else { return }
        if clip.isReversed {
            edit("Reverse") { try $0.setReversed(false, clipID: clip.id) }
            return
        }
        if media.reversedFileName != nil {
            edit("Reverse") { try $0.setReversed(true, clipID: clip.id) }
            return
        }
        runBusy("Reversing clip…") { model in
            let name = "rev-\(media.fileName.split(separator: ".").first ?? "clip").mov"
            let destination = model.resolver.mediaDirectory.appendingPathComponent(name)
            try await UtilityMedia.makeReversedVideo(source: model.resolver.url(for: media), destination: destination) { p in
                Task { @MainActor in model.busyProgress = p }
            }
            model.edit("Reverse") { project in
                if let i = project.media.firstIndex(where: { $0.id == media.id }) { project.media[i].reversedFileName = name }
                try project.setReversed(true, clipID: clip.id)
            }
            model.showToast("Clip reversed", systemImage: "backward.fill")
        }
    }

    /// Voice (CLP-5): turns the selected video clip's own sound off or back on.
    func toggleVoice() {
        guard let clip = selectedClip, let media = project.mediaItem(clip.mediaID) else { return }
        guard media.hasAudio else { showToast("This clip has no sound", systemImage: "speaker.slash"); return }
        let muting = !clip.isMuted
        edit("Voice") { try $0.updateClip(clip.id) { $0.isMuted = muting } }
        showToast(muting ? "Voice off" : "Voice on", systemImage: muting ? "mic.slash" : "mic")
    }

    /// Turns Denoise on (at `level`) or off for the whole video (DNS-1, DNS-2). Every video in the
    /// edit with sound is cleaned once per strength, then reused (also by split pieces and copies).
    func setNoiseReduction(_ level: NoiseReduction?) {
        guard let level else {
            edit("Noise reduction") { $0.setNoiseReduction(nil) }
            return
        }
        let sources = project.denoiseSources
        guard !sources.isEmpty else { showToast("This video has no sound", systemImage: "speaker.slash"); return }
        let missing = sources.filter { !hasCurrentDenoisedFile($0, level: level) }
        guard !missing.isEmpty else {
            edit("Noise reduction") { $0.setNoiseReduction(level) }
            showToast("Noise reduced (\(level.title))", systemImage: "waveform")
            return
        }
        runBusy("Reducing noise…") { model in
            let files = try await model.makeDenoisedFiles(missing, level: level)
            model.edit("Noise reduction") { $0.setNoiseReduction(level, files: files) }
            model.showToast("Noise reduced (\(level.title))", systemImage: "waveform")
        }
    }

    /// DNS-7: while Denoise is on, videos added later are cleaned straight away.
    func denoiseNewMedia() {
        guard let level = project.noiseReduction else { return }
        let missing = project.denoiseSources.filter { !hasCurrentDenoisedFile($0, level: level) }
        guard !missing.isEmpty else { return }
        runBusy("Reducing noise…") { model in
            let files = try await model.makeDenoisedFiles(missing, level: level)
            model.edit("Noise reduction") { $0.recordDenoisedFiles(files, level: level) }
        }
    }

    /// A cleaned file for `level` exists and was made by the current rules (an older one, from
    /// before the DNS-6 fix, is made again).
    private func hasCurrentDenoisedFile(_ item: MediaItem, level: NoiseReduction) -> Bool {
        guard resolver.denoisedURL(for: item, level: level) != nil, let name = item.denoisedFileNames?[level] else { return false }
        return NoiseReducer.isCurrent(fileName: name)
    }

    /// Cleans each item's sound in turn; returns the new file names by media ID.
    private func makeDenoisedFiles(_ items: [MediaItem], level: NoiseReduction) async throws -> [UUID: String] {
        var files: [UUID: String] = [:]
        for (done, item) in items.enumerated() {
            let base = item.fileName.split(separator: ".").first.map(String.init) ?? "clip"
            let name = NoiseReducer.fileName(level: level, base: base)
            let destination = resolver.mediaDirectory.appendingPathComponent(name)
            let count = Double(items.count)
            try await NoiseReducer.process(source: resolver.url(for: item), destination: destination, level: level) { p in
                Task { @MainActor in self.busyProgress = (Double(done) + p) / count }
            }
            files[item.id] = name
        }
        return files
    }

    /// Removes um, uh, ah… from the captions (text only; the video is not cut).
    func removeCaptionFillers() {
        var track = project.captions
        let removed = track.removeFillers()
        guard removed > 0 else {
            showToast("No filler words found", systemImage: "checkmark.circle")
            return
        }
        edit("Remove fillers") { $0.captions = track }
        if project.captions.segments.isEmpty { select(.none) }
        showToast("Removed \(removed) filler word\(removed == 1 ? "" : "s")", systemImage: "text.badge.minus")
    }

    var selectedAudioID: UUID? {
        if case .audio(let id) = session.selection { return id }
        return nil
    }

    var selectedAudio: AudioClip? {
        guard let id = selectedAudioID else { return nil }
        return project.audioClips.first { $0.id == id }
    }

    /// Cuts a music clip in two at `time` (the scissors on the timeline / toolbar).
    /// Each piece is its own clip: select, move, repeat, duplicate or delete it separately.
    func cutAudio(_ id: UUID, at time: MediaTime) {
        var newID: UUID?
        edit("Cut audio") { newID = try $0.splitAudio(id, at: time) }
        if let newID {
            session.selection = .audio(newID)
            showToast("Cut at \(time.timecode)", systemImage: "scissors")
        }
        loadWaveforms()
    }

    func cutSelectedAudio() {
        guard let id = selectedAudioID else { return }
        cutAudio(id, at: currentTime)
    }



    /// "Start Here" (MUS-11) is offered while the playhead is inside the selected audio clip,
    /// at least 0.2 s from its ends (the same rule as the scissors).
    var canStartSelectedAudioHere: Bool {
        guard let clip = selectedAudio else { return false }
        let margin = Project.minimumAudioDuration
        return currentTime >= clip.start + margin && currentTime <= clip.timelineRange.end - margin
    }

    /// One tap: the music now plays from the playhead's point in the song, moved back to the
    /// start. Then it plays from there so the user hears the result with the video.
    func startSelectedAudioHere() {
        guard let id = selectedAudioID, canStartSelectedAudioHere else { return }
        let time = currentTime.snappedToFrame(fps: 30)
        var newID: UUID?
        edit("Start here") { newID = try $0.startAudioHere(id, at: time) }
        guard let newID, let clip = project.audioClips.first(where: { $0.id == newID }) else { return }
        session.selection = .audio(newID)
        loadWaveforms()
        showToast("Music starts from \(clip.sourceRange.start.timecode)", systemImage: "arrow.right.to.line")
        seek(to: clip.start)
        if clip.start < duration { play() }
    }

    /// "Move to Start" is offered when there is blank space before the selected music on its lane.
    var canMoveSelectedAudioToStart: Bool {
        guard let id = selectedAudioID else { return false }
        return project.audioGapStart(id) != nil
    }

    func moveSelectedAudioToStart() {
        guard let id = selectedAudioID, let start = project.audioGapStart(id) else { return }
        edit("Move to start") { try $0.moveAudioToGapStart(id) }
        showToast("Moved to \(start.timecode)", systemImage: "arrow.left.to.line")
    }

    /// Repeat is offered only while the selected music stops before the video ends.
    var canRepeatSelectedAudio: Bool {
        guard let id = selectedAudioID, let clip = project.audioClips.first(where: { $0.id == id }) else { return false }
        return clip.timelineRange.end < project.layout.duration - MediaTime(seconds: 0.2)
    }

    func repeatSelectedAudio() {
        guard let id = selectedAudioID else { return }
        var added = 0
        edit("Repeat audio") { added = try $0.repeatAudio(id) }
        showToast(added > 0 ? "Repeated \(added + 1)× to the end" : "Already plays to the end",
                  systemImage: "repeat")
        loadWaveforms()
    }

    // MARK: Watermark & title cards

    func setWatermark(_ change: (inout Watermark) -> Void) {
        edit("Watermark") { p in
            var w = p.watermark ?? Watermark()
            change(&w)
            p.watermark = w
        }
    }

    func removeWatermark() { edit("Remove watermark") { $0.watermark = nil } }

    /// Stores a picked image in the project and uses it as the watermark.
    func setWatermarkImage(_ data: Data) {
        let name = "watermark-\(UUID().uuidString.prefix(8)).png"
        let url = resolver.mediaDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: resolver.mediaDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            showToast("Couldn't use that image", systemImage: "exclamationmark.triangle")
            return
        }
        setWatermark { $0.kind = .image; $0.imageFileName = name }
    }

    /// Renders and inserts / updates the opening or closing slide.
    func applyTitleCard(_ card: TitleCard, duration: MediaTime) {
        let dir = resolver.mediaDirectory
        Task {
            do {
                let item = try await Task.detached { try TitleCardRenderer.write(card, to: dir) }.value
                self.edit(card.placement == .opening ? "Opening slide" : "Closing slide") {
                    $0.upsertTitleCard(card, image: item, duration: duration)
                }
                if let entry = self.project.titleCardClip(card.placement).flatMap({ self.project.layout.entry(for: $0.id) }) {
                    self.seek(to: entry.range.start + MediaTime(seconds: min(0.8, entry.range.duration.seconds / 2)))
                }
            } catch {
                self.showToast("Couldn't create the slide", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func removeTitleCard(_ placement: TitleCard.Placement) {
        edit("Remove slide") { $0.removeTitleCard(placement) }
    }

    // MARK: Dragging text on the preview

    @ObservationIgnored private var textSizeCache: [String: CGSize] = [:]

    /// Moves text live while the finger is down (no composition rebuild, just a redraw).
    func liveMoveText(_ id: UUID, to center: SIMD2<Double>) {
        renderToggles.setTextCenter(center, for: id)
        player.seek(to: currentTime.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Stores the final position as a custom (free) placement.
    func commitTextMove(_ id: UUID, to center: SIMD2<Double>) {
        edit("Move text") { p in
            p.updateText(id) { $0.anchor = nil; $0.centerX = center.x; $0.centerY = center.y }
        }
        // The rebuilt composition carries the new position; drop the live override after it lands.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            self.renderToggles.setTextCenter(nil, for: id)
        }
    }

    /// Size (in preview-render pixels) and centre (canvas-normalized) of a text overlay,
    /// matching what the compositor draws.
    func textFrame(_ overlay: TextOverlay) -> (size: CGSize, center: SIMD2<Double>, canvas: CGSize)? {
        let canvas = project.aspectRatio.renderSize(shortEdge: 720)
        let key = "\(overlay.text.hashValue)-\(overlay.style.hashValue)-\(overlay.scale)-\(Int(canvas.width))x\(Int(canvas.height))"
        let pixelSize: CGSize
        if let cached = textSizeCache[key] {
            pixelSize = cached
        } else {
            guard let image = TextRasterizer.render(overlay, canvas: canvas) else { return nil }
            pixelSize = CGSize(width: image.width, height: image.height)
            if textSizeCache.count > 100 { textSizeCache.removeAll() }
            textSizeCache[key] = pixelSize
        }
        let size = CGSize(width: pixelSize.width * overlay.scale, height: pixelSize.height * overlay.scale)
        let center = renderToggles.textCenter(overlay.id)
            ?? overlay.anchor?.center(for: size, canvas: canvas)
            ?? SIMD2(overlay.centerX, overlay.centerY)
        return (size, center, canvas)
    }

    func addText() {
        var newID: UUID?
        edit("Add text") { p in newID = p.addText("Your text", at: currentTime) }
        if let newID {
            session.selection = .text(newID)
            panel = .text(newID)
        }
    }

    // MARK: Import

    func importMedia(urls: [URL]) async {
        busyMessage = "Importing…"
        busyProgress = nil
        defer { busyMessage = nil }
        var items: [MediaItem] = []
        for url in urls {
            if let item = try? await MediaImporter.importMedia(at: url, store: store, projectID: project.id) {
                items.append(item)
            }
        }
        guard !items.isEmpty else {
            showToast("Couldn't import that file", systemImage: "exclamationmark.triangle")
            return
        }
        edit("Add media") { p in
            for item in items { p.appendClip(for: item) }
        }
        loadWaveforms()
        denoiseNewMedia()
    }

    func addMusic(_ track: SampleMedia.Track) {
        runBusy("Adding \(track.name)…") { model in
            let length = max(model.duration.seconds, 10)
            let file = "music-\(track.id)-\(Int(length)).m4a"
            let url = model.resolver.mediaDirectory.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) {
                try SampleMedia.renderMusic(track, duration: length, to: url)
            }
            var item = try await MediaImporter.probeAudio(url, fileName: file, displayName: track.name)
            item.id = UUID()
            try await model.placeMusic(item, name: track.name)
            if let list = try? model.recentAudio.add(fileAt: url, name: track.name, duration: item.duration) {
                model.recentTracks = list
            }
        }
    }

    /// Adds the user's own audio as background music: an audio file (Files app)
    /// or the soundtrack of a video from Photos.
    /// The file is copied into the project so the edit keeps working if the original moves.
    func addMusicFile(_ url: URL, name: String) {
        runBusy("Adding \(name)…") { model in
            let fileName = try model.store.importFile(at: url, projectID: model.project.id)
            let stored = model.resolver.mediaDirectory.appendingPathComponent(fileName)
            let item: MediaItem
            do {
                item = try await MediaImporter.probeAudio(stored, fileName: fileName, displayName: name)
            } catch {
                try? FileManager.default.removeItem(at: stored)
                throw MusicImportError.noAudio
            }
            try await model.placeMusic(item, name: name)
            // Remember it for the Recent list (kept even if this project is deleted later).
            if let list = try? model.recentAudio.add(fileAt: stored, name: name, duration: item.duration) {
                model.recentTracks = list
            }
        }
    }

    /// Adds one of the recent tracks to this project (copied in, like a file from Files).
    func addRecentTrack(_ entry: RecentAudioStore.Entry) {
        addMusicFile(recentAudio.url(for: entry), name: entry.name)
    }

    func loadRecentTracks() {
        recentTracks = recentAudio.entries
    }

    /// Puts music on its own lane (after any existing music),
    /// and sets sensible defaults (70% volume, fade-out, ducking under speech).
    private func placeMusic(_ item: MediaItem, name: String) async throws {
        edit("Add music") { p in
            p.media.append(item)
            // The whole song goes on the timeline; preview and export stop at the end of the video.
            let length = item.duration
            // Another track starts where the existing music ends (if that's inside the video).
            let musicEnd = p.audioClips.filter { $0.role == .music }.map(\.timelineRange.end).max() ?? .zero
            let start = musicEnd < p.layout.duration ? musicEnd : .zero
            var clip = AudioClip(mediaID: item.id, role: .music,
                                 sourceRange: MediaTimeRange(start: .zero, duration: length),
                                 start: start)
            clip.name = name
            clip.volume = 0.7
            clip.fadeOut = MediaTime(seconds: min(1.5, length.seconds / 4))
            clip.autoDuck = true
            clip.fitsVideo = true
            p.addAudio(clip)
        }
        loadWaveforms()
        showToast("Added \(name)", systemImage: "music.note")
    }

    // MARK: AI features

    func generateCaptions() {
        runBusy("Transcribing on device…") { model in
            let (track, engine) = try await CaptionGenerator.generate(project: model.project, resolver: model.resolver,
                                                                     workDirectory: model.store.cacheDirectory(for: model.project.id))
            model.edit("Auto captions") { $0.captions = track }
            model.session.selection = .captions
            model.panel = .captions
            let words = track.segments.reduce(0) { $0 + $1.words.count }
            model.showToast("Captioned \(words) words", systemImage: "captions.bubble")
            _ = engine
        }
    }

    func removeSilences() {
        runBusy("Finding pauses…") { model in
            let ranges = try await SilenceDetector.detect(project: model.project, resolver: model.resolver)
            guard !ranges.isEmpty else {
                model.showToast("No long pauses found", systemImage: "waveform")
                return
            }
            let before = model.project.layout.duration
            model.edit("Remove silence") { $0.rippleDelete(ranges: ranges) }
            let saved = (before - model.project.layout.duration).seconds
            model.showToast("Removed \(ranges.count) pause\(ranges.count == 1 ? "" : "s") · \(String(format: "%.1f", saved))s shorter",
                            systemImage: "waveform.badge.minus")
        }
    }


    func autoReframe() {
        guard let clip = selectedClip, let media = project.mediaItem(clip.mediaID), clip.kind == .video, !clip.isStill else {
            showToast("Select a video clip", systemImage: "rectangle.dashed")
            return
        }
        runBusy("Tracking subject…") { model in
            let keys = try await Reframer.analyze(url: model.resolver.url(for: media), range: clip.sourceRange)
            model.edit("Auto reframe") { p in
                try p.updateClip(clip.id) { c in
                    c.reframe = keys
                    c.transform.fit = .fill
                }
            }
            model.showToast("Reframed to follow the subject", systemImage: "viewfinder")
        }
    }

    func autoEnhance() {
        guard let clip = selectedClip, let media = project.mediaItem(clip.mediaID) else {
            showToast("Select a clip", systemImage: "rectangle.dashed")
            return
        }
        runBusy("Enhancing…") { model in
            let adj = try await AutoEnhancer.analyze(url: model.resolver.url(for: media), range: clip.sourceRange,
                                                     isPhoto: clip.kind == .photo)
            model.edit("Auto enhance") { p in try p.updateClip(clip.id) { $0.adjustments = adj } }
            model.showToast("Enhanced", systemImage: "wand.and.stars")
        }
    }

    func setBackgroundRemoval(_ replacement: BackgroundReplacement?) {
        guard let id = selectedClipID else { return }
        edit("Remove background") { try $0.updateClip(id) { $0.backgroundRemoval = replacement } }
        if replacement != nil { showToast("Background removed", systemImage: "person.crop.rectangle") }
    }

    // MARK: Helpers

    func runBusy(_ message: String, _ work: @escaping (EditorModel) async throws -> Void) {
        pause()
        busyMessage = message
        busyProgress = nil
        Task {
            defer { self.busyMessage = nil; self.busyProgress = nil }
            do {
                try await work(self)
            } catch {
                var message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if LaunchOptions.isUITesting {
                    let ns = error as NSError
                    message += " [\(ns.domain) \(ns.code); analyzer: \(CaptionGenerator.lastAnalyzerFailure ?? "-")]"
                }
                self.showToast(message, systemImage: "exclamationmark.triangle")
            }
        }
    }

    func showToast(_ message: String, systemImage: String = "sparkles") {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = Toast(message: message, systemImage: systemImage) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(LaunchOptions.isUITesting ? 6 : 2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
        }
    }

    func loadWaveforms() {
        let items = project.audioClips.compactMap { clip -> (UUID, URL)? in
            guard waveforms[clip.mediaID] == nil, let m = project.mediaItem(clip.mediaID) else { return nil }
            return (m.id, resolver.url(for: m))
        }
        for (id, url) in items {
            Task {
                if let peaks = try? await Waveform.peaks(url: url, buckets: 400) {
                    self.waveforms[id] = peaks
                    self.timelineVersion += 1
                }
            }
        }
    }

    func close() async {
        pause()
        await autosaver.schedule(session.project)
        await autosaver.flush()
        try? store.save(session.project)
        await saveThumbnail()
    }

    private func saveThumbnail() async {
        guard let clip = project.clips.first, let media = project.mediaItem(clip.mediaID) else { return }
        let url = resolver.url(for: media)
        let image: CGImage?
        if media.kind == .photo {
            image = MediaImporter.loadImage(url, maxPixelSize: 400)
        } else {
            image = try? await MediaImporter.frame(of: url, at: clip.sourceRange.start, maxSize: CGSize(width: 400, height: 400))
        }
        guard let image else { return }
        let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        try? data?.write(to: store.thumbnailURL(for: project.id))
    }
}

enum MusicImportError: LocalizedError {
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudio: return "That file has no audio track."
        }
    }
}

enum FileImportPurpose {
    case media, music
}
