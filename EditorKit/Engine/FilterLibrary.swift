import Foundation
import simd

/// Built-in color looks. Each look is a pure color function baked into a 3D
/// LUT texture once, so applying any filter costs a single texture lookup per
/// pixel on the GPU regardless of how complex the look is.
public struct FilterPreset: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    let transform: @Sendable (SIMD3<Float>) -> SIMD3<Float>

    public static func == (a: FilterPreset, b: FilterPreset) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(transform(c), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}

public enum FilterLibrary {
    public static let lutSize = 33

    @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
    @inline(__always) static func saturate(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let l = luma(c); return SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * amount
    }
    @inline(__always) static func contrast(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        (c - 0.5) * amount + 0.5
    }
    @inline(__always) static func sCurve(_ x: Float, _ k: Float) -> Float {
        // Smooth contrast curve that keeps black and white fixed.
        let t = simd_clamp(x, 0, 1)
        let s = t * t * (3 - 2 * t)
        return t + (s - t) * k
    }
    @inline(__always) static func curve(_ c: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        SIMD3(sCurve(c.x, k), sCurve(c.y, k), sCurve(c.z, k))
    }
    @inline(__always) static func lift(_ c: SIMD3<Float>, _ black: Float) -> SIMD3<Float> {
        c * (1 - black) + black
    }
    @inline(__always) static func splitTone(_ c: SIMD3<Float>, shadows: SIMD3<Float>, highlights: SIMD3<Float>, amount: Float) -> SIMD3<Float> {
        let l = luma(c)
        let tint = shadows * (1 - l) + highlights * l
        return c + (tint - 0.5) * amount
    }

    public static let presets: [FilterPreset] = [
        FilterPreset(id: "vivid", name: "Vivid") { c in curve(saturate(c, 1.35), 0.35) },
        FilterPreset(id: "warm", name: "Warm") { c in
            curve(SIMD3(c.x * 1.08 + 0.02, c.y * 1.02, c.z * 0.88), 0.15)
        },
        FilterPreset(id: "cool", name: "Cool") { c in
            SIMD3(c.x * 0.9, c.y * 1.0, c.z * 1.1 + 0.03)
        },
        FilterPreset(id: "teal_orange", name: "Cinema") { c in
            curve(splitTone(saturate(c, 1.1), shadows: SIMD3(0.35, 0.55, 0.62), highlights: SIMD3(0.68, 0.52, 0.38), amount: 0.35), 0.3)
        },
        FilterPreset(id: "film", name: "Film") { c in
            lift(curve(saturate(c, 0.85), 0.25), 0.06) * SIMD3(1.02, 1.0, 0.95)
        },
        FilterPreset(id: "fade", name: "Fade") { c in lift(saturate(c, 0.8), 0.12) },
        FilterPreset(id: "vintage", name: "Vintage") { c in
            let s = saturate(c, 0.7)
            return lift(SIMD3(s.x * 1.07, s.y * 0.98, s.z * 0.82), 0.08)
        },
        FilterPreset(id: "mono", name: "Mono") { c in SIMD3(repeating: luma(c)) },
        FilterPreset(id: "noir", name: "Noir") { c in
            let l = sCurve(luma(c), 0.9); return SIMD3(repeating: l * l * 1.05)
        },
        FilterPreset(id: "sepia", name: "Sepia") { c in
            let l = luma(c); return SIMD3(l * 1.07 + 0.05, l * 0.9 + 0.03, l * 0.7)
        },
        FilterPreset(id: "pastel", name: "Pastel") { c in lift(saturate(c, 0.75), 0.1) * SIMD3(1.0, 0.98, 1.02) },
        FilterPreset(id: "punch", name: "Punch") { c in contrast(saturate(c, 1.25), 1.2) },
        FilterPreset(id: "golden", name: "Golden Hour") { c in
            curve(splitTone(c, shadows: SIMD3(0.45, 0.4, 0.5), highlights: SIMD3(0.75, 0.55, 0.3), amount: 0.4), 0.2)
        },
        FilterPreset(id: "moody", name: "Moody") { c in
            let s = saturate(c, 0.75)
            return curve(splitTone(s, shadows: SIMD3(0.4, 0.5, 0.55), highlights: SIMD3(0.55, 0.5, 0.45), amount: 0.3), 0.4) * 0.95
        },
        FilterPreset(id: "lush", name: "Lush") { c in
            let s = saturate(c, 1.2); return SIMD3(s.x * 0.97, s.y * 1.06, s.z * 0.98)
        },
        FilterPreset(id: "bleach", name: "Bleach") { c in
            let l = SIMD3<Float>(repeating: luma(c))
            return curve(c * 0.5 + l * 0.5, 0.6)
        },
        FilterPreset(id: "night", name: "Night") { c in
            SIMD3(c.x * 0.75, c.y * 0.9, c.z * 1.15 + 0.02) * 0.9
        },
        FilterPreset(id: "rose", name: "Rose") { c in SIMD3(c.x * 1.06 + 0.02, c.y * 0.96, c.z * 1.0 + 0.02) },
        FilterPreset(id: "matte", name: "Matte") { c in lift(curve(c, 0.2), 0.09) * 0.96 },
        FilterPreset(id: "chrome", name: "Chrome") { c in curve(saturate(c, 1.15), 0.55) },
    ]

    public static func preset(_ id: String) -> FilterPreset? { presets.first { $0.id == id } }

    /// RGBA float LUT data (size³ entries, red varying fastest) for a 3D texture.
    public static func lutData(for preset: FilterPreset, size: Int = lutSize) -> [SIMD4<Float>] {
        var data = [SIMD4<Float>](repeating: .zero, count: size * size * size)
        let scale = 1 / Float(size - 1)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = preset.apply(SIMD3(Float(r) * scale, Float(g) * scale, Float(b) * scale))
                    data[i] = SIMD4(out, 1)
                    i += 1
                }
            }
        }
        return data
    }
}
