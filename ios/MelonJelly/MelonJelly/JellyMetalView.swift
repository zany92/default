// The Metal view: forwards touches (and iPad pointer hover) to the engine.

import MetalKit
import SwiftUI
import UIKit

final class JellyMTKView: MTKView {
    weak var engine: JellyEngine?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        framebufferOnly = true
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        contentScaleFactor = min(UIScreen.main.nativeScale, 2)
        backgroundColor = UIColor(red: 0.886, green: 0.875, blue: 0.855, alpha: 1)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        engine?.hoverMoved(g.location(in: self))
    }

    private func key(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { engine?.touchBegan(id: key(t), at: t.location(in: self)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { engine?.touchMoved(id: key(t), to: t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { engine?.touchEnded(id: key(t), at: t.location(in: self), cancelled: false, tapCount: t.tapCount) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { engine?.touchEnded(id: key(t), at: t.location(in: self), cancelled: true, tapCount: 0) }
    }
}

struct JellyMetalView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> JellyMTKView {
        let v = JellyMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.engine = model.engine
        do {
            try model.engine.attach(to: v)
        } catch {
            DispatchQueue.main.async { model.fatalError = "Le moteur Metal n’a pas pu démarrer : \(error)" }
            v.isPaused = true
        }
        return v
    }

    func updateUIView(_ uiView: JellyMTKView, context: Context) {}
}
