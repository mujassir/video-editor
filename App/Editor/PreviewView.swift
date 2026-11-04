import SwiftUI
import AVFoundation
import EditorKit

/// AVPlayerLayer host. Frames come straight from the Metal compositor.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onReadyForDisplay: (() -> Void)?
    private var observation: NSKeyValueObservation?

    func observeReadiness() {
        observation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.onReadyForDisplay?() }
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var onReady: () -> Void = {}
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.onReadyForDisplay = onReady
        v.observeReadiness()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        v.accessibilityIdentifier = "preview"
        return v
    }
    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// Canvas-shaped preview with direct manipulation of the selected text.
struct PreviewView: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let ratio = model.project.aspectRatio.value
            let fitted = fit(ratio: ratio, in: geo.size)
            ZStack {
                if model.project.clips.isEmpty {
                    emptyState
                } else {
                    PlayerSurface(player: model.player, onReady: {
                        // New item's first frame is up: drop the held frame shortly after.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { model.holdFrame = nil }
                    })
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay {
                            if let frame = model.holdFrame {
                                Image(uiImage: frame).resizable().allowsHitTesting(false)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(textHandles(canvas: fitted))
                        .contentShape(Rectangle())
                        .onTapGesture { model.togglePlay() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(Theme.secondaryText)
            Text("Add videos or photos to start").foregroundStyle(Theme.secondaryText)
        }
    }

    private func fit(ratio: Double, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > ratio {
            return CGSize(width: size.height * ratio, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / ratio)
    }

    /// Drag the selected text overlay around the canvas.
    @ViewBuilder
    private func textHandles(canvas: CGSize) -> some View {
        if case .text(let id) = model.session.selection,
           let overlay = model.project.textOverlays.first(where: { $0.id == id }),
           overlay.range.contains(model.currentTime) {
            let box = CGSize(width: canvas.width * 0.7, height: canvas.height * overlay.style.size * 1.8 * overlay.scale)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: box.width, height: box.height)
                .position(x: handleCenter(overlay).x * canvas.width, y: handleCenter(overlay).y * canvas.height)
                .gesture(DragGesture().onChanged { v in
                    let x = min(max(v.location.x / canvas.width, 0.05), 0.95)
                    let y = min(max(v.location.y / canvas.height, 0.05), 0.95)
                    model.editCoalescing("Move text", key: "move-\(id)") { p in
                        p.updateText(id) { $0.anchor = nil; $0.centerX = x; $0.centerY = y }
                    }
                })
                .accessibilityIdentifier("textHandle")
        }
    }

    /// Approximate on-screen centre of a text overlay (anchored text hugs an edge).
    private func handleCenter(_ overlay: TextOverlay) -> CGPoint {
        guard let anchor = overlay.anchor else { return CGPoint(x: overlay.centerX, y: overlay.centerY) }
        let a = anchor.axes
        return CGPoint(x: 0.5 + a.x * 0.32, y: 0.5 + a.y * 0.4)
    }
}
