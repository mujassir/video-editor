// Generates original portrait demo footage for App Store screenshots (no third-party imagery).
//   xcrun swift tools/screenshots/make-footage.swift <output-folder>
import AVFoundation
import CoreGraphics
import Foundation

let W = 1080, H = 1920, fps = 30, seconds = 6.0

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
func gradient(_ ctx: CGContext, _ colors: [UInt32], from y0: CGFloat, to y1: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(rgb) as CFArray, locations: nil)!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: min(y0, y1), width: CGFloat(W), height: abs(y1 - y0)))
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}
func poly(_ ctx: CGContext, _ pts: [CGPoint], _ c: UInt32) {
    ctx.beginPath(); ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }
    ctx.closePath(); ctx.setFillColor(rgb(c)); ctx.fillPath()
}

// Drawing uses a top-left origin (y grows downwards).
typealias Scene = (CGContext, Double) -> Void

let sunset: Scene = { ctx, t in
    let horizon = CGFloat(H) * 0.58
    gradient(ctx, [0x2B1B4A, 0x8E3B6B, 0xFF7E5F, 0xFEB47B], from: 0, to: horizon)
    let sunY = horizon - 40 - CGFloat(t) * 14
    ctx.setFillColor(rgb(0xFFE3A3)); ctx.fillEllipse(in: CGRect(x: 540 - 150, y: sunY - 150, width: 300, height: 300))
    gradient(ctx, [0x3A2D5C, 0x1B2A4A, 0x0E1A33], from: horizon, to: CGFloat(H))
    for i in 0..<26 {
        let y = horizon + 20 + CGFloat(i) * 34
        let w = 260 - CGFloat(i) * 6 + CGFloat(sin(t * 2 + Double(i))) * 30
        ctx.setFillColor(rgb(0xFFC48A).copy(alpha: max(0.1, 0.8 - CGFloat(i) * 0.03))!)
        ctx.fill(CGRect(x: 540 - w / 2 + CGFloat(sin(t + Double(i) * 0.7)) * 20, y: y, width: max(20, w), height: 8))
    }
}

let mountains: Scene = { ctx, t in
    gradient(ctx, [0x7FB8E6, 0xBFDDF2, 0xFDE2C4], from: 0, to: CGFloat(H) * 0.7)
    ctx.setFillColor(rgb(0xFFF6E0)); ctx.fillEllipse(in: CGRect(x: 700, y: 360, width: 170, height: 170))
    for (i, cloud) in [(120.0, 300.0), (620.0, 520.0), (260.0, 700.0)].enumerated() {
        let x = CGFloat(cloud.0) + CGFloat(t) * CGFloat(18 + i * 8)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: x, y: CGFloat(cloud.1), width: 260, height: 70))
        ctx.fillEllipse(in: CGRect(x: x + 70, y: CGFloat(cloud.1) - 35, width: 150, height: 90))
    }
    let layers: [(UInt32, CGFloat, [CGFloat], CGFloat)] = [
        (0x8DA9C4, 1000, [0, -260, 120, -120, 300, -320, 520, -80, 760, -300, 1080, -60], 6),
        (0x5B7DA0, 1180, [0, -200, 200, -40, 380, -300, 600, -100, 840, -260, 1080, -120], 12),
        (0x34506E, 1380, [0, -120, 260, -280, 500, -60, 700, -220, 1080, -40], 20),
        (0x1E3148, 1580, [0, -60, 300, -200, 560, -40, 860, -160, 1080, -80], 30),
    ]
    for (color, base, profile, speed) in layers {
        let dx = -CGFloat(t) * speed
        var pts = [CGPoint(x: -100, y: CGFloat(H))]
        stride(from: 0, to: profile.count, by: 2).forEach { pts.append(CGPoint(x: profile[$0] + dx, y: base + profile[$0 + 1])) }
        pts.append(CGPoint(x: CGFloat(W) + 200, y: base)); pts.append(CGPoint(x: CGFloat(W) + 200, y: CGFloat(H)))
        poly(ctx, pts, color)
    }
}

let city: Scene = { ctx, t in
    gradient(ctx, [0x0B1026, 0x1C1A4A, 0x4A2A6A], from: 0, to: CGFloat(H) * 0.75)
    ctx.setFillColor(rgb(0xF4F1DE)); ctx.fillEllipse(in: CGRect(x: 160, y: 300, width: 140, height: 140))
    for i in 0..<60 {
        let x = CGFloat((i * 397) % W), y = CGFloat((i * 211) % 900)
        let a = 0.4 + 0.4 * sin(t * 3 + Double(i))
        ctx.setFillColor(CGColor(gray: 1, alpha: CGFloat(a))); ctx.fillEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
    }
    ctx.setFillColor(rgb(0x2A1F45)); ctx.fill(CGRect(x: 0, y: CGFloat(H) * 0.75, width: CGFloat(W), height: CGFloat(H) * 0.25))
    var x: CGFloat = -20, n = 0
    while x < CGFloat(W) {
        let w = CGFloat(90 + (n * 53) % 90), h = CGFloat(500 + (n * 137) % 600)
        let top = CGFloat(H) * 0.8 - h
        ctx.setFillColor(rgb(n % 2 == 0 ? 0x141A33 : 0x1B2140)); ctx.fill(CGRect(x: x, y: top, width: w, height: h + 400))
        var wy = top + 24
        while wy < CGFloat(H) * 0.8 - 20 {
            var wx = x + 14
            while wx < x + w - 20 {
                let on = (Int(wx) * 7 + Int(wy) * 13 + Int(t * 2) * (n % 3)) % 5 < 2
                if on { ctx.setFillColor(rgb(0xFFD27A)); ctx.fill(CGRect(x: wx, y: wy, width: 12, height: 16)) }
                wx += 26
            }
            wy += 34
        }
        x += w + 8; n += 1
    }
    ctx.setFillColor(rgb(0xFF3C61).copy(alpha: 0.18)!)
    ctx.fill(CGRect(x: 0, y: CGFloat(H) * 0.8, width: CGFloat(W), height: CGFloat(H) * 0.2))
}

func render(_ scene: Scene, to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
    writer.add(input)
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(seconds * Double(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let buffer = pb else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        scene(ctx, Double(i) / Double(fps))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if let e = writer.error { throw e }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, scene) in [("01-sunset", sunset), ("02-mountains", mountains), ("03-city", city)] {
    try await render(scene, to: out.appendingPathComponent("\(name).mov"))
    print("wrote \(name).mov")
}
