import SwiftUI
import EditorKit

/// Bottom panel container – slides up over the toolbar.
struct PanelContainer<Content: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: title, onDone: onDone)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
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
    var body: some View {
        PanelContainer(title: "Canvas", onDone: { model.panel = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(AspectRatio.allCases) { r in
                        ChipButton(title: r.rawValue, isSelected: model.project.aspectRatio == r) {
                            model.edit("Aspect ratio") { $0.aspectRatio = r }
                        }
                    }
                }
                Text("Background").font(.subheadline).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 12) {
                    ChipButton(title: "Blur", isSelected: model.project.background == .blur) {
                        model.edit("Background") { $0.background = .blur }
                    }
                    SwatchRow(selected: { if case .color(let c) = model.project.background { return c }; return nil }()) { c in
                        if let c { model.edit("Background") { $0.background = .color(c) } }
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

enum FilterPreviewRenderer {
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
                                model.player.play()
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
                    ToolButton(title: clip?.transform.fit == .fill ? "Fit" : "Fill", systemImage: "arrow.up.left.and.arrow.down.right") {
                        update("Fit") { $0.fit = $0.fit == .fill ? .fit : .fill }
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
                VStack(spacing: 12) {
                    TextField("Enter text", text: Binding(get: { overlay.text }, set: { v in update("Edit text", coalesce: true) { $0.text = v } }),
                              axis: .vertical)
                        .focused($focused)
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TextAnimation.allCases) { a in
                                ChipButton(title: a.displayName, isSelected: overlay.animationIn == a) {
                                    update("Animation") { $0.animationIn = a }
                                    model.seek(to: overlay.range.start)
                                    model.player.play()
                                }
                            }
                        }
                    }
                    LabeledSlider(title: "Size", value: Binding(get: { overlay.style.size }, set: { v in update("Text size", coalesce: true) { $0.style.size = v } }),
                                  range: 0.03...0.16, format: { String(format: "%.0f", $0 * 1000) })
                    LabeledSlider(title: "Duration", value: Binding(get: { overlay.range.duration.seconds }, set: { v in
                        update("Text duration", coalesce: true) { $0.range.duration = MediaTime(seconds: v) }
                    }), range: 0.5...15, format: { String(format: "%.1fs", $0) })
                }
            }
        }
    }
}

// MARK: - Music

struct MusicPanel: View {
    @Bindable var model: EditorModel
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
