// UI state, mirrored into the engine.

import Combine
import SwiftUI
import UIKit

final class AppModel: ObservableObject {
    let engine = JellyEngine()

    @Published var tool: Tool = .hand { didSet { engine.setTool(tool) } }
    @Published var paletteID = Palette.all[0].id {
        didSet { if let p = Palette.all.first(where: { $0.id == paletteID }) { engine.palette = p } }
    }
    @Published var firmness: Double = 0.40 { didSet { engine.firmness = Float(firmness) } }
    @Published var damping: Double = 0.45 { didSet { engine.damping = Float(damping) } }
    @Published var paused = false { didSet { engine.paused = paused } }
    @Published var slow = false { didSet { engine.slow = slow } }
    @Published var showMesh = false { didSet { engine.showMesh = showMesh } }

    @Published var readouts = Readouts()
    @Published var toast: String?
    @Published var stroke: (a: CGPoint, b: CGPoint)?
    @Published var strokeVisible = false
    @Published var fatalError: String?

    private var toastWork: DispatchWorkItem?

    init() {
        damping = Double(engine.damping)
        readouts = engine.readouts()
        engine.onReadouts = { [weak self] r in self?.readouts = r }
        engine.onToast = { [weak self] m in self?.showToast(m) }
        engine.onStroke = { [weak self] a, b, on in
            guard let self else { return }
            self.stroke = (a, b)
            if on {
                self.strokeVisible = true
            } else {
                withAnimation(.easeOut(duration: 0.42)) { self.strokeVisible = false }
            }
        }
    }

    var accent: Color {
        let p = Palette.all.first(where: { $0.id == paletteID }) ?? Palette.all[0]
        return Color(linear: p.uiFlesh)
    }

    func nudge() { engine.nudge() }
    func reset() { engine.reset(); readouts = engine.readouts() }

    func setObstruction(_ insets: UIEdgeInsets) { engine.obstruction = insets }

    private func showToast(_ m: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = m }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }
}

extension Color {
    /// a colour given in linear RGB
    init(linear c: SIMD3<Float>) {
        func enc(_ v: Float) -> Double {
            let v = min(1, max(0, v))
            return Double(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        self.init(red: enc(c.x), green: enc(c.y), blue: enc(c.z))
    }
}
