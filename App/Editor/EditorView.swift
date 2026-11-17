import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import EditorKit

struct EditorView: View {
    @State var model: EditorModel
    /// Opened from New Project: present the Photos library right away so the user can
    /// pick videos and photos and start (LIB-1). Cancelling leaves the empty editor open.
    var startWithPhotos = false
    let onClose: () -> Void
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showExport = false
    @State private var showAddMenu = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// LAY-1: the wide layout needs a regular-width window at least this wide (pt).
    static let wideMinWidth: CGFloat = 840

    var body: some View {
        GeometryReader { geo in
            if sizeClass == .regular && geo.size.width >= Self.wideMinWidth {
                wideLayout(width: geo.size.width)
            } else {
                phoneLayout
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .background { EditorShortcuts(model: model, onExport: openExport) }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.top, 56).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let message = model.busyMessage {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    BusyOverlay(message: message, progress: model.busyProgress)
                }
            }
        }
        .task {
            // UI tests and demos (-sampleMedia) import bundled clips instead of the Photos library.
            guard startWithPhotos, model.project.isEmptyEdit, !LaunchOptions.useSampleMedia,
                  LaunchOptions.demoMediaFolder == nil else { return }
            try? await Task.sleep(for: .milliseconds(350))   // let the editor slide in first
            showPicker = true
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20,
                      matching: .any(of: [.videos, .images]), preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let urls = await PhotoImport.load(items)
                pickerItems = []
                await model.importMedia(urls: urls)
            }
        }
        .fileImporter(isPresented: $model.showFileImporter,
                      allowedContentTypes: model.fileImportPurpose == .music ? [.audio] : [.movie, .image, .audio],
                      allowsMultipleSelection: model.fileImportPurpose != .music) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            switch model.fileImportPurpose {
            case .music:
                let url = urls[0]
                model.addMusicFile(url, name: url.deletingPathExtension().lastPathComponent)
                model.panel = nil
            case .media:
                Task { await model.importMedia(urls: urls) }
            }
        }
        .confirmationDialog("Add", isPresented: $showAddMenu) {
            Button("Photos Library") { showPicker = true }
            Button("Files") { model.openFiles(for: .media) }
            if LaunchOptions.useSampleMedia || LaunchOptions.demoMediaFolder != nil {
                Button("Sample Clips") { Task { await SampleImport.importSamples(into: model) } }
            }
        }
        .fullScreenCover(isPresented: $showExport) {
            ExportView(model: model).centeredOnWideScreens()
        }
        .fullScreenCover(isPresented: Binding(get: { model.panel == .captionText },
                                              set: { if !$0, model.panel == .captionText { model.panel = nil } })) {
            CaptionTextEditor(model: model).centeredOnWideScreens()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }

    // MARK: Layouts (LAY-1…3)

    /// Phone layout (EDT): preview, transport, timeline, then the toolbar or the open panel.
    private var phoneLayout: some View {
        VStack(spacing: 0) {
            topBar
            PreviewView(model: model, onAddMedia: addMedia)
                .padding(.horizontal, 8)
                .frame(minHeight: 150, maxHeight: .infinity)
            transport
            TimelineRepresentable(model: model, onAddMedia: addMedia)
                .frame(height: timelineHeight)
            bottomArea
                .layoutPriority(1)
        }
    }

    /// Wide layout (LAY-2): preview and transport beside the sidebar, the timeline full width below.
    private func wideLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewView(model: model, onAddMedia: addMedia)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                }
                sidebar
                    .frame(width: min(420, max(340, width * 0.3)))
            }
            TimelineRepresentable(model: model, onAddMedia: addMedia)
                .frame(height: wideTimelineHeight)
        }
    }

    private var laneCount: Int { (model.project.audioClips.map(\.lane).max() ?? 0) + 1 }

    private var timelineHeight: CGFloat { min(250, 150 + CGFloat(laneCount) * 34) }

    private var wideTimelineHeight: CGFloat { min(320, 170 + CGFloat(laneCount) * 38) }

    /// LAY-3: the selection's tools as a grid, or the open panel (no grabber, no swipe-down).
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let panel = model.panel, panel != .captionText, panel != .export {
                ScrollView {
                    panelView(panel)
                }
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity)
            } else {
                Text(sidebarTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                    .accessibilityIdentifier("sidebar.title")
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        currentTools
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
        .environment(\.inSidebar, true)
        .animation(.easeOut(duration: 0.2), value: model.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.sidebar")
    }

    /// The sidebar heading: what the tools act on.
    private var sidebarTitle: String {
        switch model.session.selection {
        case .none: return "Project"
        case .clip: return model.selectedClip?.isStill == true ? "Photo" : "Video Clip"
        case .text: return "Text"
        case .audio: return model.selectedAudio?.role == .music ? "Music" : "Audio"
        case .captions: return "Captions"
        }
    }

    private func openExport() {
        guard model.duration > .zero else { return }
        model.pause()
        showExport = true
    }

    /// The timeline "+" and the empty preview open the Photos library directly (IMP-1, PRV-7). UI tests and demos
    /// (-sampleMedia / -demoMedia) get the Add menu instead, to pick the bundled Sample Clips.
    private func addMedia() {
        if LaunchOptions.useSampleMedia || LaunchOptions.demoMediaFolder != nil {
            showAddMenu = true
        } else {
            model.pause()
            showPicker = true
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                Task { await model.close(); onClose() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).background(Theme.surface, in: Circle())
            }
            .accessibilityIdentifier("editor.close")
            Button { model.panel = .canvas } label: {
                Text(model.project.aspectRatio.rawValue).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).frame(height: 32).background(Theme.surface, in: Capsule())
            }
            .accessibilityIdentifier("editor.aspect")
            Spacer()
            // Shown only when they can do something: none in a new project, Redo only after an Undo.
            if model.session.canUndo {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityIdentifier("editor.undo")
                    .transition(.opacity)
            }
            if model.session.canRedo {
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityIdentifier("editor.redo")
                    .transition(.opacity)
            }
            // Hidden while there's nothing to export (the edit has no length yet).
            if model.duration > .zero {
                Button {
                    openExport()
                } label: {
                    Text("Export").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).frame(height: 34)
                        .background(Theme.accent, in: Capsule())
                }
                .accessibilityIdentifier("editor.export")
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: model.session.canUndo)
        .animation(.easeOut(duration: 0.2), value: model.session.canRedo)
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            Text(model.currentTime.timecode).monospacedDigit().accessibilityIdentifier("time.current")
            Text("/ \(model.duration.timecode)").monospacedDigit().foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("time.total")
            if LaunchOptions.isUITesting {
                Text(model.trimDebug).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("debug.trim")
                // Reads previewRate so it refreshes when the speed changes.
                Text(String(format: "%g/%g", model.previewRate == model.player.defaultRate ? model.player.defaultRate : -1, model.debugRate)).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("debug.rate")
            }
            Spacer()
            // PRV-9: preview-only play speed (export is unaffected).
            PreviewRatePicker(model: model)
        }
        // Play stays centred under the preview.
        .overlay {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22)).frame(width: 44, height: 36)
            }
            .accessibilityIdentifier("editor.play")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .zIndex(1)   // the speed picker opens upwards over the preview
    }

    // MARK: Bottom: tools or panel

    @ViewBuilder
    private var bottomArea: some View {
        Group {
            if let panel = model.panel {
                panelView(panel).transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                toolbar
            }
        }
        .animation(.spring(duration: 0.28), value: model.panel)
    }

    @ViewBuilder
    private func panelView(_ panel: EditorPanel) -> some View {
        switch panel {
        case .canvas: CanvasPanel(model: model)
        case .music: MusicPanel(model: model)
        case .captions: CaptionsPanel(model: model)
        case .captionText: toolbar   // shown full screen (see .fullScreenCover)
        case .duck:
            if let id = model.selectedAudioID { DuckPanel(model: model, audioID: id) } else { toolbar }
        case .text(let id):
            if let id { TextPanel(model: model, textID: id) } else { toolbar }
        case .transition(let id): TransitionPanel(model: model, clipID: id)
        case .textDuration(let id): TextDurationPanel(model: model, textID: id)
        case .textAnimate(let id): TextAnimatePanel(model: model, textID: id)
        case .textPosition(let id): TextPositionPanel(model: model, textID: id)
        case .watermark: WatermarkPanel(model: model)
        case .titleCard(let placement): TitleCardPanel(model: model, placement: placement)
        case .denoise: NoiseReductionPanel(model: model)
        case .trim, .duration, .motion, .filters, .adjust, .speed, .crop, .background:
            if let id = model.selectedClipID {
                switch panel {
                case .trim: TrimPanel(model: model, clipID: id)
                case .motion: PhotoMotionPanel(model: model, clipID: id)
                case .duration: PhotoDurationPanel(model: model, clipID: id)
                case .filters: FiltersPanel(model: model, clipID: id)
                case .adjust: AdjustPanel(model: model, clipID: id)
                case .speed: SpeedPanel(model: model, clipID: id)
                case .crop: CropPanel(model: model, clipID: id)
                default: BackgroundPanel(model: model, clipID: id)
                }
            } else {
                toolbar
            }
        case .export: toolbar
        }
    }

    /// The tools for the current selection: one list for the phone toolbar and the wide sidebar grid.
    @ViewBuilder private var currentTools: some View {
        switch model.session.selection {
        case .clip: clipTools
        case .text(let id): textTools(id)
        case .audio: audioTools
        case .captions: captionTools
        case .none: mainTools
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                currentTools
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 74)
        .background(Theme.surface)
        .accessibilityIdentifier("toolbar")
    }

    @ViewBuilder private var mainTools: some View {
        // With no content yet (the edit has no length, as for Export) only Intro and Outro show.
        if model.duration > .zero {
            ToolButton(title: "Music", systemImage: "music.note") { model.select(.none); model.panel = .music }
            // Captions transcribe speech, so they're only offered once there's a video clip (not just photos).
            if model.project.hasVideoClips {
                ToolButton(title: "Captions", systemImage: "captions.bubble", badge: "AI") { model.panel = .captions }
                // DNS-1: one Denoise setting for the whole video.
                ToolButton(title: "Denoise", systemImage: "waveform",
                           isActive: model.project.noiseReduction != nil || model.project.clips.contains { $0.noiseReduction != nil }) {
                    model.select(.none); model.panel = .denoise
                }
            }
            ToolButton(title: "Watermark", systemImage: "seal", isActive: model.project.watermark != nil) { model.select(.none); model.panel = .watermark }
            ToolButton(title: "Text", systemImage: "textformat") { model.addText() }
        }
        ToolButton(title: "Intro", systemImage: "rectangle.lefthalf.inset.filled") { model.select(.none); model.panel = .titleCard(.opening) }
        ToolButton(title: "Outro", systemImage: "rectangle.righthalf.inset.filled") { model.select(.none); model.panel = .titleCard(.closing) }
    }

    @ViewBuilder private var clipTools: some View {
        if model.selectedClip?.isStill == true {
            photoTools
        } else {
            videoTools
        }
    }

    /// Photos and freeze frames: only tools that make sense for a still image.
    @ViewBuilder private var photoTools: some View {
        ToolButton(title: "Duration", systemImage: "timer") { model.panel = .duration }
        ToolButton(title: "Animate", systemImage: "camera.metering.center.weighted",
                   isActive: (model.selectedClip?.photoMotion ?? .none) != .none
                       || !(model.selectedClip?.animation?.isEmpty ?? true)) { model.panel = .motion }
        ToolButton(title: "Filters", systemImage: "camera.filters") { model.panel = .filters }
        ToolButton(title: "Adjust", systemImage: "slider.horizontal.3") { model.panel = .adjust }
        ToolButton(title: "Enhance", systemImage: "wand.and.stars", badge: "AI") { model.autoEnhance() }
        ToolButton(title: "Cutout", systemImage: "person.crop.rectangle", badge: "AI") { model.panel = .background }
        ToolButton(title: "Crop", systemImage: "crop.rotate") { model.panel = .crop }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelected() }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }

    @ViewBuilder private var videoTools: some View {
        ToolButton(title: "Split", systemImage: "scissors") { model.split() }
        // Voice: the clip's own sound on/off. Highlighted (and slashed) while it's off.
        ToolButton(title: "Voice", systemImage: model.selectedClip?.isMuted == true ? "mic.slash" : "mic",
                   isActive: model.selectedClip?.isMuted == true) { model.toggleVoice() }
        ToolButton(title: "Speed", systemImage: "speedometer") { model.panel = .speed }
        ToolButton(title: "Animate", systemImage: "camera.metering.center.weighted",
                   isActive: !(model.selectedClip?.animation?.isEmpty ?? true)) { model.panel = .motion }
        ToolButton(title: "Filters", systemImage: "camera.filters") { model.panel = .filters }
        ToolButton(title: "Adjust", systemImage: "slider.horizontal.3") { model.panel = .adjust }
        ToolButton(title: "Enhance", systemImage: "wand.and.stars", badge: "AI") { model.autoEnhance() }
        ToolButton(title: "Cutout", systemImage: "person.crop.rectangle", badge: "AI") { model.panel = .background }
        ToolButton(title: "Reframe", systemImage: "viewfinder", badge: "AI") { model.autoReframe() }
        ToolButton(title: "Crop", systemImage: "crop.rotate") { model.panel = .crop }
        ToolButton(title: "Reverse", systemImage: "backward.fill", isActive: model.selectedClip?.isReversed == true) { model.reverseSelected() }
        ToolButton(title: "Freeze", systemImage: "snowflake") { model.freezeFrame() }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelected() }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }

    @ViewBuilder private func textTools(_ id: UUID) -> some View {
        let overlay = model.project.textOverlays.first { $0.id == id }
        ToolButton(title: "Edit", systemImage: "character.cursor.ibeam") { model.panel = .text(id) }
        ToolButton(title: "Duration", systemImage: "timer") { model.panel = .textDuration(id) }
        ToolButton(title: "Animate", systemImage: "camera.metering.center.weighted",
                   isActive: !(overlay?.animation?.isEmpty ?? true)) { model.panel = .textAnimate(id) }
        ToolButton(title: "Position", systemImage: "square.grid.3x3", isActive: overlay?.anchor != nil) { model.panel = .textPosition(id) }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") {
            var newID: UUID?
            model.edit("Duplicate text") { newID = $0.duplicateText(id) }
            if let newID { model.select(.text(newID)) }
        }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }

    @ViewBuilder private var audioTools: some View {
        ToolButton(title: "Cut", systemImage: "scissors") { model.cutSelectedAudio() }
        if model.canStartSelectedAudioHere {
            ToolButton(title: "Start Here", systemImage: "arrow.right.to.line") { model.startSelectedAudioHere() }
        }
        if model.selectedAudio?.role == .music {
            ToolButton(title: "Duck", systemImage: "waveform.badge.minus") { model.panel = .duck }
        }
        if model.canMoveSelectedAudioToStart {
            ToolButton(title: "Move to Start", systemImage: "arrow.left.to.line") { model.moveSelectedAudioToStart() }
        }
        if model.canRepeatSelectedAudio {
            ToolButton(title: "Repeat", systemImage: "repeat") { model.repeatSelectedAudio() }
        }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }

    @ViewBuilder private var captionTools: some View {
        ToolButton(title: "Edit", systemImage: "character.cursor.ibeam") { model.panel = .captionText }
        ToolButton(title: "Style", systemImage: "paintbrush") { model.panel = .captions }
        ToolButton(title: "Fillers", systemImage: "text.badge.minus") { model.removeCaptionFillers() }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }
}

