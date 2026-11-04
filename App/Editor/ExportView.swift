import SwiftUI
import AVKit
import EditorKit

struct ExportView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()
    @State private var progress: Double?
    @State private var outputURL: URL?
    @State private var error: String?
    @State private var saved = false
    @State private var elapsed: TimeInterval = 0
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let outputURL {
                    done(outputURL)
                } else if let progress {
                    exporting(progress)
                } else {
                    options
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.disabled(progress != nil && outputURL == nil)
                        .accessibilityIdentifier("export.close")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Resolution") {
                ForEach(ExportSettings.Resolution.allCases) { r in
                    ChipButton(title: r.label, isSelected: settings.resolution == r) { settings.resolution = r }
                }
            }
            section("Frame rate") {
                ForEach([24, 30, 60], id: \.self) { f in
                    ChipButton(title: "\(f) fps", isSelected: settings.frameRate == f) { settings.frameRate = f }
                }
            }
            section("Format") {
                ForEach(ExportSettings.Codec.allCases) { c in
                    ChipButton(title: c.label, isSelected: settings.codec == c) { settings.codec = c }
                }
            }
            let size = model.project.aspectRatio.renderSize(shortEdge: settings.resolution.rawValue)
            Text("\(Int(size.width))×\(Int(size.height)) · \(model.duration.timecode) · hardware encoded")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            Button(action: start) {
                Text("Export Video").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("export.start")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) { content() }
        }
    }

    private func exporting(_ p: Double) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60)
            ZStack {
                Circle().stroke(Theme.surfaceRaised, lineWidth: 10)
                Circle().trim(from: 0, to: p).stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(p * 100))%").font(.title.monospacedDigit().weight(.bold))
            }
            .frame(width: 150, height: 150)
            .accessibilityIdentifier("export.progress")
            Text("Rendering with the Metal compositor and hardware encoder").font(.footnote)
                .multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(model.project.aspectRatio.value, contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Label("Exported in \(String(format: "%.1f", elapsed))s", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
                .accessibilityIdentifier("export.done")
            HStack(spacing: 12) {
                Button {
                    Task {
                        do { try await Exporter.saveToPhotos(url); saved = true }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("export.save")
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(model.project.name.replacingOccurrences(of: " ", with: "-"))-\(Int(Date().timeIntervalSince1970)).mp4")
        progress = 0
        error = nil
        let started = Date()
        let project = model.project
        let resolver = model.resolver
        let settings = settings
        Task {
            do {
                try await Exporter.export(project: project, resolver: resolver, settings: settings, to: url) { p in
                    Task { @MainActor in self.progress = max(self.progress ?? 0, p) }
                }
                elapsed = Date().timeIntervalSince(started)
                outputURL = url
                player = AVPlayer(url: url)
                player?.play()
            } catch {
                self.error = "Export failed: \(error.localizedDescription)"
                progress = nil
            }
        }
    }
}
