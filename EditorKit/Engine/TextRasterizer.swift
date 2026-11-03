import CoreText
import CoreGraphics
import Foundation

/// Rasterizes text and captions into premultiplied BGRA bitmaps with Core Text.
/// Pure Core Graphics, so it is safe on the compositor's background queue.
public enum TextRasterizer {
    public struct Run: Sendable {
        public var text: String
        public var color: RGBAColor
        public init(text: String, color: RGBAColor) {
            self.text = text
            self.color = color
        }
    }

    public struct Style: Sendable {
        public var fontName: String
        public var fontSize: CGFloat
        public var outlineColor: RGBAColor?
        public var outlineWidth: CGFloat
        public var shadow: Bool
        public var glowColor: RGBAColor?
        public var backgroundColor: RGBAColor?
        public var maxWidth: CGFloat
        public init(fontName: String, fontSize: CGFloat, outlineColor: RGBAColor? = nil, outlineWidth: CGFloat = 0,
                    shadow: Bool = true, glowColor: RGBAColor? = nil, backgroundColor: RGBAColor? = nil, maxWidth: CGFloat) {
            self.fontName = fontName
            self.fontSize = fontSize
            self.outlineColor = outlineColor
            self.outlineWidth = outlineWidth
            self.shadow = shadow
            self.glowColor = glowColor
            self.backgroundColor = backgroundColor
            self.maxWidth = maxWidth
        }
    }