// MARK: - Wide screens and keyboard (LAY-5, LAY-6)

extension View {
    /// Full-screen sheets (Export, caption editor) stay at most 720 pt wide, centred (LAY-6).
    func centeredOnWideScreens() -> some View {
        frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(Theme.background.ignoresSafeArea())
    }
}

/// LAY-5: hardware-keyboard shortcuts. Invisible buttons, so they also show in the system's
/// shortcut overlay. Keys without a modifier (and undo / redo) are off while a panel with a text
/// field is open, so typing never triggers them.
struct EditorShortcuts: View {
    @Bindable var model: EditorModel
    let onExport: () -> Void

    private var typing: Bool {
        switch model.panel {
        case .text, .captionText, .watermark, .titleCard: return true
        default: return false
        }
    }

    private static let frame = MediaTime(seconds: 1.0 / 30)
    private static let second = MediaTime(seconds: 1)

    var body: some View {
        ZStack {
            shortcut("Play / Pause", .space, [], enabled: !typing) { model.togglePlay() }
            shortcut("Previous Frame", .leftArrow, [], enabled: !typing) { step(by: .zero - Self.frame) }
            shortcut("Next Frame", .rightArrow, [], enabled: !typing) { step(by: Self.frame) }
            shortcut("Back 1 Second", .leftArrow, .shift, enabled: !typing) { step(by: .zero - Self.second) }
            shortcut("Forward 1 Second", .rightArrow, .shift, enabled: !typing) { step(by: Self.second) }
            shortcut("Undo", "z", .command, enabled: !typing && model.session.canUndo) { model.undo() }
            shortcut("Redo", "z", [.command, .shift], enabled: !typing && model.session.canRedo) { model.redo() }
            shortcut("Split", "b", .command, enabled: model.duration > .zero) { model.split() }
            shortcut("Delete", .delete, [], enabled: !typing && model.session.selection != .none) { model.deleteSelection() }
            // .cancelAction is the Esc key; a plain .escape shortcut isn't delivered on iPad.
            if model.panel != nil || model.session.selection != .none {
                Button("Close") {
                    if model.panel != nil { model.panel = nil } else { model.select(.none) }
                }
                .keyboardShortcut(.cancelAction)
            }
            shortcut("Export", "e", .command, enabled: model.duration > .zero) { onExport() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func step(by delta: MediaTime) {
        model.pause()
        model.seek(to: model.currentTime + delta)
    }

    /// Shortcuts with ⌘ stay in place and are disabled when they can't act. Plain keys (Space,
    /// arrows, Delete) are only present while they can act: a disabled one could still capture
    /// its key, for example the space bar while typing a caption.
    @ViewBuilder
    private func shortcut(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers,
                          enabled: Bool, action: @escaping () -> Void) -> some View {
        if modifiers.contains(.command) {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .disabled(!enabled)
        } else if enabled {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: modifiers)
        }
    }
}

// MARK: - Photo picker import

struct MovieTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieTransfer(url: dest)
        }
    }
}

