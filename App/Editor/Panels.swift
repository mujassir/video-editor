import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import EditorKit

/// Bottom panel container – slides up over the toolbar.
struct PanelContainer<Content: View>: View {
    let title: String
    let onDone: () -> Void
    var onUndo: (() -> Void)? = nil
    var canUndo = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: title, onDone: onDone, onUndo: onUndo, canUndo: canUndo)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.\(title)")
    }
}

private let swatches: [RGBAColor] = [
    .white, .black, RGBAColor(r: 1, g: 0.86, b: 0.1), RGBAColor(r: 1, g: 0.24, b: 0.38),
    RGBAColor(r: 0.25, g: 0.55, b: 1), RGBAColor(r: 0.2, g: 0.8, b: 0.55), RGBAColor(r: 0.65, g: 0.4, b: 0.95),
    RGBAColor(r: 1, g: 0.55, b: 0.15),
]

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

struct SwatchRow: View {
    let selected: RGBAColor?
    var includeNone = false
    let onPick: (RGBAColor?) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if includeNone {
                    Button { onPick(nil) } label: {
                        Image(systemName: "nosign").frame(width: 30, height: 30)
                            .background(Theme.surfaceRaised, in: Circle())
                            .overlay(Circle().stroke(selected == nil ? Color.white : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityIdentifier("swatch.none")
                }
                ForEach(Array(swatches.enumerated()), id: \.offset) { i, c in
                    Button { onPick(c) } label: {
                        Circle().fill(c.color).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(selected == c ? Color.white : Theme.stroke, lineWidth: selected == c ? 2.5 : 1))
                    }.buttonStyle(.plain).accessibilityIdentifier("swatch.\(i)")
                }
            }.padding(.vertical, 2)
        }
    }
}

// MARK: - Canvas

