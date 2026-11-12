import SwiftUI
import EditorKit

struct RootView: View {
    @State private var app = AppModel()
    @State private var editor: EditorModel?
    /// The editor was opened from New Project: show the Photos library straight away (LIB-1).
    @State private var startWithPhotos = false

    var body: some View {
        ZStack {
            if let editor {
                EditorView(model: editor, startWithPhotos: startWithPhotos) {
                    let closed = editor.project
                    self.editor = nil
                    if closed.isEmptyEdit {
                        app.delete(closed)      // nothing was added: don't keep a 0:00 project
                    } else {
                        app.reload()
                    }
                }
                .transition(.move(edge: .trailing))
            } else {
                ProjectsView(app: app, onOpen: { project in open(project) },
                             onCreate: { project in open(project, startWithPhotos: true) })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: editor == nil)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func open(_ project: Project, startWithPhotos: Bool = false) {
        guard let fresh = try? app.store.load(project.id) else { return }
        self.startWithPhotos = startWithPhotos
        editor = EditorModel(project: fresh, store: app.store)
    }
}

struct ProjectsView: View {
    let app: AppModel
    let onOpen: (Project) -> Void
    /// A new project was created (opens the editor with the Photos library).
    let onCreate: (Project) -> Void
    @State private var renaming: Project?
    @State private var newName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    newProjectCard
                    if !app.projects.isEmpty {
                        Text("Recent").font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(app.projects) { project in
                                ProjectCard(project: project, thumbnail: app.store.thumbnailURL(for: project.id))
                                    .onTapGesture { onOpen(project) }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") { newName = project.name; renaming = project }
                                        Button("Duplicate", systemImage: "plus.square.on.square") { app.duplicate(project) }
                                        Button("Delete", systemImage: "trash", role: .destructive) { app.delete(project) }
                                    }
                            }
                        }
                    }
                    privacyNote
                }
                .padding(18)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cutline")
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let p = renaming { app.rename(p, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private var newProjectCard: some View {
        Button {
            if let project = try? app.createProject() { onCreate(project) }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Project").font(.title3.weight(.bold))
                    Text("Edit videos and photos with on-device AI").font(.subheadline).opacity(0.85)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(LinearGradient(colors: [Theme.accent, Color(red: 0.55, green: 0.2, blue: 0.95)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("projects.new")
    }

    private var privacyNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.accent)
            Text("Everything runs on your iPhone. No account, no uploads, no watermark.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 8)
    }
}

struct ProjectCard: View {
    let project: Project
    let thumbnail: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The column decides the size; the thumbnail (any aspect ratio) fills it and is cropped,
            // so a wide 16:9 cover can't push past the card into its neighbour.
            Theme.surfaceRaised
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .overlay {
                    if let image = UIImage(contentsOfFile: thumbnail.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title).foregroundStyle(Theme.secondaryText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottomTrailing) {
                Text(project.duration.timecode)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(project.modifiedAt, style: .relative).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.card")
    }
}

/// Generated or bundled sample clips for UI tests and the demo.
enum SampleImport {
    static func importSamples(into model: EditorModel) async {
        var urls: [URL] = []
        if let folder = LaunchOptions.demoMediaFolder,
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            urls = files.filter { ["mov", "mp4", "m4v", "jpg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("samples", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model.busyMessage = "Preparing samples…"
            for (i, hue) in [0.02, 0.55, 0.8].enumerated() {
                let video = dir.appendingPathComponent("sample\(i)-v.mov")
                let audio = dir.appendingPathComponent("sample\(i)-a.m4a")
                let out = dir.appendingPathComponent("sample\(i).mov")
                if !FileManager.default.fileExists(atPath: out.path) {
                    try? await SampleMedia.makeVideo(url: video, size: CGSize(width: 1280, height: 720), duration: 4,
                                                     draw: SampleMedia.animated(hue: hue))
                    try? SampleMedia.renderTonePattern([(true, 1.2), (false, 1.3), (true, 1.5)], to: audio)
                    try? await SampleMedia.mux(video: video, audio: audio, to: out)
                }
                urls.append(out)
            }
        }
        await model.importMedia(urls: urls)
        if LaunchOptions.sampleCaptions {
            model.edit("Sample captions") { p in
                p.captions.segments = [("Um hello there", 0.5), ("This is a caption", 3.0), ("Thanks for watching, uh", 6.0), ("Ah", 8.0)].map { text, start in
                    let words = text.split(separator: " ").enumerated().map { i, w in
                        CaptionWord(text: String(w), range: MediaTimeRange(start: MediaTime(seconds: start + Double(i) * 0.4),
                                                                           duration: MediaTime(seconds: 0.4)))
                    }
                    return CaptionSegment(words: words)
                }
            }
        }
    }
}