enum PhotoImport {
    static func load(_ items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
               let movie = try? await item.loadTransferable(type: MovieTransfer.self) {
                urls.append(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
        }
        return urls
    }
}


/// PRV-9: preview play speed. A small button shows the speed; tapping it opens a column of round
/// buttons above it (fastest on top). Its own view, so it doesn't redraw with the playhead and
/// taps aren't lost while playing.
struct PreviewRatePicker: View {
    @Bindable var model: EditorModel
    @State private var isOpen = false

    /// "0.5×", "1×", "1.25×".
    static func title(_ rate: Float) -> String { String(format: "%g×", rate) }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { isOpen.toggle() }
        } label: {
            Text(Self.title(model.previewRate)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(isOpen || model.previewRate != 1 ? 0.28 : 0.12)))
        }
        .accessibilityIdentifier("preview.rate")
        .accessibilityLabel("Play speed \(Self.title(model.previewRate))")
        .overlay(alignment: .bottom) {
            if isOpen {
                VStack(spacing: 8) {
                    ForEach(EditorModel.previewRates.reversed(), id: \.self) { rate in
                        let selected = rate == model.previewRate
                        Button {
                            model.previewRate = rate
                            // Picked while paused: play at the new speed straight away.
                            if !model.isPlaying { model.togglePlay() }
                            withAnimation(.spring(duration: 0.25)) { isOpen = false }
                        } label: {
                            Text(Self.title(rate))
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(selected ? .black : .white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.75)))
                                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rate.\(Self.title(rate))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(6)
                .background(Capsule().fill(.black.opacity(0.35)))
                .offset(y: -34)
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
    }
}