    static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func attributed(_ runs: [Run], style: Style) -> NSAttributedString {
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        var alignment = CTTextAlignment.center
        let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                value: &alignment)]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        let result = NSMutableAttributedString()
        for run in runs {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(run.color),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }

    /// Renders runs into an image sized to fit the text plus padding for outline and shadow.
    public static func render(_ runs: [Run], style: Style) -> CGImage? {
        let string = attributed(runs, style: style)
        guard string.length > 0 else { return nil }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let constraint = CGSize(width: style.maxWidth, height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let pad = ceil(style.fontSize * 0.35 + style.outlineWidth * 2)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        let width = Int(textSize.width + pad * 2)
        let height = Int(textSize.height + pad * 2)
        guard width > 0, height > 0, width < 8192, height < 8192 else { return nil }

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        let textRect = CGRect(x: pad, y: pad, width: textSize.width, height: textSize.height)

        if let bg = style.backgroundColor {
            let r = textRect.insetBy(dx: -style.fontSize * 0.3, dy: -style.fontSize * 0.12)
            ctx.setFillColor(cgColor(bg))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: style.fontSize * 0.25, cornerHeight: style.fontSize * 0.25, transform: nil))
            ctx.fillPath()
        }

        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        if let glow = style.glowColor {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: style.fontSize * 0.45, color: cgColor(glow))
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        } else if style.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -style.fontSize * 0.06), blur: style.fontSize * 0.18,
                          color: CGColor(gray: 0, alpha: 0.65))
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }

        if let outline = style.outlineColor, style.outlineWidth > 0 {
            // Stroke pass beneath the fill.
            let stroked = NSMutableAttributedString(attributedString: string)
            let full = NSRange(location: 0, length: stroked.length)
            stroked.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: cgColor(outline), range: full)
            let percent = style.outlineWidth / style.fontSize * 100 * 2
            stroked.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: percent, range: full)
            ctx.setLineJoin(.round)
            let strokeSetter = CTFramesetterCreateWithAttributedString(stroked)
            CTFrameDraw(CTFramesetterCreateFrame(strokeSetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// Convenience for a `TextOverlay` at a given canvas height.
    public static func render(_ overlay: TextOverlay, canvas: CGSize, visibleCharacters: Int? = nil) -> CGImage? {
        var text = overlay.text
        if let n = visibleCharacters { text = String(text.prefix(n)) }
        if text.isEmpty { text = " " }
        let style = Style(fontName: overlay.style.fontName,
                          fontSize: canvas.height * overlay.style.size,
                          outlineColor: overlay.style.outlineColor,
                          outlineWidth: canvas.height * overlay.style.size * overlay.style.outlineWidth,
                          shadow: overlay.style.shadow,
                          backgroundColor: overlay.style.backgroundColor,
                          maxWidth: canvas.width * 0.9)
        return render([Run(text: text, color: overlay.style.color)], style: style)
    }

    /// Renders one caption segment with the active word highlighted per preset.
    public static func renderCaption(_ segment: CaptionSegment, activeWord: Int?, track: CaptionTrack, canvas: CGSize) -> CGImage? {
        let base = canvas.height
        var runs: [Run] = []
        let words = segment.words
        for (i, word) in words.enumerated() {
            var text = word.text
            if track.preset == .bold { text = text.uppercased() }
            let isActive = i == activeWord
            let color: RGBAColor
            switch track.preset {
            case .karaoke, .bold:
                color = isActive ? track.highlightColor : .white
            case .neon:
                color = isActive ? RGBAColor(r: 1, g: 1, b: 1) : RGBAColor(r: 0.55, g: 0.95, b: 1)
            case .classic, .minimal:
                color = .white
            }
            runs.append(Run(text: text + (i < words.count - 1 ? " " : ""), color: color))
        }
        let style: Style
        switch track.preset {
        case .classic:
            style = Style(fontName: "HelveticaNeue-Medium", fontSize: base * 0.036, shadow: false,
                          backgroundColor: RGBAColor(r: 0, g: 0, b: 0, a: 0.6), maxWidth: canvas.width * 0.86)
        case .karaoke:
            style = Style(fontName: "HelveticaNeue-Bold", fontSize: base * 0.042, outlineColor: .black,
                          outlineWidth: base * 0.004, shadow: true, maxWidth: canvas.width * 0.86)
        case .bold:
            style = Style(fontName: "Futura-CondensedExtraBold", fontSize: base * 0.055, outlineColor: .black,
                          outlineWidth: base * 0.006, shadow: true, maxWidth: canvas.width * 0.86)
        case .minimal:
            style = Style(fontName: "HelveticaNeue", fontSize: base * 0.032, shadow: true, maxWidth: canvas.width * 0.86)
        case .neon:
            style = Style(fontName: "AvenirNext-Heavy", fontSize: base * 0.045, shadow: false,
                          glowColor: RGBAColor(r: 0.2, g: 0.9, b: 1), maxWidth: canvas.width * 0.86)
        }
        return render(runs, style: style)
    }
}

/// Entrance/exit animation state for an overlay at a point in time.
public struct OverlayAnimationState: Sendable, Equatable {
    public var opacity: Double = 1
    public var scale: Double = 1
    public var offsetY: Double = 0   // canvas-normalized
    public var visibleCharacters: Int?
}

public enum OverlayAnimator {
    public static let animationDuration = 0.4

    public static func state(for overlay: TextOverlay, at time: MediaTime) -> OverlayAnimationState? {
        guard overlay.range.contains(time) else { return nil }
        var s = OverlayAnimationState()
        let local = (time - overlay.range.start).seconds
        let remaining = (overlay.range.end - time).seconds
        let d = min(animationDuration, overlay.range.duration.seconds / 3)
        if local < d { apply(overlay.animationIn, progress: local / d, entering: true, text: overlay.text, to: &s) }
        if remaining < d { apply(overlay.animationOut, progress: remaining / d, entering: false, text: overlay.text, to: &s) }
        return s
    }

    /// `progress` runs 0 → 1 as the overlay becomes fully visible (for exits it counts down).
    static func apply(_ animation: TextAnimation, progress: Double, entering: Bool, text: String, to s: inout OverlayAnimationState) {
        let p = min(max(progress, 0), 1)
        switch animation {
        case .none: break
        case .fade: s.opacity *= p
        case .pop:
            // Overshoot then settle.
            let back = 1.70158
            let t = p - 1
            s.scale *= max(0.01, 1 + (back + 1) * t * t * t + back * t * t)
            s.opacity *= min(1, p * 2)
        case .slideUp:
            s.offsetY += (1 - p * p * (3 - 2 * p)) * 0.06
            s.opacity *= p
        case .typewriter:
            if entering {
                s.visibleCharacters = Int((Double(text.count) * p).rounded(.up))
            } else {
                s.opacity *= p
            }
        case .bounce:
            let b = abs(sin(p * .pi * 2.5)) * (1 - p)
            s.offsetY -= b * 0.04
            s.opacity *= min(1, p * 3)
        }
    }

    /// The caption segment and active word index visible at `time`.
    public static func caption(in track: CaptionTrack, at time: MediaTime) -> (CaptionSegment, Int?)? {
        guard track.isVisible else { return nil }
        guard let segment = track.segments.first(where: {
            let r = $0.range
            // Hold each caption slightly past its last word for readability.
            return time >= r.start && time < r.end + MediaTime(seconds: 0.25)
        }) else { return nil }
        let active = segment.words.lastIndex { $0.range.start <= time }
        return (segment, active)
    }
}
