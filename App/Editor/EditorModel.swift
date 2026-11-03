import SwiftUI
import AVFoundation
import EditorKit

enum EditorPanel: Equatable {
    case canvas, filters, adjust, speed, volume, transition(UUID), text(UUID?), music, captions, crop, background, export
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
    var isPlaying = false
    var isScrubbing = false
    var panel: EditorPanel?
    var toast: Toast?
    var busyMessage: String?
    var busyProgress: Double?
    var lastError: String?
    var previewReady = false
    /// Incremented when the timeline must redraw (thumbnails, waveforms loaded).
    var timelineVersion = 0
    var waveforms: [UUID: [Float]] = [:]

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
            }
        }
        scheduleRebuild(immediate: true)
        loadWaveforms()
    }

    var project: Project { session.project }
    var duration: MediaTime { project.duration }

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
            let built = try await CompositionBuilder().build(project: project, resolver: resolver, renderSize: size)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = isPlaying
            let resume = min(currentTime, built.duration)
            player.replaceCurrentItem(with: item)
            await player.seek(to: resume.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            builtRevision = revision
            previewReady = true
        } catch {
            lastError = "Preview failed: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - MediaTime(seconds: 0.05) { seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: MediaTime, exact: Bool = true) {
        let t = time.clamped(to: .zero...max(duration, .zero))
        currentTime = t
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 30)
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
    func trimDrag(_ id: UUID, edge: Project.TrimEdge, delta: MediaTime, state: UIGestureRecognizer.State) {
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

    func extractAudio() {
        guard let id = selectedClipID else { return }
        edit("Extract audio") { try $0.extractAudio(from: id) }
        loadWaveforms()
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
            let beats = try await BeatDetector.detect(url: url)?.beats ?? []
            model.edit("Add music") { p in
                p.media.append(item)
                var clip = AudioClip(mediaID: item.id, role: .music,
                                     sourceRange: MediaTimeRange(start: .zero, duration: min(item.duration, p.layout.duration)),
                                     start: .zero)
                clip.name = track.name
                clip.volume = 0.7
                clip.fadeOut = MediaTime(seconds: 1.5)
                clip.autoDuck = true
                clip.beats = beats.map { MediaTime(seconds: $0) }
                p.addAudio(clip)
            }
            model.loadWaveforms()
            model.showToast("Added \(track.name) · \(beats.count) beats", systemImage: "music.note")
        }
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

    func beatSync() {
        guard let music = project.audioClips.first(where: { $0.role == .music && !$0.beats.isEmpty }) else {
            showToast("Add music first", systemImage: "music.note")
            panel = .music
            return
        }
        var aligned = 0
        edit("Beat sync") { aligned = $0.syncCutsToBeats(music.timelineBeats) }
        showToast("Synced \(aligned) cut\(aligned == 1 ? "" : "s") to the beat", systemImage: "metronome")
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
                self.showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                               systemImage: "exclamationmark.triangle")
            }
        }
    }

    func showToast(_ message: String, systemImage: String = "sparkles") {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = Toast(message: message, systemImage: systemImage) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
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