struct CanvasPanel: View {
    @Bindable var model: EditorModel
    /// Canvas fit as set by the user, else what the first clip uses.
    private var currentFit: ContentFit { model.project.defaultFit ?? model.project.clips.first?.transform.fit ?? .fit }
    private var currentAnchor: ContentAnchor { model.project.defaultAnchor ?? model.project.clips.first?.transform.anchor ?? .center }
    var body: some View {
        PanelContainer(title: "Canvas", onDone: { model.panel = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AspectRatio.allCases) { r in
                            ChipButton(title: r.rawValue, isSelected: model.project.aspectRatio == r) {
                                model.edit("Aspect ratio") { $0.aspectRatio = r }
                            }
                        }
                    }
                }
                Text("Media that doesn't fit").font(.subheadline).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    ForEach([ContentFit.fit, .fill, .stretch], id: \.self) { fit in
                        ChipButton(title: fit.displayName, isSelected: currentFit == fit) {
                            model.edit("Canvas fit") { $0.setContentFit(fit, anchor: currentAnchor) }
                        }
                    }
                }
                if currentFit != .stretch {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ContentAnchor.allCases) { anchor in
                                ChipButton(title: anchor.displayName, isSelected: currentAnchor == anchor) {
                                    model.edit("Canvas position") { $0.setContentFit(currentFit, anchor: anchor) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Filters

struct FiltersPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @State private var previews: [String: UIImage] = [:]

    private var clip: VideoClip? { model.project.clipIndex(clipID).map { model.project.clips[$0] } }

    var body: some View {
        PanelContainer(title: "Filters", onDone: { model.panel = nil }) {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        filterTile(id: nil, name: "None")
                        ForEach(FilterLibrary.presets) { p in filterTile(id: p.id, name: p.name) }
                    }
                }
                if let filter = clip?.filter {
                    LabeledSlider(title: "Intensity", value: Binding(
                        get: { filter.intensity },
                        set: { v in model.editCoalescing("Filter intensity", key: "fi-\(clipID)") { p in
                            try? p.updateClip(clipID) { $0.filter?.intensity = v }
                        } }), range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
                }
            }
        }
        .task { await renderPreviews() }
    }

    private func filterTile(id: String?, name: String) -> some View {
        let selected = clip?.filter?.filterID == id
        return Button {
            model.edit("Filter") { p in try p.updateClip(clipID) { $0.filter = id.map { FilterSetting(filterID: $0) } } }
            model.showCleanFrameOfSelection()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let img = previews[id ?? "none"] {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Theme.surfaceRaised
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : .clear, lineWidth: 2.5))
                Text(name).font(.caption2).foregroundStyle(selected ? Theme.accent : .white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.\(id ?? "none")")
    }

    /// Thumbnail of the clip run through every LUT on the CPU (tiny images, so instant).
    private func renderPreviews() async {
        guard let clip, let media = model.project.mediaItem(clip.mediaID) else { return }
        let url = model.resolver.url(for: media)
        let base: CGImage?
        if media.kind == .photo {
            base = MediaImporter.loadImage(url, maxPixelSize: 120)
        } else {
            base = try? await MediaImporter.frame(of: url, at: clip.sourceRange.start + MediaTime(seconds: 0.1),
                                                  maxSize: CGSize(width: 120, height: 120))
        }
        guard let base else { return }
        let results = await Task.detached { () -> [String: UIImage] in
            var out: [String: UIImage] = ["none": UIImage(cgImage: base)]
            for p in FilterLibrary.presets {
                if let img = FilterPreviewRenderer.apply(p, to: base) { out[p.id] = UIImage(cgImage: img) }
            }
            return out
        }.value
        previews = results
    }
}

nonisolated enum FilterPreviewRenderer {
    static func apply(_ preset: FilterPreset, to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: data.count, by: 4) {
            let c = preset.apply(SIMD3(Float(data[i]) / 255, Float(data[i + 1]) / 255, Float(data[i + 2]) / 255))
            data[i] = UInt8(c.x * 255); data[i + 1] = UInt8(c.y * 255); data[i + 2] = UInt8(c.z * 255)
        }
        return ctx.makeImage()
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID

    private func binding(_ key: WritableKeyPath<ColorAdjustments, Double>, _ name: String) -> Binding<Double> {
        Binding(
            get: { model.project.clipIndex(clipID).map { model.project.clips[$0].adjustments[keyPath: key] } ?? 0 },
            set: { v in model.editCoalescing(name, key: "adj-\(name)-\(clipID)") { p in
                try? p.updateClip(clipID) { $0.adjustments[keyPath: key] = v }
            } })
    }

    var body: some View {
        PanelContainer(title: "Adjust", onDone: { model.panel = nil }) {
            VStack(spacing: 8) {
                HStack {
                    Button { model.autoEnhance() } label: {
                        Label("Auto Enhance", systemImage: "wand.and.stars").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("adjust.auto")
                    Spacer()
                    Button("Reset") {
                        model.edit("Reset adjustments") { p in try p.updateClip(clipID) { $0.adjustments = .neutral } }
                    }.font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        LabeledSlider(title: "Exposure", value: binding(\.exposure, "Exposure"))
                        LabeledSlider(title: "Contrast", value: binding(\.contrast, "Contrast"))
                        LabeledSlider(title: "Saturation", value: binding(\.saturation, "Saturation"))
                        LabeledSlider(title: "Warmth", value: binding(\.warmth, "Warmth"))
                        LabeledSlider(title: "Highlights", value: binding(\.highlights, "Highlights"))
                        LabeledSlider(title: "Shadows", value: binding(\.shadows, "Shadows"))
                        LabeledSlider(title: "Vignette", value: binding(\.vignette, "Vignette"), range: 0...1,
                                      format: { String(format: "%.0f", $0 * 100) })
                        LabeledSlider(title: "Sharpen", value: binding(\.sharpen, "Sharpen"), range: 0...1,
                                      format: { String(format: "%.0f", $0 * 100) })
                    }
                }.frame(maxHeight: 190)
            }
        }
    }
}

// MARK: - Speed / volume

struct SpeedPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var speed: Double { model.project.clipIndex(clipID).map { model.project.clips[$0].speed } ?? 1 }

    var body: some View {
        PanelContainer(title: "Speed", onDone: { model.panel = nil }) {
            VStack(spacing: 14) {
                Text(String(format: "%.2g×", speed)).font(.title2.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("speed.value")
                // Log scale so 0.1× … 10× feels even.
                Slider(value: Binding(get: { log10(speed) }, set: { v in
                    let s = (pow(10, v) * 20).rounded() / 20
                    model.editCoalescing("Speed", key: "speed-\(clipID)") { p in try? p.setSpeed(s, clipID: clipID) }
                }), in: -1...1).tint(Theme.accent).accessibilityIdentifier("slider.Speed")
                HStack {
                    ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { v in
                        ChipButton(title: String(format: "%g×", v), isSelected: abs(speed - v) < 0.01) {
                            model.edit("Speed") { try $0.setSpeed(v, clipID: clipID) }
                        }
                    }
                }
            }
        }
    }
}

struct VolumePanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var clip: VideoClip? { model.project.clipIndex(clipID).map { model.project.clips[$0] } }

    var body: some View {
        PanelContainer(title: "Volume", onDone: { model.panel = nil }) {
            VStack(spacing: 12) {
                LabeledSlider(title: "Volume", value: Binding(get: { clip?.volume ?? 1 }, set: { v in
                    model.editCoalescing("Volume", key: "vol-\(clipID)") { p in try? p.updateClip(clipID) { $0.volume = v } }
                }), range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })
                HStack {
                    ChipButton(title: clip?.isMuted == true ? "Unmute" : "Mute", isSelected: clip?.isMuted == true) {
                        model.edit("Mute") { p in try p.updateClip(clipID) { $0.isMuted.toggle() } }
                    }
                    ChipButton(title: "Extract Audio") { model.extractAudio() }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Transition

struct TransitionPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var transition: EditorKit.Transition? { model.project.clipIndex(clipID).flatMap { model.project.clips[$0].transitionOut } }

    var body: some View {
        PanelContainer(title: "Transition", onDone: { model.panel = nil }) {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ChipButton(title: "None", isSelected: transition == nil) {
                        model.edit("Transition") { try $0.setTransition(nil, after: clipID) }
                    }
                    ForEach(TransitionKind.allCases) { k in
                        ChipButton(title: k.displayName, isSelected: transition?.kind == k) {
                            model.edit("Transition") {
                                try $0.setTransition(EditorKit.Transition(kind: k, duration: transition?.duration ?? MediaTime(seconds: 0.5)), after: clipID)
                            }
                            if let entry = model.project.layout.entry(for: clipID) {
                                model.seek(to: max(.zero, entry.range.end - entry.overlapOut - MediaTime(seconds: 0.4)))
                                model.play()
                            }
                        }
                    }
                }
                if let t = transition {
                    LabeledSlider(title: "Duration", value: Binding(get: { t.duration.seconds }, set: { v in
                        model.editCoalescing("Transition length", key: "tl-\(clipID)") { p in
                            try? p.setTransition(EditorKit.Transition(kind: t.kind, duration: MediaTime(seconds: v)), after: clipID)
                        }
                    }), range: 0.2...2, format: { String(format: "%.1fs", $0) })
                }
            }
        }
    }
}

// MARK: - Crop & rotate

struct CropPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var clip: VideoClip? { model.project.clipIndex(clipID).map { model.project.clips[$0] } }

    private func update(_ label: String, _ change: @escaping (inout ClipTransform) -> Void) {
        model.edit(label) { p in try p.updateClip(clipID) { change(&$0.transform) } }
    }

    var body: some View {
        PanelContainer(title: "Crop", onDone: { model.panel = nil }) {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    ToolButton(title: "Rotate", systemImage: "rotate.right") { update("Rotate") { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } }
                    ToolButton(title: "Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { update("Flip") { $0.flipHorizontal.toggle() } }
                    ToolButton(title: "Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { update("Flip") { $0.flipVertical.toggle() } }
                    // Per-clip override of the canvas fit: Fit → Fill → Stretch.
                    ToolButton(title: (clip?.transform.fit ?? .fit).displayName, systemImage: "arrow.up.left.and.arrow.down.right") {
                        update("Fit") { t in
                            switch t.fit {
                            case .fit: t.fit = .fill
                            case .fill: t.fit = .stretch
                            case .stretch: t.fit = .fit
                            }
                        }
                    }
                }
                LabeledSlider(title: "Zoom", value: Binding(get: { clip?.transform.scale ?? 1 }, set: { v in
                    model.editCoalescing("Zoom", key: "zoom-\(clipID)") { p in try? p.updateClip(clipID) { $0.transform.scale = v } }
                }), range: 0.5...3, format: { String(format: "%.1f×", $0) })
                HStack {
                    ForEach(["Original", "1:1", "4:5", "16:9"], id: \.self) { name in
                        ChipButton(title: name) { update("Crop") { $0.crop = cropRect(name) } }
                    }
                }
            }
        }
    }

    /// Centred crop of the source to a ratio.
    private func cropRect(_ name: String) -> CropRect {
        guard let clip, let media = model.project.mediaItem(clip.mediaID), name != "Original" else { return .full }
        let target: Double = name == "1:1" ? 1 : (name == "4:5" ? 0.8 : 16.0 / 9.0)
        let source = media.naturalSize.width / max(media.naturalSize.height, 1)
        if source > target {
            let w = target / source
            return CropRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = source / target
        return CropRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

// MARK: - Background removal

struct BackgroundPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var current: BackgroundReplacement? { model.project.clipIndex(clipID).flatMap { model.project.clips[$0].backgroundRemoval } }

    var body: some View {
        PanelContainer(title: "Remove Background", onDone: { model.panel = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cuts out people automatically – no green screen.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 10) {
                    ChipButton(title: "Off", isSelected: current == nil) { model.setBackgroundRemoval(nil) }
                    ChipButton(title: "Blur", isSelected: current == .blur) { model.setBackgroundRemoval(.blur) }
                    ChipButton(title: "Canvas", isSelected: current == .transparent) { model.setBackgroundRemoval(.transparent) }
                }
                SwatchRow(selected: { if case .color(let c) = current { return c }; return nil }()) { c in
                    if let c { model.setBackgroundRemoval(.color(c)) }
                }
            }
        }
    }
}

// MARK: - Text

struct TextPanel: View {
    @Bindable var model: EditorModel
    let textID: UUID
    @FocusState private var focused: Bool

    private var overlay: TextOverlay? { model.project.textOverlays.first { $0.id == textID } }
    private let fonts: [(String, String)] = [
        ("Bold", "HelveticaNeue-Bold"), ("Classic", "Georgia-Bold"), ("Rounded", "ArialRoundedMTBold"),
        ("Condensed", "Futura-CondensedExtraBold"), ("Elegant", "Didot-Bold"), ("Mono", "Menlo-Bold"),
        ("Script", "SnellRoundhand-Black"), ("Heavy", "AvenirNext-Heavy"),
    ]

    private func update(_ label: String, coalesce: Bool = false, _ change: @escaping (inout TextOverlay) -> Void) {
        if coalesce {
            model.editCoalescing(label, key: "\(label)-\(textID)") { $0.updateText(textID, change) }
        } else {
            model.edit(label) { $0.updateText(textID, change) }
        }
    }

    var body: some View {
        PanelContainer(title: "Text", onDone: { focused = false; model.panel = nil }) {
            if let overlay {
                ScrollView {
                VStack(spacing: 12) {
                    TextField("Enter text", text: Binding(get: { overlay.text }, set: { v in update("Edit text", coalesce: true) { $0.text = v } }))
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { focused = false }
                        .padding(10)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("text.field")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(fonts, id: \.1) { name, font in
                                Button { update("Font") { $0.style.fontName = font } } label: {
                                    Text(name).font(.custom(font, size: 15))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(overlay.style.fontName == font ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                                }.buttonStyle(.plain).accessibilityIdentifier("font.\(name)")
                            }
                        }
                    }
                    SwatchRow(selected: overlay.style.color) { c in if let c { update("Text color") { $0.style.color = c } } }
                    HStack(spacing: 8) {
                        ChipButton(title: "Outline", isSelected: overlay.style.outlineColor != nil) {
                            update("Outline") {
                                if $0.style.outlineColor == nil { $0.style.outlineColor = .black; $0.style.outlineWidth = 0.08 }
                                else { $0.style.outlineColor = nil; $0.style.outlineWidth = 0 }
                            }
                        }
                        ChipButton(title: "Label", isSelected: overlay.style.backgroundColor != nil) {
                            update("Label") { $0.style.backgroundColor = $0.style.backgroundColor == nil ? RGBAColor(r: 0, g: 0, b: 0, a: 0.6) : nil }
                        }
                        ChipButton(title: "Shadow", isSelected: overlay.style.shadow) { update("Shadow") { $0.style.shadow.toggle() } }
                    }
                    LabeledSlider(title: "Size", value: Binding(get: { overlay.style.size }, set: { v in update("Text size", coalesce: true) { $0.style.size = v } }),
                                  range: 0.03...0.16, format: { String(format: "%.0f", $0 * 1000) })
                }
                }
                .frame(maxHeight: 300)
            }
        }
    }
}

