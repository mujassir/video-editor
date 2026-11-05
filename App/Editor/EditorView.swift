import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import EditorKit

struct EditorView: View {
    @State var model: EditorModel
    let onClose: () -> Void
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showExport = false
    @State private var showAddMenu = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            PreviewView(model: model)
                .padding(.horizontal, 8)
                .frame(minHeight: 150, maxHeight: .infinity)
            transport
            TimelineRepresentable(model: model, onAddMedia: { showAddMenu = true })
                .frame(height: timelineHeight)
            bottomArea
                .layoutPriority(1)
        }
        .background(Theme.background.ignoresSafeArea())
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
            ExportView(model: model)
        }
        .fullScreenCover(isPresented: Binding(get: { model.panel == .audioTrim && model.selectedAudioID != nil },
                                              set: { if !$0, model.panel == .audioTrim { model.panel = nil } })) {
            if let id = model.selectedAudioID { AudioEditorView(model: model, audioID: id) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }

    private var timelineHeight: CGFloat {
        let lanes = (model.project.audioClips.map(\.lane).max() ?? 0) + 1
        return min(250, 150 + CGFloat(lanes) * 34)
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
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.session.canUndo).accessibilityIdentifier("editor.undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.session.canRedo).accessibilityIdentifier("editor.redo")
            Button {
                model.pause()
                showExport = true
            } label: {
                Text("Export").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(model.project.clips.isEmpty)
            .accessibilityIdentifier("editor.export")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            Text(model.currentTime.timecode).monospacedDigit().accessibilityIdentifier("time.current")
            Text("/ \(model.duration.timecode)").monospacedDigit().foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("time.total")
            if LaunchOptions.isUITesting {
                Text(model.trimDebug).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("debug.trim")
            }
            Spacer()
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22)).frame(width: 44, height: 36)
            }
            .accessibilityIdentifier("editor.play")
            Spacer()
            Button { model.split() } label: {
                Image(systemName: "scissors").frame(width: 44, height: 36)
            }
            .disabled(model.project.clips.isEmpty)
            .accessibilityIdentifier("editor.splitQuick")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
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
        case .audioTrim:
            toolbar   // the audio editor is presented full screen (see fullScreenCover)
        case .captions: CaptionsPanel(model: model)
        case .text(let id):
            if let id { TextPanel(model: model, textID: id) } else { toolbar }
        case .transition(let id): TransitionPanel(model: model, clipID: id)
        case .textDuration(let id): TextDurationPanel(model: model, textID: id)
        case .textAnimate(let id): TextAnimatePanel(model: model, textID: id)
        case .textPosition(let id): TextPositionPanel(model: model, textID: id)
        case .watermark: WatermarkPanel(model: model)
        case .titleCard(let placement): TitleCardPanel(model: model, placement: placement)
        case .trim, .duration, .motion, .filters, .adjust, .speed, .volume, .crop, .background:
            if let id = model.selectedClipID {
                switch panel {
                case .trim: TrimPanel(model: model, clipID: id)
                case .motion: PhotoMotionPanel(model: model, clipID: id)
                case .duration: PhotoDurationPanel(model: model, clipID: id)
                case .filters: FiltersPanel(model: model, clipID: id)
                case .adjust: AdjustPanel(model: model, clipID: id)
                case .speed: SpeedPanel(model: model, clipID: id)
                case .volume: VolumePanel(model: model, clipID: id)
                case .crop: CropPanel(model: model, clipID: id)
                default: BackgroundPanel(model: model, clipID: id)
                }
            } else {
                toolbar
            }
        case .export: toolbar
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                switch model.session.selection {
                case .clip: clipTools
                case .text(let id): textTools(id)
                case .audio: audioTools
                case .captions: captionTools
                case .none: mainTools
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 74)
        .background(Theme.surface)
        .accessibilityIdentifier("toolbar")
    }

    @ViewBuilder private var mainTools: some View {
        ToolButton(title: "Media", systemImage: "plus.rectangle.on.rectangle") { showAddMenu = true }
        ToolButton(title: "Music", systemImage: "music.note") { model.select(.none); model.panel = .music }
        ToolButton(title: "Captions", systemImage: "captions.bubble", badge: "AI") { model.panel = .captions }
        ToolButton(title: "Watermark", systemImage: "seal", isActive: model.project.watermark != nil) { model.select(.none); model.panel = .watermark }
        ToolButton(title: "Text", systemImage: "textformat") { model.addText() }
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
        ToolButton(title: "Trim", systemImage: "timeline.selection") { model.panel = .trim }
        ToolButton(title: "Speed", systemImage: "speedometer") { model.panel = .speed }
        ToolButton(title: "Animate", systemImage: "camera.metering.center.weighted",
                   isActive: !(model.selectedClip?.animation?.isEmpty ?? true)) { model.panel = .motion }
        ToolButton(title: "Volume", systemImage: "speaker.wave.2") { model.panel = .volume }
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
        ToolButton(title: "Edit", systemImage: "slider.horizontal.below.rectangle") { model.panel = .audioTrim }
        ToolButton(title: "Repeat", systemImage: "repeat") { model.repeatSelectedAudio() }
        ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelectedAudio() }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
    }

    @ViewBuilder private var captionTools: some View {
        ToolButton(title: "Style", systemImage: "paintbrush") { model.panel = .captions }
        ToolButton(title: "Delete", systemImage: "trash") { model.deleteSelection() }
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
