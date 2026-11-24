// Renders App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png:
//   xcrun swift tools/icon/AppIcon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Cut & Weld icon: "Slanted cut" in Plum & ember. Drawn on a 180-unit grid, scaled to 1024 px.
let px = 1024
let s = CGFloat(px) / 180
func c(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let coral = c(0xFF3C61), plum = c(0x2A0E1A), amber = c(0xFFB547), cream = c(0xFFF4E6)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: s, y: -s)   // top-left origin, 180-unit grid

ctx.setFillColor(coral); ctx.fill(CGRect(x: 0, y: 0, width: 180, height: 180))

func poly(_ pts: [(CGFloat, CGFloat)], _ col: CGColor) {
    ctx.beginPath(); ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath(); ctx.setFillColor(col); ctx.fillPath()
}
poly([(16, 70), (86, 70), (78, 110), (16, 110)], plum)
poly([(102, 70), (164, 70), (164, 110), (94, 110)], plum)

ctx.setFillColor(coral)
for x in [22, 36, 50] as [CGFloat] { ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 74, width: 7, height: 5), cornerWidth: 1, cornerHeight: 1, transform: nil)) }
for x in [22, 36, 50] as [CGFloat] { ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 101, width: 7, height: 5), cornerWidth: 1, cornerHeight: 1, transform: nil)) }
for x in [124, 138, 152] as [CGFloat] {
    for y in [74, 101] as [CGFloat] { ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 7, height: 5), cornerWidth: 1, cornerHeight: 1, transform: nil)) }
}
ctx.fillPath()

func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), _ col: CGColor, _ w: CGFloat) {
    ctx.beginPath(); ctx.move(to: CGPoint(x: a.0, y: a.1)); ctx.addLine(to: CGPoint(x: b.0, y: b.1))
    ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.strokePath()
}
line((97, 56), (83, 124), amber, 3.5)
line((106, 76), (116, 66), cream, 3)
line((74, 104), (64, 114), cream, 3)
line((108, 100), (118, 108), cream, 3)
line((72, 80), (62, 72), cream, 3)

ctx.setFillColor(cream); ctx.fillEllipse(in: CGRect(x: 79, y: 79, width: 22, height: 22))
ctx.setFillColor(amber); ctx.fillEllipse(in: CGRect(x: 85, y: 85, width: 10, height: 10))

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