// MARK: - Music

struct MusicPanel: View {
    @Bindable var model: EditorModel
    @State private var videoItem: PhotosPickerItem?
    var selectedAudio: AudioClip? {
        if case .audio(let id) = model.session.selection { return model.project.audioClips.first { $0.id == id } }
        return nil
    }

    var body: some View {
        PanelContainer(title: "Music", onDone: { model.panel = nil }) {
            VStack(spacing: 10) {
                if let audio = selectedAudio {
                    LabeledSlider(title: "Volume", value: Binding(get: { audio.volume }, set: { v in
                        model.editCoalescing("Music volume", key: "mv-\(audio.id)") { $0.updateAudio(audio.id) { $0.volume = v } }
                    }), range: 0...1.5, format: { String(format: "%.0f%%", $0 * 100) })
                    LabeledSlider(title: "Fade out", value: Binding(get: { audio.fadeOut.seconds }, set: { v in
                        model.editCoalescing("Fade", key: "fo-\(audio.id)") { $0.updateAudio(audio.id) { $0.fadeOut = MediaTime(seconds: v) } }
                    }), range: 0...5, format: { String(format: "%.1fs", $0) })
                    Toggle("Auto-duck under speech", isOn: Binding(get: { audio.autoDuck }, set: { v in
                        model.edit("Auto duck") { $0.updateAudio(audio.id) { $0.autoDuck = v } }
                    })).tint(Theme.accent).font(.subheadline)
                } else {
                    HStack(spacing: 8) {
                        sourceButton("Files", "folder") { model.openFiles(for: .music) }
                        PhotosPicker(selection: $videoItem, matching: .videos) {
                            MusicSourceLabel(title: "From Video", icon: "film")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("music.source.video")
                    }
                    Text("Built-in tracks").font(.caption).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(SampleMedia.library) { track in
                        HStack {
                            Image(systemName: "music.note").frame(width: 36, height: 36)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(track.name).font(.subheadline.weight(.semibold))
                                Text("\(track.mood) · \(Int(track.bpm)) BPM").font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button("Use") { model.addMusic(track); model.panel = nil }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Theme.accent, in: Capsule())
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("music.use.\(track.id)")
                        }
                    }
                    Text("Royalty-free · generated on device").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            videoItem = nil
            Task {
                guard let movie = try? await item.loadTransferable(type: MovieTransfer.self) else {
                    model.showToast("Couldn't load that video", systemImage: "exclamationmark.triangle")
                    return
                }
                model.addMusicFile(movie.url, name: "Video sound")
                model.panel = nil
            }
        }
    }

    private func sourceButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { MusicSourceLabel(title: title, icon: icon) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("music.source.\(title.lowercased())")
    }
}

// MARK: - Captions

struct CaptionsPanel: View {
    @Bindable var model: EditorModel
    private var track: CaptionTrack { model.project.captions }

    var body: some View {
        PanelContainer(title: "Captions", onDone: { model.panel = nil }) {
            VStack(spacing: 12) {
                if track.segments.isEmpty {
                    VStack(spacing: 8) {
                        Text("Transcribe speech into animated captions.\nRuns entirely on your iPhone.")
                            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
                        Button { model.generateCaptions() } label: {
                            Label("Generate Captions", systemImage: "captions.bubble.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityIdentifier("captions.generate")
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(CaptionPreset.allCases) { p in
                            ChipButton(title: p.displayName, isSelected: track.preset == p) {
                                model.edit("Caption style") { $0.captions.preset = p }
                            }
                        }
                    }
                    SwatchRow(selected: track.highlightColor) { c in if let c { model.edit("Highlight") { $0.captions.highlightColor = c } } }
                    LabeledSlider(title: "Position", value: Binding(get: { track.positionY }, set: { v in
                        model.editCoalescing("Caption position", key: "cp") { $0.captions.positionY = v }
                    }), range: 0.1...0.92, format: { String(format: "%.0f%%", $0 * 100) })
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(track.segments.enumerated()), id: \.element.id) { i, seg in
                                HStack(alignment: .top) {
                                    Text(seg.range.start.timecode).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                                        .frame(width: 48, alignment: .leading)
                                    TextField("", text: Binding(get: { seg.text }, set: { v in
                                        model.editCoalescing("Edit caption", key: "cap-\(seg.id)") { p in
                                            guard i < p.captions.segments.count else { return }
                                            p.captions.segments[i].words = Self.retime(v, like: p.captions.segments[i])
                                        }
                                    }))
                                    .font(.subheadline)
                                    .accessibilityIdentifier("caption.field.\(i)")
                                }
                            }
                        }
                    }.frame(maxHeight: 110)
                }
            }
        }
    }

    /// Re-spreads edited text over the original segment timing.
    static func retime(_ text: String, like segment: CaptionSegment) -> [CaptionWord] {
        let range = segment.range
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let each = range.duration.seconds / Double(words.count)
        return words.enumerated().map { i, w in
            CaptionWord(text: w, range: MediaTimeRange(start: range.start + MediaTime(seconds: Double(i) * each),
                                                       duration: MediaTime(seconds: each)))
        }
    }
}

// MARK: - Precise trim

struct TrimPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var clip: VideoClip? { model.project.clipIndex(clipID).map { model.project.clips[$0] } }
    private var mediaDuration: Double {
        clip.flatMap { model.project.mediaItem($0.mediaID) }.map { max($0.duration.seconds, 0.2) } ?? 1
    }

