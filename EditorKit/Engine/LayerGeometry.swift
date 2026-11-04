import CoreGraphics
import simd

public struct QuadVertex: Sendable, Equatable {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>
    public var local: SIMD2<Float>
}

/// Per-frame visual parameters produced by transitions.
public struct LayerAnimation: Sendable, Equatable {
    public var opacity: Float = 1
    public var brightness: Float = 1
    public var offset: SIMD2<Double> = .zero    // canvas-normalized (1 = full canvas width/height)
    public var scale: Double = 1
    public var blurRadius: Float = 0
    public var wipeProgress: Float = -1
    public var glitch: Float = 0
    public init() {}
}

public enum LayerGeometry {
    /// Maps an upright-display point back to raw-frame UV, given clockwise source quarter turns.
    @inline(__always)
    static func unrotate(_ p: SIMD2<Double>, turns: Int) -> SIMD2<Double> {
        // A clockwise 90° rotation maps raw (x, y) → display (1 - y, x).
        var q = p
        for _ in 0..<(((turns % 4) + 4) % 4) { q = SIMD2(q.y, 1 - q.x) }
        return q
    }

    /// Size of the displayed image (after source orientation, crop and user rotation), in pixels.
    public static func displaySize(media: MediaItem, transform: ClipTransform) -> CGSize {
        let w = media.naturalSize.width * transform.crop.width
        let h = media.naturalSize.height * transform.crop.height
        return transform.quarterTurns % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Crop-centre shift (canvas-normalized) that keeps the reframe target centred while filling the canvas.
    public static func reframeOffset(center: SIMD2<Double>, contentSize: CGSize, canvas: CGSize) -> SIMD2<Double> {
        // Content is centred by default; move it so `center` (0...1 in content) sits at canvas centre.
        let overflowX = max(0, contentSize.width - canvas.width) / canvas.width
        let overflowY = max(0, contentSize.height - canvas.height) / canvas.height
        let dx = (0.5 - center.x) * contentSize.width / canvas.width
        let dy = (0.5 - center.y) * contentSize.height / canvas.height
        // Clamp so the canvas never shows past the content edges.
        return SIMD2(min(max(dx, -overflowX / 2), overflowX / 2),
                     min(max(dy, -overflowY / 2), overflowY / 2))
    }

    /// Interpolated reframe centre at a source time.
    public static func reframeCenter(_ keys: [ReframeKeyframe], at time: MediaTime) -> SIMD2<Double>? {
        guard let first = keys.first else { return nil }
        if time <= first.time { return SIMD2(first.centerX, first.centerY) }
        for (a, b) in zip(keys, keys.dropFirst()) where time >= a.time && time <= b.time {
            let span = Double((b.time - a.time).ticks)
            let t = span > 0 ? Double((time - a.time).ticks) / span : 0
            let s = t * t * (3 - 2 * t)
            return SIMD2(a.centerX + (b.centerX - a.centerX) * s, a.centerY + (b.centerY - a.centerY) * s)
        }
        let last = keys[keys.count - 1]
        return SIMD2(last.centerX, last.centerY)
    }

    /// Builds the triangle-strip quad (TL, TR, BL, BR) for a clip layer.
    ///
    /// - Parameters:
    ///   - sourceTurns: raw-frame orientation (0 for stills, which are decoded upright).
    ///   - reframe: optional centre (0...1 in displayed content) to keep in view when filling.
    public static func quad(media: MediaItem, transform: ClipTransform, sourceTurns: Int,
                            canvas: CGSize, animation: LayerAnimation = LayerAnimation(),
                            reframe: SIMD2<Double>? = nil, forceFill: Bool = false) -> [QuadVertex] {
        let content = displaySize(media: media, transform: transform)
        guard content.width > 0, content.height > 0, canvas.width > 0, canvas.height > 0 else { return [] }
        let fill = forceFill || transform.fit == .fill || reframe != nil
        let sx = canvas.width / content.width
        let sy = canvas.height / content.height
        let base = fill ? max(sx, sy) : min(sx, sy)
        let scale = base * transform.scale * animation.scale
        let size = CGSize(width: content.width * scale, height: content.height * scale)

        var center = SIMD2<Double>(0.5, 0.5)
        center += SIMD2(transform.offsetX, transform.offsetY) * 0.5
        center += animation.offset
        if let reframe {
            center += reframeOffset(center: reframe, contentSize: size, canvas: canvas)
        }
        let halfW = size.width / canvas.width / 2
        let halfH = size.height / canvas.height / 2
        // Canvas-normalized corners (origin top-left), order TL, TR, BL, BR.
        let corners: [SIMD2<Double>] = [
            SIMD2(center.x - halfW, center.y - halfH),
            SIMD2(center.x + halfW, center.y - halfH),
            SIMD2(center.x - halfW, center.y + halfH),
            SIMD2(center.x + halfW, center.y + halfH),
        ]
        let locals: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        let crop = transform.crop
        return zip(corners, locals).map { corner, local in
            // Output-local → before user flips/rotation → cropped display → raw UV.
            var p = local
            if transform.flipHorizontal { p.x = 1 - p.x }
            if transform.flipVertical { p.y = 1 - p.y }
            p = unrotate(p, turns: transform.quarterTurns)
            let display = SIMD2(crop.x + p.x * crop.width, crop.y + p.y * crop.height)
            let raw = unrotate(display, turns: sourceTurns)
            let ndc = SIMD2<Float>(Float(corner.x * 2 - 1), Float(1 - corner.y * 2))
            return QuadVertex(position: ndc, uv: SIMD2<Float>(raw), local: SIMD2<Float>(local))
        }
    }

    /// Full-canvas quad with identity UVs.
    public static func fullscreen() -> [QuadVertex] {
        [
            QuadVertex(position: SIMD2(-1, 1), uv: SIMD2(0, 0), local: SIMD2(0, 0)),
            QuadVertex(position: SIMD2(1, 1), uv: SIMD2(1, 0), local: SIMD2(1, 0)),
            QuadVertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1), local: SIMD2(0, 1)),
            QuadVertex(position: SIMD2(1, -1), uv: SIMD2(1, 1), local: SIMD2(1, 1)),
        ]
    }

    /// Quad for an overlay of `size` pixels centred at a canvas-normalized point.
    public static func overlayQuad(size: CGSize, center: SIMD2<Double>, canvas: CGSize,
                                   scale: Double = 1, rotation: Double = 0) -> [QuadVertex] {
        let hw = size.width * scale / 2, hh = size.height * scale / 2
        let c = SIMD2(center.x * canvas.width, center.y * canvas.height)
        let cosR = cos(rotation), sinR = sin(rotation)
        let pts: [SIMD2<Double>] = [SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(-hw, hh), SIMD2(hw, hh)]
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        return zip(pts, uvs).map { p, uv in
            let r = SIMD2(p.x * cosR - p.y * sinR, p.x * sinR + p.y * cosR) + c
            let ndc = SIMD2<Float>(Float(r.x / canvas.width * 2 - 1), Float(1 - r.y / canvas.height * 2))
            return QuadVertex(position: ndc, uv: uv, local: uv)
        }
    }

    /// Visual parameters for a clip during a transition.
    /// - Parameters:
    ///   - progress: 0 at transition start, 1 at end.
    ///   - incoming: true for the clip entering.
    public static func transitionAnimation(_ kind: TransitionKind, progress p: Double, incoming: Bool) -> LayerAnimation {
        var a = LayerAnimation()
        let p = min(max(p, 0), 1)
        let e = p * p * (3 - 2 * p) // ease in-out
        switch kind {
        case .fade:
            // Dip to black: outgoing darkens over the first half, incoming brightens over the second.
            if incoming {
                a.opacity = p < 0.5 ? 0 : 1
                a.brightness = Float(max(0, p * 2 - 1))
            } else {
                a.brightness = Float(max(0, 1 - p * 2))
            }
        case .dissolve:
            if incoming { a.opacity = Float(e) }
        case .slideLeft:
            a.offset = SIMD2(incoming ? 1 - e : -e, 0)
        case .slideUp:
            a.offset = SIMD2(0, incoming ? 1 - e : -e)
        case .zoom:
            if incoming {
                a.scale = 1.4 - 0.4 * e
                a.opacity = Float(e)
            } else {
                a.scale = 1 + 0.4 * e
            }
        case .wipe:
            if incoming { a.wipeProgress = Float(e) }
        case .blur:
            let radius = Float(sin(p * .pi)) * 24
            a.blurRadius = radius
            if incoming { a.opacity = Float(e) }
        case .glitch:
            let g = Float(sin(p * .pi))
            a.glitch = g
            if incoming { a.opacity = p < 0.5 ? 0 : 1 }
        }
        return a
    }
}
