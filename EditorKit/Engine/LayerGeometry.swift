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
    /// Rotation in radians (clockwise on screen) around the layer centre.
    public var rotation: Double = 0
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
        let stretch = transform.fit == .stretch && !forceFill && reframe == nil
        let sx = canvas.width / content.width
        let sy = canvas.height / content.height
        let base = fill ? max(sx, sy) : min(sx, sy)
        let zoom = transform.scale * animation.scale
        let size = stretch
            ? CGSize(width: canvas.width * zoom, height: canvas.height * zoom)
            : CGSize(width: content.width * base * zoom, height: content.height * base * zoom)

        var center = SIMD2<Double>(0.5, 0.5)
        if !stretch, reframe == nil, let anchor = transform.anchor, anchor != .center {
            // Align the chosen edge of the media with the same canvas edge.
            let dx = (size.width - canvas.width) / canvas.width / 2
            let dy = (size.height - canvas.height) / canvas.height / 2
            switch anchor {
            case .left: center.x += dx
            case .right: center.x -= dx
            case .top: center.y += dy
            case .bottom: center.y -= dy
            case .center: break
            }
        }
        center += SIMD2(transform.offsetX, transform.offsetY) * 0.5
        center += animation.offset
        if let reframe {
            center += reframeOffset(center: reframe, contentSize: size, canvas: canvas)
        }
        let halfW = size.width / canvas.width / 2
        let halfH = size.height / canvas.height / 2
        // Canvas-normalized corners (origin top-left), order TL, TR, BL, BR.
        var corners: [SIMD2<Double>] = [
            SIMD2(center.x - halfW, center.y - halfH),
            SIMD2(center.x + halfW, center.y - halfH),
            SIMD2(center.x - halfW, center.y + halfH),
            SIMD2(center.x + halfW, center.y + halfH),
        ]
        if animation.rotation != 0 {
            // Rotate in pixel space so non-square canvases don't skew the layer.
            let c = cos(animation.rotation), s = sin(animation.rotation)
            corners = corners.map { p in
                let dx = (p.x - center.x) * canvas.width, dy = (p.y - center.y) * canvas.height
                return SIMD2(center.x + (dx * c - dy * s) / canvas.width, center.y + (dx * s + dy * c) / canvas.height)
            }
        }
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

    /// Camera move over a still image at `progress` (0 = clip start, 1 = clip end).
    /// Moves are eased and stay within a 1.08–1.3× zoom so the edges never show
    /// when the photo fills the canvas.
    public static func photoMotion(_ motion: PhotoMotion, progress p: Double) -> LayerAnimation {
        var a = LayerAnimation()
        let t = min(max(p, 0), 1)
        let e = t * t * (3 - 2 * t)
        let pan = 0.06
        switch motion {
        case .none: break
        case .zoomIn: a.scale = 1.0 + 0.25 * e
        case .zoomOut: a.scale = 1.25 - 0.25 * e
        case .panLeft:
            a.scale = 1.18
            a.offset = SIMD2(pan - 2 * pan * e, 0)
        case .panRight:
            a.scale = 1.18
            a.offset = SIMD2(-pan + 2 * pan * e, 0)
        case .panUp:
            a.scale = 1.18
            a.offset = SIMD2(0, pan - 2 * pan * e)
        case .panDown:
            a.scale = 1.18
            a.offset = SIMD2(0, -pan + 2 * pan * e)
        case .kenBurns:
            a.scale = 1.08 + 0.2 * e
            a.offset = SIMD2(-0.035 + 0.07 * e, 0.025 - 0.05 * e)
        }
        return a
    }

    /// Combines two animations (scales multiply, offsets add, fades multiply).
    public static func combine(_ a: LayerAnimation, _ b: LayerAnimation) -> LayerAnimation {
        var c = a
        c.scale *= b.scale
        c.offset += b.offset
        c.opacity *= b.opacity
        c.brightness *= b.brightness
        c.blurRadius = max(a.blurRadius, b.blurRadius)
        c.glitch = max(a.glitch, b.glitch)
        c.rotation += b.rotation
        if b.wipeProgress >= 0 { c.wipeProgress = b.wipeProgress }
        return c
    }

    /// Cross-fade weight of the next source frame during slow motion: how far the
    /// playback position is between two source frames (0 = on a frame, →1 = next frame).
    public static func blendWeight(fileTime: Double, fps: Double) -> Double {
        let f = fileTime * fps
        return min(max(f - f.rounded(.down), 0), 1)
    }

    // MARK: Clip animations (In / Out / Combo)

    /// Entrance pose at `progress` (0 = start of the entrance, 1 = fully in).
    /// Exits use the same curves played backwards.
    public static func entrance(_ kind: ClipEntrance, progress p: Double) -> LayerAnimation {
        var a = LayerAnimation()
        let t = min(max(p, 0), 1)
        let e = 1 - pow(1 - t, 3)                 // ease out cubic
        let inv = 1 - e
        switch kind {
        case .fade:
            a.opacity = Float(t)
        case .zoomIn:
            a.scale = 0.3 + 0.7 * e
            a.opacity = Float(min(1, t * 2))
        case .zoomOut:
            a.scale = 1.6 - 0.6 * e
            a.opacity = Float(min(1, t * 2))
        case .slideLeft:  a.offset = SIMD2(inv, 0)      // enters from the right, moving left
        case .slideRight: a.offset = SIMD2(-inv, 0)
        case .slideUp:    a.offset = SIMD2(0, inv)
        case .slideDown:  a.offset = SIMD2(0, -inv)
        case .rotate:
            a.rotation = -Double.pi / 2 * inv
            a.scale = 0.6 + 0.4 * e
            a.opacity = Float(min(1, t * 2))
        case .spin:
            a.rotation = -2 * Double.pi * inv
            a.scale = 0.2 + 0.8 * e
            a.opacity = Float(min(1, t * 1.5))
        case .pop:
            // Overshoot to ~1.1× then settle.
            let back = 1.9, u = t - 1
            a.scale = max(0.01, 1 + (back + 1) * u * u * u + back * u * u)
            a.opacity = Float(min(1, t * 3))
        case .bounce:
            a.scale = max(0.01, bounceOut(t))
        case .drop:
            a.offset = SIMD2(0, -(1 - bounceOut(t)))
        case .blur:
            a.blurRadius = Float(inv * 28)
            a.opacity = Float(min(1, t * 1.5))
        case .swing:
            a.rotation = 0.5 * inv * cos(t * .pi * 3)
            a.opacity = Float(min(1, t * 2))
        }
        return a
    }

    static func bounceOut(_ t: Double) -> Double {
        let n = 7.5625, d = 2.75
        if t < 1 / d { return n * t * t }
        if t < 2 / d { let u = t - 1.5 / d; return n * u * u + 0.75 }
        if t < 2.5 / d { let u = t - 2.25 / d; return n * u * u + 0.9375 }
        let u = t - 2.625 / d
        return n * u * u + 0.984375
    }

    /// Looping emphasis at clip-local time `seconds` (periods of about a beat).
    public static func combo(_ kind: ClipCombo, seconds s: Double) -> LayerAnimation {
        var a = LayerAnimation()
        let w = 2 * Double.pi
        switch kind {
        case .pulse:     a.scale = 1 + 0.05 * (0.5 - 0.5 * cos(w * s / 1.0))
        case .heartbeat:
            let ph = s.truncatingRemainder(dividingBy: 1.0)
            let beat = exp(-pow((ph - 0.1) / 0.05, 2)) + 0.7 * exp(-pow((ph - 0.3) / 0.05, 2))
            a.scale = 1 + 0.07 * beat
        case .shake:     a.offset = SIMD2(0.012 * sin(w * s * 7) * (0.6 + 0.4 * sin(w * s * 1.3)), 0.006 * sin(w * s * 11))
        case .wobble:    a.rotation = 0.06 * sin(w * s * 2)
        case .swing:     a.rotation = 0.1 * sin(w * s / 1.6)
        case .float:     a.offset = SIMD2(0, 0.02 * sin(w * s / 2.4))
        case .rock:
            a.rotation = 0.05 * sin(w * s / 1.2)
            a.scale = 1.04
        case .spin:      a.rotation = w * s / 6      // one turn every 6 s
        }
        return a
    }

    /// Full clip animation at clip-local time: entrance, exit and looping combo.
    public static func clipAnimation(_ anim: ClipAnimation, local: Double, duration: Double) -> LayerAnimation {
        var result = LayerAnimation()
        if let combo = anim.combo {
            result = combine(result, self.combo(combo, seconds: local))
        }
        // Keep In and Out from overlapping on short clips.
        let inLen = min(anim.inDuration, duration / 2), outLen = min(anim.outDuration, duration / 2)
        if let kind = anim.entrance, inLen > 0, local < inLen {
            result = combine(result, entrance(kind, progress: local / inLen))
        }
        if let kind = anim.exit, outLen > 0, local > duration - outLen {
            result = combine(result, entrance(kind, progress: (duration - local) / outLen))
        }
        return result
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