    var body: some View {
        PanelContainer(title: "Trim", onDone: { model.panel = nil }) {
            if let clip, !clip.isStill {
                VStack(spacing: 10) {
                    LabeledSlider(title: "Start", value: Binding(get: { clip.sourceRange.start.seconds }, set: { v in
                        model.editCoalescing("Trim", key: "trim-start-\(clipID)") { p in
                            let end = clip.sourceRange.end.seconds
                            try? p.setSourceRange(clipID: clipID, MediaTimeRange(start: MediaTime(seconds: min(v, end - 0.1)), end: clip.sourceRange.end))
                        }
                    }), range: 0...mediaDuration, format: { String(format: "%.1fs", $0) })
                    LabeledSlider(title: "End", value: Binding(get: { clip.sourceRange.end.seconds }, set: { v in
                        model.editCoalescing("Trim", key: "trim-end-\(clipID)") { p in
                            let start = clip.sourceRange.start.seconds
                            try? p.setSourceRange(clipID: clipID, MediaTimeRange(start: clip.sourceRange.start, end: MediaTime(seconds: max(v, start + 0.1))))
                        }
                    }), range: 0...mediaDuration, format: { String(format: "%.1fs", $0) })
                    Text("Or drag the white handles on the timeline").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            } else {
                Text("Photos and freeze frames: drag the handle to change length.").font(.footnote)
            }
        }
    }
}

// MARK: - Animate (In / Out / Combo / Motion)

struct PhotoMotionPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @State private var tab: Tab = .entrance

    enum Tab: String, CaseIterable, Identifiable {
        case entrance = "In", exit = "Out", combo = "Combo", motion = "Motion"
        var id: String { rawValue }
    }

    private var clip: VideoClip? { model.project.clipIndex(clipID).map { model.project.clips[$0] } }
    private var anim: ClipAnimation { clip?.animation ?? ClipAnimation() }
    private var tabs: [Tab] { clip?.isStill == true ? Tab.allCases : [.entrance, .exit, .combo] }
    private var motion: PhotoMotion { clip?.photoMotion ?? .none }

    var body: some View {
        PanelContainer(title: "Animate", onDone: { model.panel = nil }) {
            VStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("animate.tabs")
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        switch tab {
                        case .entrance, .exit:
                            tile("None", "nosign", selected: (tab == .entrance ? anim.entrance : anim.exit) == nil,
                                 id: "anim.\(tab.rawValue).none") { setEntrance(nil) }
                            ForEach(ClipEntrance.allCases) { k in
                                tile(k.displayName, k.systemImage,
                                     selected: (tab == .entrance ? anim.entrance : anim.exit) == k,
                                     id: "anim.\(tab.rawValue).\(k.rawValue)") { setEntrance(k) }
                            }
                        case .combo:
                            tile("None", "nosign", selected: anim.combo == nil, id: "anim.combo.none") { setCombo(nil) }
                            ForEach(ClipCombo.allCases) { k in
                                tile(k.displayName, k.systemImage, selected: anim.combo == k,
                                     id: "anim.combo.\(k.rawValue)") { setCombo(k) }
                            }
                        case .motion:
                            ForEach(PhotoMotion.allCases) { m in
                                tile(m.displayName, m.systemImage, selected: motion == m, id: "motion.\(m.rawValue)") { setMotion(m) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
                if tab == .entrance || tab == .exit {
                    LabeledSlider(title: "Length", value: Binding(
                        get: { tab == .entrance ? anim.inDuration : anim.outDuration },
                        set: { v in
                            let out = tab == .exit
                            model.editCoalescing("Animation length", key: "alen-\(tab.rawValue)-\(clipID)") { p in
                                try? p.updateClip(clipID) { c in
                                    var a = c.animation ?? ClipAnimation()
                                    if out { a.outDuration = v } else { a.inDuration = v }
                                    c.animation = a
                                }
                            }
                        }), range: 0.2...3, format: { String(format: "%.1fs", $0) })
                }
                if model.project.clips.count > 1 {
                    Button { applyToAll() } label: {
                        Label(tab == .motion ? "Apply to all photos" : "Apply to all clips", systemImage: "square.stack.3d.down.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("animate.applyAll")
                }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(selected ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func setEntrance(_ kind: ClipEntrance?) {
        let out = tab == .exit
        model.edit(out ? "Out animation" : "In animation") { p in
            try p.updateClip(clipID) { c in
                var a = c.animation ?? ClipAnimation()
                if out { a.exit = kind } else { a.entrance = kind }
                c.animation = a.isEmpty ? nil : a
            }
        }
        preview(atEnd: out)
    }

    private func setCombo(_ kind: ClipCombo?) {
        model.edit("Combo animation") { p in
            try p.updateClip(clipID) { c in
                var a = c.animation ?? ClipAnimation()
                a.combo = kind
                c.animation = a.isEmpty ? nil : a
            }
        }
        preview(atEnd: false)
    }

    private func setMotion(_ m: PhotoMotion) {
        model.edit("Animate photo") { try $0.setPhotoMotion(m, clipID: clipID) }
        preview(atEnd: false)
    }

    private func applyToAll() {
        if tab == .motion {
            model.edit("Animate photos") { try $0.setPhotoMotion(motion, clipID: clipID, allPhotos: true) }
            model.showToast("Applied to all photos", systemImage: "square.stack.3d.down.right")
        } else {
            let a = anim
            model.edit("Animate all clips") { p in
                for i in p.clips.indices { p.clips[i].animation = a.isEmpty ? nil : a }
            }
            model.showToast("Applied to all clips", systemImage: "square.stack.3d.down.right")
        }
    }

    /// Plays the part of the clip where the chosen animation happens.
    private func preview(atEnd: Bool) {
        guard let entry = model.project.layout.entry(for: clipID) else { return }
        let lead = MediaTime(seconds: min(1.5, entry.range.duration.seconds))
        model.seek(to: atEnd ? max(entry.range.start, entry.range.end - lead) : entry.range.start)
        model.play()
    }
}

// MARK: - Photo duration

struct PhotoDurationPanel: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    private var seconds: Double {
        model.project.clipIndex(clipID).map { model.project.clips[$0].sourceRange.duration.seconds } ?? 3
    }
    private var photoCount: Int { model.project.clips.filter { $0.kind == .photo }.count }

    var body: some View {
        PanelContainer(title: "Duration", onDone: { model.panel = nil }) {
            VStack(spacing: 12) {
                Text(String(format: "%.1f s", seconds)).font(.title2.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("duration.value")
                Slider(value: Binding(get: { seconds }, set: { v in
                    let rounded = (v * 10).rounded() / 10
                    model.editCoalescing("Photo duration", key: "dur-\(clipID)") { p in
                        try? p.setStillDuration(MediaTime(seconds: rounded), clipID: clipID)
                    }
                }), in: 0.5...30).tint(Theme.accent).accessibilityIdentifier("slider.Duration")
                HStack(spacing: 8) {
                    ForEach([2.0, 3, 5, 10], id: \.self) { v in
                        ChipButton(title: String(format: "%gs", v), isSelected: abs(seconds - v) < 0.05) {
                            model.edit("Photo duration") { try $0.setStillDuration(MediaTime(seconds: v), clipID: clipID) }
                        }
                    }
                }
                if photoCount > 1 {
                    Button {
                        let d = MediaTime(seconds: seconds)
                        model.edit("Photo duration") { try $0.setStillDuration(d, clipID: clipID, allPhotos: true) }
                        model.showToast("All photos set to \(String(format: "%.1f", seconds)) s", systemImage: "timer")
                    } label: {
                        Label("Apply to all \(photoCount) photos", systemImage: "square.stack.3d.down.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("duration.applyAll")
                }
            }
        }
    }
}

struct MusicSourceLabel: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }
}

// MARK: - Audio editor (full screen)

/// A kept (not deleted) section placed on the played timeline.
struct KeptSegment: Equatable {
    let index: Int          // index into the clip's sections
    let start: Double       // song time
    let end: Double
    let volume: Double
    let offset: Double      // where it starts in the played music
    var duration: Double { end - start }
}

/// Full-screen audio editor. Only the music that plays is shown: deleted sections
/// are cut out and the rest closes up, on the waveform, play bar and timer alike.
/// Tap the waveform to select a section (own volume / delete); drag the play-bar
/// knob to move the playing position; markers split the music into sections.
struct AudioEditorView: View {
    @Bindable var model: EditorModel
    let audioID: UUID
    @State private var selectedSection: Int?
    @State private var preview = AudioPreview()
    @State private var resumeAfterScrub = false

    private var clip: AudioClip? { model.project.audioClips.first { $0.id == audioID } }
    private var media: MediaItem? { clip.flatMap { model.project.mediaItem($0.mediaID) } }
    private var sections: [AudioSection] { clip?.resolvedSections ?? [] }

    private var kept: [KeptSegment] {
        var out: [KeptSegment] = [], offset = 0.0
        for (k, s) in sections.enumerated() where !s.deleted {
            out.append(KeptSegment(index: k, start: s.start.seconds, end: s.end.seconds, volume: s.volume, offset: offset))
            offset += s.end.seconds - s.start.seconds
        }
        return out
    }
    private var playedLength: Double { kept.last.map { $0.offset + $0.duration } ?? 0 }
    private var songEnd: Double { kept.last?.end ?? (clip?.sourceRange.end.seconds ?? 0) }

    /// Song time → position in the played music (a deleted part maps to where the next kept part starts).
    private func toPlayed(_ t: Double) -> Double {
        for seg in kept {
            if t < seg.start { return seg.offset }
            if t < seg.end { return seg.offset + (t - seg.start) }
        }
        return playedLength
    }

    /// Position in the played music → song time.
    private func toSong(_ p: Double) -> Double {
        for seg in kept where p < seg.offset + seg.duration { return seg.start + max(0, p - seg.offset) }
        return songEnd
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    timer
                    AudioWaveEditor(peaks: media.flatMap { model.waveforms[$0.id] } ?? [],
                                    songLength: max(media?.duration.seconds ?? 1, 0.5),
                                    segments: kept, selected: selectedSection,
                                    cursor: toPlayed(preview.position),
                                    onTapSection: { k in selectedSection = k })
                        .frame(height: 150)
                        .accessibilityIdentifier("audioEditor.wave")
                    scrubBar
                    controls
                    if let k = selectedSection, sections.indices.contains(k), !sections[k].deleted { sectionPanel(k) }
                    overall
                    Text(clip.map { "\(Self.time($0.playedDuration.seconds)) of music · \(sections.count) section\(sections.count == 1 ? "" : "s")\(sections.contains { $0.deleted } ? " · \(sections.filter(\.deleted).count) deleted" : "")" } ?? "")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("audioTrim.summary")
                }
                .padding(16)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            model.pause()
            if let media { preview.load(model.resolver.url(for: media)) }
            syncPreview()
            preview.seekIdle(to: toSong(0))
        }
        .onDisappear { preview.stop() }
        .onChange(of: clip?.sections) { _, _ in syncPreview(); keepPositionInMusic() }
        .onChange(of: clip?.volume) { _, _ in syncPreview() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Audio").font(.headline)
                Text(clip?.name.isEmpty == false ? clip!.name : "Music").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button { preview.stop(); model.undo(); clampSelection() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36).background(Theme.surfaceRaised, in: Circle())
            }
            .disabled(!model.session.canUndo)
            .accessibilityIdentifier("panel.undo")
            Button { preview.stop(); model.panel = nil } label: {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36).background(Theme.accent, in: Circle())
            }
            .accessibilityIdentifier("panel.done")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
    }

    /// Live position in the played music.
    private var timer: some View {
        VStack(spacing: 2) {
            Text(Self.time(toPlayed(preview.position))).font(.system(size: 34, weight: .semibold).monospacedDigit())
                .accessibilityIdentifier("audioEditor.timer")
            Text("of \(Self.time(playedLength))")
                .font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
        }
    }

    /// Single-line play bar: drag the knob to move the playing position.
    private var scrubBar: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { min(max(toPlayed(preview.position), 0), playedLength) },
                                  set: { p in preview.seekIdle(to: toSong(p)) }),
                   in: 0...max(playedLength, 0.1)) { editing in
                if editing {
                    resumeAfterScrub = preview.isPlaying
                    preview.pause()
                } else if resumeAfterScrub {
                    resumeAfterScrub = false
                    preview.play(from: preview.position, to: songEnd)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("audioEditor.scrub")
            HStack {
                Text("0:00").accessibilityIdentifier("audioEditor.startLabel")
                Spacer()
                Text(Self.clock(playedLength)).accessibilityIdentifier("audioEditor.endLabel")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { togglePreview() } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .bold))
                    .frame(width: 52, height: 52).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("audioTrim.play")
            Button { addMarker() } label: {
                Label("Add Marker", systemImage: "flag").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("audioEditor.addMarker")
        }
        .foregroundStyle(.white)
    }

    private func sectionPanel(_ k: Int) -> some View {
        let s = sections[k]
        let number = (kept.firstIndex { $0.index == k } ?? 0) + 1
        let start = toPlayed(s.start.seconds), length = s.end.seconds - s.start.seconds
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Section \(number) of \(kept.count)").font(.subheadline.weight(.semibold))
                Text("\(Self.clock(start)) – \(Self.clock(start + length))").font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("audioEditor.section")
            LabeledSlider(title: "Volume", value: Binding(get: { s.volume }, set: { v in
                model.editCoalescing("Section volume", key: "secvol-\(audioID)-\(k)") { p in
                    try? p.setAudioSectionVolume(audioID, index: k, v)
                }
            }), range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })
            HStack(spacing: 10) {
                Button(role: .destructive) { deleteSection(k) } label: {
                    Label("Delete section", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.surfaceRaised, in: Capsule())
                }
                .disabled(kept.count < 2)
                .accessibilityIdentifier("audioEditor.deleteSection")
                if k + 1 < sections.count, !sections[k + 1].deleted {
                    Button {
                        model.edit("Remove marker") { try $0.removeAudioMarker(audioID, after: k) }
                        clampSelection()
                    } label: {
                        Label("Remove marker", systemImage: "flag.slash").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.surfaceRaised, in: Capsule())
                    }
                    .accessibilityIdentifier("audioEditor.removeMarker")
                }
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var overall: some View {
        VStack(spacing: 10) {
            if let clip {
                LabeledSlider(title: "Volume", value: Binding(get: { clip.volume }, set: { v in
                    model.editCoalescing("Music volume", key: "mv-\(audioID)") { $0.updateAudio(audioID) { $0.volume = v } }
                }), range: 0...1.5, format: { String(format: "%.0f%%", $0 * 100) })
                if sections.count > 1 {
                    Button("Clear all markers") {
                        preview.stop()
                        model.edit("Clear markers") { try $0.clearAudioMarkers(audioID) }
                        selectedSection = nil
                    }
                    .font(.subheadline).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("audioEditor.clearMarkers")
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    private func syncPreview() {
        preview.sections = clip?.resolvedSections ?? []
        preview.baseVolume = clip?.volume ?? 1
    }

    /// After sections change (delete, undo, clear), park the playhead on music that plays.
    private func keepPositionInMusic() {
        clampSelection()
        let t = preview.position
        let inKept = kept.contains { t >= $0.start && t < $0.end }
        if !inKept { preview.seekIdle(to: toSong(min(toPlayed(t), max(0, playedLength - 0.05)))) }
    }

    private func clampSelection() {
        if let k = selectedSection, k >= sections.count || sections[k].deleted { selectedSection = nil }
    }

    private func deleteSection(_ k: Int) {
        preview.stop()
        model.edit("Delete section") { try $0.setAudioSectionDeleted(audioID, index: k, true) }
        selectedSection = nil
    }

    private func togglePreview() {
        if preview.isPlaying {
            preview.pause()
        } else {
            let p = toPlayed(preview.position)
            preview.play(from: toSong(p < playedLength - 0.05 ? p : 0), to: songEnd)
        }
    }

    /// Marker at the playback position. If a marker can't go there (at an edge or
    /// right on another marker), it splits the selected section — or the longest one — in half.
    private func addMarker() {
        let gap = 0.25   // engine minimum section (0.2 s) plus slack
        var t = preview.position
        if !kept.contains(where: { t > $0.start + gap && t < $0.end - gap }) {
            let target = kept.first { $0.index == selectedSection && $0.duration > gap * 2 }
                ?? kept.max { $0.duration < $1.duration }
            guard let target, target.duration > gap * 2 else {
                model.showToast("Section too short for another marker")
                return
            }
            t = (target.start + target.end) / 2
        }
        model.edit("Add marker") { try $0.addAudioMarker(audioID, at: MediaTime(seconds: t)) }
        selectedSection = clip?.resolvedSections.firstIndex { t >= $0.start.seconds && t < $0.end.seconds }
        if !preview.isPlaying { preview.seekIdle(to: t) }
    }

    /// m:ss for the play-bar labels.
    static func clock(_ v: Double) -> String {
        let t = Int(max(v, 0).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func time(_ v: Double) -> String {
        let t = max(v, 0)
        return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// Waveform of the music that plays: kept sections back to back, the selected one
/// highlighted, markers between sections and the play cursor. Tapping selects a section.
struct AudioWaveEditor: View {
    let peaks: [Float]
    let songLength: Double
    let segments: [KeptSegment]
    let selected: Int?
    var cursor: Double
    var onTapSection: (Int) -> Void = { _ in }

    private var total: Double { segments.last.map { $0.offset + $0.duration } ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let span = max(total, 0.001)
            let x = { (p: Double) -> CGFloat in CGFloat(p / span) * geo.size.width }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for seg in segments where seg.index == selected {
                        let r = CGRect(x: x(seg.offset), y: 0, width: max(1, x(seg.offset + seg.duration) - x(seg.offset)), height: size.height)
                        ctx.fill(Path(r), with: .color(Theme.accent.opacity(0.25)))
                    }
                    guard !peaks.isEmpty, songLength > 0 else { return }
                    let perSecond = Double(peaks.count) / songLength
                    for seg in segments {
                        let first = max(0, Int(seg.start * perSecond))
                        let last = min(peaks.count, Int(ceil(seg.end * perSecond)))
                        guard last > first else { continue }
                        let x0 = x(seg.offset), w = x(seg.offset + seg.duration) - x0
                        let barW = w / CGFloat(last - first)
                        let gain = CGFloat(min(1, seg.volume))
                        for i in first..<last {
                            let h = max(2, CGFloat(peaks[i]) * (size.height - 16) * max(0.08, gain))
                            let rect = CGRect(x: x0 + CGFloat(i - first) * barW, y: (size.height - h) / 2,
                                              width: max(0.5, barW - 0.5), height: h)
                            ctx.fill(Path(rect), with: .color(Theme.clipAudio.opacity(0.9)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let p = Double(loc.x / max(geo.size.width, 1)) * span
                    if let seg = segments.first(where: { p < $0.offset + $0.duration }) ?? segments.last {
                        onTapSection(seg.index)
                    }
                }
                ForEach(Array(segments.dropFirst().enumerated()), id: \.offset) { _, seg in
                    Rectangle().fill(Color.yellow).frame(width: 2).offset(x: x(seg.offset) - 1)
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                                .offset(x: x(seg.offset) + 3, y: 2)
                        }
                        .allowsHitTesting(false)
                }
                Rectangle().fill(Color.white).frame(width: 2).offset(x: x(cursor) - 1)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("audioTrim.cursor")
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Plays the song for the editor: skips deleted sections and applies each section's volume.
@Observable
final class AudioPreview {
    private(set) var isPlaying = false
    var position: Double = 0
    @ObservationIgnored var sections: [AudioSection] = []
    @ObservationIgnored var baseVolume: Double = 1
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endTime: Double = 0
    @ObservationIgnored private var pendingSeek: Double?

    func load(_ url: URL) {
        player = AVPlayer(url: url)
        player?.automaticallyWaitsToMinimizeStalling = false
    }

    func seekIdle(to t: Double) {
        stop()
        position = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(from start: Double, to end: Double) {
        guard let player else { return }
        removeObserver()
        endTime = end
        // Never start inside a deleted section: begin where the next kept part starts.
        let begin = playableTime(from: start)
        position = begin
        pendingSeek = nil
        apply(at: begin)
        player.seek(to: CMTime(seconds: begin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.player?.play()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        isPlaying = true
    }

    /// First time at or after `t` that isn't in a deleted section.
    private func playableTime(from t: Double) -> Double {
        var t = t
        while let s = sections.first(where: { t >= $0.start.seconds && t < $0.end.seconds }), s.deleted { t = s.end.seconds }
        return t
    }

    private func tick(_ t: Double) {
        if pendingSeek != nil { return }   // jumping over a deleted section
        position = t
        if t >= endTime - 0.02 { pause(); position = endTime; return }
        apply(at: t)
    }

    /// Section volume, and jump over deleted sections (one seek at a time).
    private func apply(at t: Double) {
        guard let s = sections.first(where: { t >= $0.start.seconds && t < $0.end.seconds }) else {
            player?.volume = Float(baseVolume)
            return
        }
        if s.deleted {
            let target = playableTime(from: t)
            if target >= endTime - 0.02 { pause(); position = endTime; return }
            pendingSeek = target
            position = target
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.pendingSeek = nil }
            }
            return
        }
        player?.volume = Float(min(1, baseVolume * s.volume))
    }

    func pause() {
        pendingSeek = nil
        player?.pause()
        removeObserver()
        isPlaying = false
    }

    func stop() { pause() }

    private func removeObserver() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

// MARK: - Text: duration, animation, position

struct TextDurationPanel: View {
    @Bindable var model: EditorModel
    let textID: UUID
    private var overlay: TextOverlay? { model.project.textOverlays.first { $0.id == textID } }

    var body: some View {
        PanelContainer(title: "Text Duration", onDone: { model.panel = nil }) {
            if let overlay {
                VStack(spacing: 12) {
                    Text(String(format: "%.1f s · starts %@", overlay.range.duration.seconds, overlay.range.start.timecode))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .accessibilityIdentifier("textDuration.value")
                    Slider(value: Binding(get: { overlay.range.duration.seconds }, set: { v in
                        let r = (v * 10).rounded() / 10
                        model.editCoalescing("Text duration", key: "tdur-\(textID)") { $0.setTextDuration(textID, MediaTime(seconds: r)) }
                    }), in: 0.5...30).tint(Theme.accent).accessibilityIdentifier("slider.TextDuration")
                    HStack(spacing: 8) {
                        ForEach([2.0, 3, 5, 10], id: \.self) { v in
                            ChipButton(title: String(format: "%gs", v), isSelected: abs(overlay.range.duration.seconds - v) < 0.05) {
                                model.edit("Text duration") { $0.setTextDuration(textID, MediaTime(seconds: v)) }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        ChipButton(title: "Start at playhead") {
                            model.edit("Move text") { $0.moveText(textID, toStart: model.currentTime) }
                        }
                        ChipButton(title: "Whole video") {
                            model.edit("Text duration") { p in
                                p.moveText(textID, toStart: .zero)
                                p.setTextDuration(textID, max(MediaTime(seconds: 0.5), p.layout.duration))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TextAnimatePanel: View {
    @Bindable var model: EditorModel
    let textID: UUID
    @State private var tab: Tab = .entrance

    enum Tab: String, CaseIterable, Identifiable {
        case entrance = "In", exit = "Out", combo = "Combo"
        var id: String { rawValue }
    }

    private var overlay: TextOverlay? { model.project.textOverlays.first { $0.id == textID } }
    private var anim: ClipAnimation { overlay?.animation ?? ClipAnimation() }

    var body: some View {
        PanelContainer(title: "Animate Text", onDone: { model.panel = nil }) {
            VStack(spacing: 10) {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("textAnimate.tabs")
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        switch tab {
                        case .entrance, .exit:
                            AnimationTile(title: "None", icon: "nosign",
                                          selected: (tab == .entrance ? anim.entrance : anim.exit) == nil,
                                          id: "tanim.\(tab.rawValue).none") { setEntrance(nil) }
                            ForEach(ClipEntrance.allCases) { k in
                                AnimationTile(title: k.displayName, icon: k.systemImage,
                                              selected: (tab == .entrance ? anim.entrance : anim.exit) == k,
                                              id: "tanim.\(tab.rawValue).\(k.rawValue)") { setEntrance(k) }
                            }
                        case .combo:
                            AnimationTile(title: "None", icon: "nosign", selected: anim.combo == nil, id: "tanim.combo.none") { setCombo(nil) }
                            ForEach(ClipCombo.allCases) { k in
                                AnimationTile(title: k.displayName, icon: k.systemImage, selected: anim.combo == k,
                                              id: "tanim.combo.\(k.rawValue)") { setCombo(k) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
                if tab != .combo {
                    LabeledSlider(title: "Length", value: Binding(
                        get: { tab == .entrance ? anim.inDuration : anim.outDuration },
                        set: { v in
                            let out = tab == .exit
                            model.editCoalescing("Text animation length", key: "talen-\(tab.rawValue)-\(textID)") { p in
                                p.updateText(textID) { t in
                                    var a = t.animation ?? ClipAnimation()
                                    if out { a.outDuration = v } else { a.inDuration = v }
                                    t.animation = a
                                }
                            }
                        }), range: 0.2...3, format: { String(format: "%.1fs", $0) })
                }
            }
        }
    }

    private func change(_ label: String, _ f: @escaping (inout ClipAnimation) -> Void, previewAtEnd: Bool) {
        model.edit(label) { p in
            p.updateText(textID) { t in
                var a = t.animation ?? ClipAnimation()
                f(&a)
                t.animation = a
                t.animationIn = .none
                t.animationOut = .none
            }
        }
        guard let overlay else { return }
        let lead = MediaTime(seconds: min(1.5, overlay.range.duration.seconds))
        model.seek(to: previewAtEnd ? max(overlay.range.start, overlay.range.end - lead) : overlay.range.start)
        model.play()
    }

    private func setEntrance(_ k: ClipEntrance?) {
        let out = tab == .exit
        change(out ? "Text out animation" : "Text in animation", { a in if out { a.exit = k } else { a.entrance = k } }, previewAtEnd: out)
    }

    private func setCombo(_ k: ClipCombo?) {
        change("Text combo", { $0.combo = k }, previewAtEnd: false)
    }
}

struct AnimationTile: View {
    let title: String
    let icon: String
    let selected: Bool
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(selected ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// 3×3 grid of fixed spots, shared by text and watermark.
struct AnchorGrid: View {
    let selected: OverlayAnchor?
    let idPrefix: String
    let onPick: (OverlayAnchor) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(OverlayAnchor.allCases) { a in
                Button { onPick(a) } label: {
                    Text(a.displayName).font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(selected == a ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix).\(a.rawValue)")
            }
        }
    }
}

struct TextPositionPanel: View {
    @Bindable var model: EditorModel
    let textID: UUID
    private var overlay: TextOverlay? { model.project.textOverlays.first { $0.id == textID } }

    /// Pause on a frame where the text is visible, so it can be placed or dragged.
    private func showText() {
        model.pause()
        guard let overlay else { return }
        if !overlay.range.contains(model.currentTime) {
            model.seek(to: overlay.range.start + MediaTime(seconds: min(0.5, overlay.range.duration.seconds / 2)))
        }
    }

    var body: some View {
        PanelContainer(title: "Text Position", onDone: { model.panel = nil }) {
            VStack(spacing: 10) {
                AnchorGrid(selected: overlay?.anchor, idPrefix: "tpos") { a in
                    model.edit("Text position") { $0.setTextAnchor(textID, a) }
                    showText()
                }
                HStack {
                    ChipButton(title: "Custom", isSelected: overlay?.anchor == nil) {
                        model.edit("Text position") { $0.setTextAnchor(textID, nil) }
                        showText()
                    }
                    Spacer()
                }
                Text("Fixed spots keep the text inside the video at that edge. For any other spot, drag the text on the video – that sets Custom.")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - Watermark

struct WatermarkPanel: View {
    @Bindable var model: EditorModel
    @State private var imageItem: PhotosPickerItem?
    private var mark: Watermark? { model.project.watermark }

    var body: some View {
        PanelContainer(title: "Watermark", onDone: { model.panel = nil }) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ChipButton(title: "Text", isSelected: mark?.kind == .text) {
                        model.setWatermark { $0.kind = .text }
                    }
                    PhotosPicker(selection: $imageItem, matching: .images) {
                        Text(mark?.kind == .image ? "Change Image" : "Image")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(mark?.kind == .image ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("watermark.image")
                    Spacer()
                    if mark != nil {
                        Button("Remove", role: .destructive) { model.removeWatermark() }
                            .font(.subheadline).accessibilityIdentifier("watermark.remove")
                    }
                }
                if let mark {
                    if mark.kind == .text {
                        TextField("Watermark text", text: Binding(get: { mark.text }, set: { v in
                            model.editCoalescing("Watermark text", key: "wm-text") { p in p.watermark?.text = v }
                        }))
                        .submitLabel(.done)
                        .padding(10)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("watermark.text")
                    }
                    AnchorGrid(selected: mark.anchor, idPrefix: "wmpos") { a in model.setWatermark { $0.anchor = a } }
                    LabeledSlider(title: "Size", value: Binding(get: { mark.size }, set: { v in
                        model.editCoalescing("Watermark size", key: "wm-size") { p in p.watermark?.size = v }
                    }), range: 0.08...0.5, format: { String(format: "%.0f%%", $0 * 100) })
                    LabeledSlider(title: "Opacity", value: Binding(get: { mark.opacity }, set: { v in
                        model.editCoalescing("Watermark opacity", key: "wm-opacity") { p in p.watermark?.opacity = v }
                    }), range: 0.1...1, format: { String(format: "%.0f%%", $0 * 100) })
                } else {
                    Text("Stamp your name or logo on the whole video, including exports.")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            imageItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.setWatermarkImage(data) }
                else { model.showToast("Couldn't load that image", systemImage: "exclamationmark.triangle") }
            }
        }
    }
}

// MARK: - Opening / closing slides

struct TitleCardPanel: View {
    @Bindable var model: EditorModel
    let placement: TitleCard.Placement
    @State private var draft: TitleCard?
    @State private var seconds: Double = 3

    private var existing: VideoClip? { model.project.titleCardClip(placement) }

    /// The ✓ button adds the slide or saves changes, then closes the panel.
    private func save() {
        if let d = draft {
            let unchanged = existing?.titleCard == d && abs((existing?.sourceRange.duration.seconds ?? -1) - seconds) < 0.05
            if !unchanged { model.applyTitleCard(d, duration: MediaTime(seconds: seconds)) }
        }
        model.panel = nil
    }
    private var name: String { placement == .opening ? "Opening Slide" : "Closing Slide" }

    var body: some View {
        PanelContainer(title: name, onDone: save) {
            if let card = draft {
                VStack(spacing: 10) {
                    TextField("Title", text: Binding(get: { card.title }, set: { draft?.title = $0 }))
                        .submitLabel(.done).padding(10)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("titleCard.title")
                    TextField("Subtitle (optional)", text: Binding(get: { card.subtitle }, set: { draft?.subtitle = $0 }))
                        .submitLabel(.done).padding(10)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("titleCard.subtitle")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(TitleCard.presets) { preset in
                                Button { draft?.apply(preset) } label: {
                                    TitleStyleTile(preset: preset, selected: card.preset?.id == preset.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("titleStyle.\(preset.id)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    LabeledSlider(title: "Duration", value: $seconds, range: 1...10, format: { String(format: "%.1fs", $0) })
                    HStack(spacing: 10) {
                        Text(existing == nil ? "Tap ✓ to add the slide" : "Tap ✓ to save changes")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        if existing != nil {
                            Button(role: .destructive) {
                                model.removeTitleCard(placement)
                                model.panel = nil
                            } label: {
                                Label("Remove", systemImage: "trash").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Theme.surfaceRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("titleCard.remove")
                        }
                    }
                }
            }
        }
        .onAppear {
            if let clip = existing, let card = clip.titleCard {
                draft = card
                seconds = clip.sourceRange.duration.seconds
            } else {
                draft = TitleCard(placement: placement, title: placement == .opening ? model.project.name : "Thanks for watching")
                seconds = 3
            }
        }
    }
}

/// Small preview of a slide style: background, accent bar and sample text.
struct TitleStyleTile: View {
    let preset: TitleCard.Preset
    let selected: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(preset.background.color)
                if preset.gradient {
                    RadialGradient(colors: [preset.accent.color.opacity(0.45), .clear], center: .center,
                                   startRadius: 0, endRadius: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(spacing: 3) {
                    Text("Aa").font(.system(size: 16, weight: .bold)).foregroundStyle(preset.textColor.color)
                    Capsule().fill(preset.accent.color).frame(width: 14, height: 3)
                }
            }
            .frame(width: 62, height: 46)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2.5 : 1))
            Text(preset.name).font(.caption2.weight(.medium)).foregroundStyle(selected ? Theme.accent : .white)
        }
    }
}
