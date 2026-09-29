// ─────────────────────────────────────────────────────────────
//  Engine: sim ↔ render glue, camera, picking, the knife, touches
// ─────────────────────────────────────────────────────────────

import Foundation
import MetalKit
import simd
import UIKit

private func srgbToLin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

struct Palette: Identifiable {
    let id: String
    let name: String
    let flesh: SIMD3<Float>, fleshDeep: SIMD3<Float>, pale: SIMD3<Float>, skin: SIMD3<Float>, stripe: SIMD3<Float>
    let seed: SIMD3<Float>, shadowTint: SIMD3<Float>
    let uiFlesh: SIMD3<Float>

    // three coordinated varieties (linear RGB)
    static let all: [Palette] = [
        Palette(id: "crimson", name: "Crimson",
                flesh: [0.93, 0.07, 0.11], fleshDeep: [0.42, 0.018, 0.035],
                pale: [0.8, 0.86, 0.62], skin: [0.03, 0.13, 0.035], stripe: [0.005, 0.034, 0.01],
                seed: [0.01, 0.0065, 0.005], shadowTint: [0.6, 0.47, 0.46], uiFlesh: [0.62, 0.03, 0.06]),
        Palette(id: "golden", name: "Golden",
                flesh: [0.97, 0.52, 0.05], fleshDeep: [0.6, 0.24, 0.012],
                pale: [0.84, 0.88, 0.64], skin: [0.04, 0.15, 0.03], stripe: [0.007, 0.04, 0.01],
                seed: [0.012, 0.008, 0.005], shadowTint: [0.64, 0.55, 0.44], uiFlesh: [0.72, 0.3, 0.02]),
        Palette(id: "rose", name: "Rosé",
                flesh: [0.95, 0.2, 0.3], fleshDeep: [0.6, 0.08, 0.15],
                pale: [0.84, 0.9, 0.72], skin: [0.06, 0.2, 0.1], stripe: [0.012, 0.06, 0.03],
                seed: [0.014, 0.009, 0.007], shadowTint: [0.64, 0.5, 0.52], uiFlesh: [0.72, 0.16, 0.24]),
    ]
}

enum Tool { case hand, knife }

struct Readouts {
    var massG: Double = 0
    var volumePct: Double = 100
    var kineticMicroJ: Double = 0
    var pieces: Int = 1
    var particles: Int = 0
    var tets: Int = 0
}

let BG_SRGB: SIMD3<Float> = [0.886, 0.875, 0.855] // #E2DFDA — the studio sweep
// the tone mapper subtracts a small toe offset; lift the backdrop so it lands on the page colour
let BG_RENDER = SIMD3<Float>(srgbToLin(BG_SRGB.x), srgbToLin(BG_SRGB.y), srgbToLin(BG_SRGB.z)) + 0.04

private let SCALE_CM = 3.5      // illustrative: 1 simulation unit ≈ 3.5 cm
private let DENSITY = 1.3       // g/cm³, gummy candy
private let MAX_PIECES = 14
private let FOV: Float = 27 * .pi / 180
private let HOVER_H: Float = 0.42 // edge height above the top of the slice while hovering
private let T: Float = Float(Shape.T)

private struct Ray { var o: SIMD3<Float>; var d: SIMD3<Float> }

private struct CutPlan {
    var next: [Piece]
    var sep: [(piece: Int, dir: SIMD3<Float>)]
    var world: World
    var sim: SoftBody
    var M: SIMD3<Float>
    var yTop: Float
    var yaw: Float
}

private struct KnifePose { var P: SIMD3<Float>; var yaw: Float; var roll: Float; var pitch: Float }

private final class KnifeAnim {
    var t: Float = 0
    let plan: CutPlan
    let from: KnifePose
    var committed = false
    init(plan: CutPlan, from: KnifePose) { self.plan = plan; self.from = from }
}

final class JellyEngine: NSObject, MTKViewDelegate {
    // ── UI hooks ──
    var onReadouts: ((Readouts) -> Void)?
    var onToast: ((String) -> Void)?
    var onStroke: ((CGPoint, CGPoint, Bool) -> Void)?

    // ── settings mirrored from the UI ──
    var palette = Palette.all[0]
    var paused = false { didSet { if paused && drag.mode == .grab { sim.endGrab(); drag.mode = nil } } }
    var slow = false
    var showMesh = false
    var firmness: Float = 0.4 { didSet { sim.firmness = firmness } }
    var damping: Float = 0.45 { didSet { sim.damping = damping } }
    private(set) var tool: Tool = .hand
    /// region of the view (points) covered by UI chrome; the slice is framed in what is left
    var obstruction = UIEdgeInsets.zero

    // ── world ──
    private var pieces: [Piece]
    private let wholePiece: Piece
    private var world: World
    private(set) var sim: SoftBody
    private var nV = 0
    private var dyn: UnsafeMutablePointer<Float>
    private var dynCap = 0

    // ── rendering ──
    private(set) var renderer: Renderer?
    private let knifeMesh: KnifeMesh
    private let knifeDyn: UnsafeMutablePointer<Float>
    private var knifeVisible = false

    // ── camera ──
    private var az: Float = 0.62, el: Float = 0.6, zoom: Float = 1
    private var target = SIMD3<Float>(0, 0.24, 1.0)
    private let home = SIMD3<Float>(0, 0.24, 1.0)
    private var viewProj = matrix_identity_float4x4
    private var view = matrix_identity_float4x4
    private var invViewProj = matrix_identity_float4x4
    private var camPos = SIMD3<Float>(0, 0, 0)
    private var camFwd = SIMD3<Float>(0, 0, -1)
    private var viewSize = CGSize(width: 1, height: 1)

    // light rig: key from behind-left and above (so thin edges glow toward the camera)
    private let keyDir = simd_normalize(SIMD3<Float>(-0.45, 0.86, -0.36))
    private let keyIntensity: Float = 2.3
    private var lightVP = matrix_identity_float4x4
    private var topVP = matrix_identity_float4x4

    // ── knife state ──
    private var kp = KnifePose(P: [0, T + HOVER_H + 1.4, 0.9], yaw: -0.62, roll: 0.16, pitch: 0.05)
    private let blade = Blade()
    private var knifeAnim: KnifeAnim?
    private var hoverSeen = false
    private var hover = CGPoint.zero
    private var strokeA = CGPoint.zero, strokeB = CGPoint.zero

    // ── touches ──
    private enum DragMode { case grab, orbit, knife, pinch }
    private struct Drag {
        var mode: DragMode?
        var id: Int = -1
        var plane: (p: SIMD3<Float>, n: SIMD3<Float>) = ([0, 0, 0], [0, 0, 1])
        var twist: Float = 0, twist0: Float = 0
        var second: (id: Int, p: CGPoint)?
        var last = CGPoint.zero
        var pinchD0: CGFloat = 1, zoom0: Float = 1
        var moved: CGFloat = 0
    }
    private var drag = Drag()
    private var lastPickTri = -1

    // ── loop ──
    private var acc: Float = 0
    private var readoutT: Float = 0
    private var lastTime: CFTimeInterval = 0
    private var time: Float = 0
    private let reducedMotion = UIAccessibility.isReduceMotionEnabled

    override init() {
        let first = initialPiece()
        pieces = [first]
        wholePiece = first
        let w = buildWorld([first])
        world = w
        let startDamping: Float = UIAccessibility.isReduceMotionEnabled ? 0.65 : 0.45
        sim = SoftBody(mesh: w.sim, firmness: 0.4, damping: startDamping)
        damping = startDamping
        let km = buildKnifeMesh()
        knifeMesh = km
        let kd = UnsafeMutablePointer<Float>.allocate(capacity: km.rest.count * 2)
        kd.initialize(repeating: 0, count: km.rest.count * 2)
        knifeDyn = kd
        let d0 = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        d0.initialize(to: 0)
        dyn = d0
        super.init()
        sim.blade = blade
        adoptRenderMesh()
        sim.reset(drop: reducedMotion ? 0 : 0.35)
    }

    deinit { dyn.deallocate(); knifeDyn.deallocate() }

    func attach(to view: MTKView) throws {
        guard let device = view.device else { throw RendererError.noDevice }
        let r = try Renderer(device: device)
        r.setKnife(knifeMesh)
        r.setMesh(world.render, edges: sim.edges, nParticles: sim.n)
        renderer = r
        view.delegate = self
    }

    private func adoptRenderMesh() {
        nV = world.render.rest.count / 3
        if nV * 6 > dynCap {
            dyn.deallocate()
            dynCap = nV * 6
            dyn = UnsafeMutablePointer<Float>.allocate(capacity: dynCap)
            dyn.initialize(repeating: 0, count: dynCap)
        }
    }

    // ── public actions ──
    func nudge() { if !paused { sim.nudge(strength: reducedMotion ? 0.45 : 1) } }

    func reset() {
        knifeAnim = nil; blade.mode = nil
        if pieces.count > 1 { installWorld([wholePiece]) }
        sim.reset(drop: reducedMotion ? 0 : 0.35); acc = 0
    }

    func resetCamera() { az = 0.62; el = 0.6; zoom = 1 }

    func setTool(_ t: Tool) {
        if t == .knife && tool != .knife && knifeAnim == nil {
            // the knife drops in from above
            let h = hoverPose()
            kp = KnifePose(P: [h.P.x, h.P.y + 1.6, h.P.z], yaw: h.yaw, roll: h.roll, pitch: h.pitch)
        }
        tool = t
    }

    // ── skinning: every render vertex (body, seeds, bubbles) follows its tetrahedron ──
    private func skin() {
        let x = sim.x
        let d = dyn
        world.skinIdx.withUnsafeBufferPointer { si in
            world.skinW.withUnsafeBufferPointer { sw in
                for v in 0..<nV {
                    let i4 = 4 * v, o = 6 * v
                    let a = 3 * Int(si[i4]), b = 3 * Int(si[i4 + 1]), c = 3 * Int(si[i4 + 2]), e = 3 * Int(si[i4 + 3])
                    let w0 = sw[i4], w1 = sw[i4 + 1], w2 = sw[i4 + 2], w3 = sw[i4 + 3]
                    d[o] = x[a] * w0 + x[b] * w1 + x[c] * w2 + x[e] * w3
                    d[o + 1] = x[a + 1] * w0 + x[b + 1] * w1 + x[c + 1] * w2 + x[e + 1] * w3
                    d[o + 2] = x[a + 2] * w0 + x[b + 2] * w1 + x[c + 2] * w2 + x[e + 2] * w3
                    d[o + 3] = 0; d[o + 4] = 0; d[o + 5] = 0
                }
            }
        }
        world.render.index.withUnsafeBufferPointer { idx in
            var t = 0
            while t < idx.count {
                let a = 6 * Int(idx[t]), b = 6 * Int(idx[t + 1]), c = 6 * Int(idx[t + 2])
                let e1x = d[b] - d[a], e1y = d[b + 1] - d[a + 1], e1z = d[b + 2] - d[a + 2]
                let e2x = d[c] - d[a], e2y = d[c + 1] - d[a + 1], e2z = d[c + 2] - d[a + 2]
                let nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x
                d[a + 3] += nx; d[a + 4] += ny; d[a + 5] += nz
                d[b + 3] += nx; d[b + 4] += ny; d[b + 5] += nz
                d[c + 3] += nx; d[c + 4] += ny; d[c + 5] += nz
                t += 3
            }
        }
        var o = 0
        while o < nV * 6 {
            var l = (d[o + 3] * d[o + 3] + d[o + 4] * d[o + 4] + d[o + 5] * d[o + 5]).squareRoot()
            if l == 0 { l = 1 }
            d[o + 3] /= l; d[o + 4] /= l; d[o + 5] /= l
            o += 6
        }
    }

    // ── camera & framing (keeps the slice clear of the UI chrome) ──
    // the camera eases after the slice if it is thrown or dragged far from home (never while holding it)
    private func followSlice(_ dt: Float) {
        if drag.mode == .grab { return }
        let c = sim.centroid()
        let k = 1 - exp(-dt * 1.4)
        let gx = home.x + c.x * 0.7, gz = home.z + (c.z - 1.01) * 0.7
        target.x += (gx - target.x) * k; target.z += (gz - target.z) * k
    }

    private func updateCamera() {
        let W = Float(max(viewSize.width, 1)), H = Float(max(viewSize.height, 1))
        let ob = obstruction
        let rx = Float(ob.left), ry = Float(ob.top)
        let rw = max(200, W - Float(ob.left + ob.right)), rh = max(200, H - Float(ob.top + ob.bottom))
        let aspect = W / H
        let hf = min(1, rh / H), wf = min(1, rw / W)
        // fit the slice's footprint: wider than it is tall from this angle
        let Rh: Float = 1.32, Rv: Float = 1.0
        let t2 = tan(FOV / 2)
        let dist = max(Rv / (t2 * 0.9 * hf), Rh / (t2 * 0.92 * aspect * wf)) * zoom
        let ce = cos(el)
        let eye = SIMD3<Float>(target.x + dist * sin(az) * ce, target.y + dist * sin(el), target.z + dist * cos(az) * ce)
        view = M4.lookAt(eye: eye, at: target, up: [0, 1, 0])
        var proj = M4.perspective(fovy: FOV, aspect: aspect, near: 0.1, far: 60)
        // lens shift so the target lands at the centre of the safe rect
        let cx = (rx + rw / 2) / W, cy = (ry + rh / 2) / H
        proj.columns.2.x -= (cx * 2 - 1)
        proj.columns.2.y -= -(cy * 2 - 1)
        viewProj = proj * view
        invViewProj = viewProj.inverse
        camPos = eye
        camFwd = simd_normalize(target - eye)
    }

    private func updateLight() {
        // shadow and height maps are centred on the slice itself so they never lose it
        let c = sim.centroid()
        let at = SIMD3<Float>(c.x, 0.3, c.z)
        lightVP = M4.ortho(-2.4, 2.4, -2.4, 2.4, 0.1, 14) * M4.lookAt(eye: at + keyDir * 7, at: at, up: [0, 0, 1])
        // top-down height map: camera under the floor looking up so the lowest surface wins; depth = (y + 1) / 5
        topVP = M4.ortho(-2.6, 2.6, -2.6, 2.6, 0, 5) * M4.lookAt(eye: [at.x, -1, at.z], at: [at.x, 1, at.z], up: [0, 0, -1])
    }

    // ── picking ──
    private func rayFrom(_ p: CGPoint) -> Ray {
        let nx = Float(p.x / max(viewSize.width, 1)) * 2 - 1, ny = 1 - Float(p.y / max(viewSize.height, 1)) * 2
        func un(_ z: Float) -> SIMD3<Float> {
            let q = invViewProj * SIMD4<Float>(nx, ny, z, 1)
            return SIMD3(q.x, q.y, q.z) / q.w
        }
        let a = un(0), b = un(1)
        return Ray(o: a, d: simd_normalize(b - a))
    }

    private func pick(_ ray: Ray) -> SIMD3<Float>? {
        var best = Float.infinity
        let o = ray.o, dd = ray.d
        let d = dyn
        let end = world.render.body.count
        world.render.index.withUnsafeBufferPointer { index in
            var t = 0
            while t < end {
                let a = 6 * Int(index[t]), b = 6 * Int(index[t + 1]), c = 6 * Int(index[t + 2])
                let e1x = d[b] - d[a], e1y = d[b + 1] - d[a + 1], e1z = d[b + 2] - d[a + 2]
                let e2x = d[c] - d[a], e2y = d[c + 1] - d[a + 1], e2z = d[c + 2] - d[a + 2]
                let px = dd.y * e2z - dd.z * e2y, py = dd.z * e2x - dd.x * e2z, pz = dd.x * e2y - dd.y * e2x
                let det = e1x * px + e1y * py + e1z * pz
                t += 3
                if abs(det) < 1e-12 { continue }
                let inv = 1 / det
                let tx = o.x - d[a], ty = o.y - d[a + 1], tz = o.z - d[a + 2]
                let uu = (tx * px + ty * py + tz * pz) * inv
                if uu < 0 || uu > 1 { continue }
                let qx = ty * e1z - tz * e1y, qy = tz * e1x - tx * e1z, qz = tx * e1y - ty * e1x
                let vv = (dd.x * qx + dd.y * qy + dd.z * qz) * inv
                if vv < 0 || uu + vv > 1 { continue }
                let tt = (e2x * qx + e2y * qy + e2z * qz) * inv
                if tt > 1e-4 && tt < best { best = tt; lastPickTri = t - 3 }
            }
        }
        return best < .infinity ? o + dd * best : nil
    }

    // forgiving fallback for grabs that land just outside the rounded silhouette
    private func pickNear(_ p: CGPoint, maxPx: Float) -> SIMD3<Float>? {
        let W = Float(viewSize.width), H = Float(viewSize.height), x = sim.x
        var best = -1, bd = maxPx * maxPx
        for i in 0..<sim.n {
            let q = viewProj * SIMD4<Float>(x[3 * i], x[3 * i + 1], x[3 * i + 2], 1)
            let sx = (q.x / q.w * 0.5 + 0.5) * W
            let sy = (0.5 - q.y / q.w * 0.5) * H
            let d = (sx - Float(p.x)) * (sx - Float(p.x)) + (sy - Float(p.y)) * (sy - Float(p.y)) - q.w * 1e-3 // prefer nearer particles on ties
            if d < bd { bd = d; best = i }
        }
        return best < 0 ? nil : SIMD3(x[3 * best], x[3 * best + 1], x[3 * best + 2])
    }

    // ── knife ──
    private func rayPlaneY(_ ray: Ray, _ y: Float) -> SIMD3<Float>? {
        if ray.d.y > -1e-4 { return nil }
        let t = (y - ray.o.y) / ray.d.y
        return t > 0 ? SIMD3(ray.o.x + ray.d.x * t, y, ray.o.z + ray.d.z * t) : nil
    }
    private var camRightYaw: Float { -az }          // blade direction that shows its face to the camera
    private func canonicalYaw(_ dx: Float, _ dz: Float) -> Float {
        var yaw = atan2(dz, dx)
        if cos(yaw - camRightYaw) < 0 { yaw += .pi }  // keep the handle on the left, tip on the right
        return yaw
    }

    // Cut: the stroke, seen on the top of the slice, defines a vertical blade plane; every piece the
    // stroke passes over is split along it. The plane is carried into each piece's rest frame
    // (best-fit rotation of the deformed piece), where it becomes a straight line across the slice.
    // Planning happens on release (so the heavy rebuild is done before the knife moves); the new
    // world is swapped in mid-stroke, at the moment the edge breaks through.
    private func planCut(_ a: CGPoint, _ b: CGPoint) -> Result<CutPlan, CutMiss> {
        if hypot(b.x - a.x, b.y - a.y) < 24 { return .failure(.silent) }
        func at(_ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        var hit = Set<Int>()
        var yTop: Float = 0
        var t0: CGFloat = -1, t1: CGFloat = -1
        for k in 0...48 {
            let t = CGFloat(k) / 48
            if let p = pick(rayFrom(at(t))), lastPickTri >= 0 {
                hit.insert(Int(world.render.vComp[Int(world.render.index[lastPickTri])]))
                yTop = max(yTop, p.y)
                if t0 < 0 { t0 = t }
                t1 = t
            }
        }
        if hit.isEmpty { return .failure(.message("Raté — tracez la lame en travers de la tranche.")) }
        if pieces.count + hit.count > MAX_PIECES { return .failure(.message("Ça fait beaucoup de morceaux. Réinitialisez pour repartir d’une tranche entière.")) }
        // the stroke as seen on the surface it was drawn over
        func onTop(_ t: CGFloat) -> SIMD3<Float>? { rayPlaneY(rayFrom(at(t)), yTop) }
        guard let A = onTop(0) ?? onTop(t0), let B = onTop(1) ?? onTop(t1), let A2 = onTop(t0), let B2 = onTop(t1) else {
            return .failure(.message("Raté — tracez la lame en travers de la tranche."))
        }
        var dx = B.x - A.x, dz = B.z - A.z
        let dl = (dx * dx + dz * dz).squareRoot()
        if dl < 0.05 { return .failure(.silent) }
        dx /= dl; dz /= dl
        let n = SIMD3<Double>(Double(-dz), 0, Double(dx))
        let o = SIMD3<Double>(Double(A2.x + B2.x) / 2, Double(yTop), Double(A2.z + B2.z) / 2)
        var next: [Piece] = []
        var sep: [(piece: Int, dir: SIMD3<Float>)] = []
        var thin = 0, cut = 0
        for (c, pc) in pieces.enumerated() {
            if !hit.contains(c) { next.append(pc); continue }
            let F = sim.pieceFrame(c), R = F.R
            // world plane n·x = n·o  →  rest plane nr·X = nr·pr
            let nr = SIMD3<Double>(R[0] * n.x + R[3] * n.y + R[6] * n.z, R[1] * n.x + R[4] * n.y + R[7] * n.z, R[2] * n.x + R[5] * n.y + R[8] * n.z)
            let d = o - F.cw
            let pr = SIMD3<Double>(R[0] * d.x + R[3] * d.y + R[6] * d.z, R[1] * d.x + R[4] * d.y + R[7] * d.z, R[2] * d.x + R[5] * d.y + R[8] * d.z) + F.cr
            let L = (nr.x * nr.x + nr.z * nr.z).squareRoot()
            if L < 0.3 { next.append(pc); thin += 1; continue }   // piece lying on its side: the blade runs along its faces
            let cc = (simd_dot(nr, pr) - nr.y * Shape.T / 2) / L
            let la = nr.x / L, lb = nr.z / L
            if !lineCrossesPiece(pc.I, la, lb, cc) { next.append(pc); continue }
            guard let parts = splitPiece(pc.I, la, lb, cc) else { next.append(pc); thin += 1; continue }
            cut += 1
            for (side, I) in [parts.0, parts.1].enumerated() {
                // which way does this half lie in the world? it is nudged away from the blade on that side
                var su = 0.0, sw = 0.0
                for p in I { su += p.x; sw += p.y }
                su /= Double(I.count); sw /= Double(I.count)
                let X = SIMD3<Double>(su - F.cr.x, Shape.T / 2 - F.cr.y, sw - F.cr.z)
                let Wp = SIMD3<Double>(R[0] * X.x + R[1] * X.y + R[2] * X.z, R[3] * X.x + R[4] * X.y + R[5] * X.z, R[6] * X.x + R[7] * X.y + R[8] * X.z) + F.cw
                var sg = (n.x * (Wp.x - o.x) + n.z * (Wp.z - o.z)).sign == .minus ? -1.0 : 1.0
                if n.x * (Wp.x - o.x) + n.z * (Wp.z - o.z) == 0 { sg = side == 1 ? 1 : -1 }
                sep.append((piece: next.count, dir: SIMD3<Float>(Float(n.x * sg), 0, Float(n.z * sg))))
                next.append(Piece(I))
            }
        }
        if cut == 0 { return .failure(.message(thin > 0 ? "Trop fin pour couper ici." : "Raté — tracez la lame en travers de la tranche.")) }
        // do the expensive part now, while the knife is still in the air
        let w = buildWorld(next)
        let ns = SoftBody(mesh: w.sim, firmness: sim.firmness, damping: sim.damping)
        return .success(CutPlan(next: next, sep: sep, world: w, sim: ns, M: SIMD3<Float>(Float(o.x), yTop, Float(o.z)), yTop: yTop, yaw: canonicalYaw(dx, dz)))
    }

    private enum CutMiss: Error { case silent, message(String) }

    // Rebuild the simulation and the GPU buffers for a new set of pieces, carrying the current
    // positions and velocities across by interpolation in the shared rest frame.
    private func installWorld(_ nextPieces: [Piece], sep: [(piece: Int, dir: SIMD3<Float>)] = [], pre: CutPlan? = nil,
                              sepSpeed: Float = 0.75, hop: Float = 0.35) {
        if drag.mode == .grab { sim.endGrab(); drag.mode = nil }
        let old = sim, oldWorld = world
        let w = pre?.world ?? buildWorld(nextPieces)
        let ns = pre?.sim ?? SoftBody(mesh: w.sim, firmness: old.firmness, damping: old.damping)
        ns.firmness = old.firmness; ns.damping = old.damping
        var nsRest = [Float](repeating: 0, count: ns.n * 3)
        for i in 0..<(ns.n * 3) { nsRest[i] = ns.rest[i] }
        let e = embed(simRest: oldWorld.sim.rest, tets: oldWorld.sim.tets, verts: nsRest)
        for i in 0..<ns.n {
            let t = e.tetOf[i]
            for k in 0..<3 {
                var xs: Float = 0, vs: Float = 0
                for j in 0..<4 {
                    let q = old.tets[4 * t + j]
                    xs += old.x[3 * q + k] * e.w[4 * i + j]
                    vs += old.v[3 * q + k] * e.w[4 * i + j]
                }
                ns.x[3 * i + k] = xs; ns.v[3 * i + k] = vs
            }
            if ns.x[3 * i + 1] < 0 { ns.x[3 * i + 1] = 0 }
        }
        for sp in sep {
            for i in 0..<ns.n where Int(ns.comp[i]) == sp.piece {
                ns.v[3 * i] += sp.dir.x * sepSpeed
                ns.v[3 * i + 1] += abs(sp.dir.y) * 0.2 * hop + hop
                ns.v[3 * i + 2] += sp.dir.z * sepSpeed
            }
        }
        ns.prev.update(from: ns.x, count: ns.n * 3)
        pieces = nextPieces; world = w; sim = ns
        sim.blade = blade
        blade.side = [Int8](repeating: 0, count: sim.nComp)
        for sp in sep {
            let s = sp.dir.x * blade.n.x + sp.dir.z * blade.n.z
            blade.side[sp.piece] = s > 0 ? 1 : s < 0 ? -1 : 0
        }
        adoptRenderMesh()
        renderer?.setMesh(world.render, edges: sim.edges, nParticles: sim.n)
    }

    // ── the visible knife: hovers under the finger, lines up over the stroke, then cuts ──
    private func knifeBasis(_ yaw: Float, _ roll: Float, _ pitch: Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let d = SIMD3<Float>(cos(yaw), 0, sin(yaw)), z = SIMD3<Float>(-d.z, 0, d.x)
        // roll about the blade (tips the face up toward the viewer), then pitch (tip down)
        let cr = cos(roll), sr = sin(roll), cp = cos(pitch), sp = sin(pitch)
        let Y1 = SIMD3<Float>(-sr * z.x, cr, -sr * z.z), Z = SIMD3<Float>(cr * z.x, sr, cr * z.z)
        let X = cp * d - sp * Y1
        let Y = sp * d + cp * Y1
        return (X, Y, Z)
    }

    private func poseKnife() {
        let (X, Y, Z) = knifeBasis(kp.yaw, kp.roll, kp.pitch)
        let r = knifeMesh.rest, nr = knifeMesh.nrm, P = kp.P, xr = Float(KnifeSpec.xr)
        var v = 0, o = 0
        while v < r.count {
            let l = SIMD3<Float>(r[v] - xr, r[v + 1], r[v + 2])
            let p = P + X * l.x + Y * l.y + Z * l.z
            let nn = X * nr[v] + Y * nr[v + 1] + Z * nr[v + 2]
            knifeDyn[o] = p.x; knifeDyn[o + 1] = p.y; knifeDyn[o + 2] = p.z
            knifeDyn[o + 3] = nn.x; knifeDyn[o + 4] = nn.y; knifeDyn[o + 5] = nn.z
            v += 3; o += 6
        }
    }

    // where the knife wants to be when it is not cutting
    private func hoverPose() -> KnifePose {
        var q = hoverSeen ? rayPlaneY(rayFrom(hover), T + HOVER_H) : nil
        if var qq = q {
            let dx = qq.x - target.x, dz = qq.z - target.z, dl = (dx * dx + dz * dz).squareRoot()
            if dl > 3 { qq.x = target.x + dx / dl * 3; qq.z = target.z + dz / dl * 3 }
            q = qq
        }
        if q == nil { let c = sim.centroid(); q = SIMD3(c.x + 0.1, T + HOVER_H, c.z + 0.25) }
        return KnifePose(P: q!, yaw: camRightYaw, roll: 0.16, pitch: 0.05)
    }

    // while the stroke is being drawn: lined up over it, edge just above the jelly
    private func strokePose() -> KnifePose {
        let h = T + 0.1
        guard let A = rayPlaneY(rayFrom(strokeA), h), let B = rayPlaneY(rayFrom(strokeB), h) else { return hoverPose() }
        let dl = hypot(B.x - A.x, B.z - A.z)
        let yaw = dl > 0.08 ? canonicalYaw(B.x - A.x, B.z - A.z) : kp.yaw
        return KnifePose(P: [(A.x + B.x) / 2, h, (A.z + B.z) / 2], yaw: yaw, roll: 0.08, pitch: 0)
    }

    private func easeToward(_ pose: KnifePose, _ k: Float) {
        kp.P = lerp3(kp.P, pose.P, k)
        kp.yaw += wrapA(pose.yaw - kp.yaw) * k
        kp.roll = lerp(kp.roll, pose.roll, k); kp.pitch = lerp(kp.pitch, pose.pitch, k)
    }

    // the cut, as a little piece of choreography (seconds)
    private enum KT { static let align: Float = 0.16, press: Float = 0.42, through: Float = 0.6, hold: Float = 0.7, lift: Float = 1.08 }

    private func runKnifeAnim(_ dt: Float) {
        guard let a = knifeAnim else { return }
        let pl = a.plan
        a.t += dt
        let t = a.t, d = SIMD3<Float>(cos(pl.yaw), 0, sin(pl.yaw)), M = pl.M
        func at(_ s: Float, _ y: Float) -> SIMD3<Float> { SIMD3(M.x + d.x * s, y, M.z + d.z * s) }
        let P1 = at(-0.12, pl.yTop + 0.1), P2 = at(0.0, pl.yTop - 0.13), P3 = at(0.2, 0.004)
        if t < KT.align {
            let s = ease(t / KT.align)
            kp.P = lerp3(a.from.P, P1, s)
            kp.yaw = a.from.yaw + wrapA(pl.yaw - a.from.yaw) * s
            kp.roll = lerp(a.from.roll, 0, s); kp.pitch = lerp(a.from.pitch, 0, s)
            blade.mode = nil
        } else if t < KT.press {
            // the edge meets the jelly and pushes it down before it gives
            let s = (t - KT.align) / (KT.press - KT.align)
            kp.P = lerp3(P1, P2, s * s); kp.yaw = pl.yaw; kp.roll = 0; kp.pitch = 0
            blade.mode = .press
        } else if t < KT.hold {
            if !a.committed {
                a.committed = true
                blade.n = SIMD3(-d.z, 0, d.x)
                blade.holdY = kp.P.y
                installWorld(pl.next, sep: pl.sep, pre: pl, sepSpeed: 0.22, hop: 0)
                onReadouts?(readouts())
            }
            let s = 1 - pow(1 - min(1, (t - KT.press) / (KT.through - KT.press)), 2)
            kp.P = lerp3(P2, P3, s)
            blade.halfGap = 0.012 + 0.02 * s
            blade.mode = .split
        } else if t < KT.lift {
            blade.mode = nil
            let s = ease((t - KT.hold) / (KT.lift - KT.hold))
            let h = tool == .knife ? hoverPose() : KnifePose(P: [P3.x, P3.y + 2.5, P3.z], yaw: pl.yaw, roll: 0.3, pitch: 0.05)
            kp.P = lerp3(P3, h.P, s)
            kp.yaw = pl.yaw + wrapA(h.yaw - pl.yaw) * s
            kp.roll = lerp(0, h.roll, s); kp.pitch = lerp(0, h.pitch, s)
        } else {
            knifeAnim = nil; blade.mode = nil
        }
    }

    private func updateKnife(_ dt: Float, _ animDt: Float) {
        if tool != .knife && knifeAnim == nil { knifeVisible = false; blade.mode = nil; return }
        if knifeAnim != nil { runKnifeAnim(animDt) } else { easeToward(drag.mode == .knife ? strokePose() : hoverPose(), 1 - exp(-dt * 16)) }
        blade.p = kp.P; blade.d = SIMD3(cos(kp.yaw), 0, sin(kp.yaw))
        if knifeAnim == nil || !(knifeAnim!.committed) { blade.n = SIMD3(-blade.d.z, 0, blade.d.x) }
        poseKnife()
        knifeVisible = true
    }

    // ── touches (view-local points) ──
    private func rotMat(_ axis: SIMD3<Float>, _ ang: Float) -> [Float] {
        let x = axis.x, y = axis.y, z = axis.z, c = cos(ang), s = sin(ang), t = 1 - c
        return [t * x * x + c, t * x * y - s * z, t * x * z + s * y,
                t * x * y + s * z, t * y * y + c, t * y * z - s * x,
                t * x * z - s * y, t * y * z + s * x, t * z * z + c]
    }

    private func dragTarget(_ p: CGPoint) -> SIMD3<Float>? {
        let ray = rayFrom(p)
        let (pp, n) = drag.plane
        let den = simd_dot(ray.d, n)
        if abs(den) < 1e-5 { return nil }
        let t = simd_dot(pp - ray.o, n) / den
        var q = ray.o + ray.d * t
        // keep the grab within a generous but finite reach, and above the floor
        let dx = q.x - target.x, dz = q.z - target.z, lim: Float = 3.4, dl = (dx * dx + dz * dz).squareRoot()
        if dl > lim { q.x = target.x + dx / dl * lim; q.z = target.z + dz / dl * lim }
        q.y = min(max(q.y, 0.02), 3.2)
        return q
    }

    private func applyGrab(_ p: CGPoint) {
        if let q = dragTarget(p) { sim.moveGrab(q, rot: rotMat(camFwd, drag.twist)) }
    }

    func hoverMoved(_ p: CGPoint) {
        if drag.mode == nil { hover = p; hoverSeen = true }
    }

    func touchBegan(id: Int, at p: CGPoint) {
        if drag.mode == .grab && id != drag.id {
            // second finger twists the grabbed patch
            drag.second = (id, p)
            drag.twist0 = drag.twist - Float(atan2(p.y - drag.last.y, p.x - drag.last.x))
            return
        }
        if drag.mode == .orbit && id != drag.id {
            // second finger while orbiting: pinch to zoom
            drag.second = (id, p)
            drag.mode = .pinch
            drag.pinchD0 = max(20, hypot(p.x - drag.last.x, p.y - drag.last.y))
            drag.zoom0 = zoom
            return
        }
        if drag.mode != nil { return }
        drag.moved = 0
        if tool == .knife {
            if paused || knifeAnim != nil { return }
            drag.mode = .knife; drag.id = id
            hover = p; hoverSeen = true
            strokeA = p; strokeB = p
            onStroke?(strokeA, strokeB, true)
            return
        }
        let hit = !paused ? (pick(rayFrom(p)) ?? pickNear(p, maxPx: 34)) : nil
        drag.id = id; drag.last = p
        if let hit {
            drag.mode = .grab; drag.twist = 0
            drag.plane = (hit, camFwd)
            sim.beginGrab(hit, radius: 0.4)
        } else {
            drag.mode = .orbit
        }
    }

    func touchMoved(id: Int, to p: CGPoint) {
        if let s = drag.second, s.id == id {
            drag.second = (id, p)
            if drag.mode == .pinch {
                let d = max(20, hypot(p.x - drag.last.x, p.y - drag.last.y))
                zoom = max(0.65, min(1.6, drag.zoom0 * Float(drag.pinchD0 / d)))
            } else if drag.mode == .grab {
                drag.twist = drag.twist0 + Float(atan2(p.y - drag.last.y, p.x - drag.last.x))
                drag.twist = max(-1.3, min(1.3, drag.twist))
                applyGrab(drag.last)
            }
            return
        }
        if id != drag.id || drag.mode == nil { return }
        if drag.mode == .knife {
            strokeB = p
            onStroke?(strokeA, strokeB, true)
            return
        }
        let dx = Float(p.x - drag.last.x), dy = Float(p.y - drag.last.y)
        drag.moved += hypot(p.x - drag.last.x, p.y - drag.last.y)
        drag.last = p
        switch drag.mode {
        case .grab?:
            applyGrab(p)
        case .orbit?:
            az = max(-0.35, min(1.6, az - dx * 0.006))
            el = max(0.12, min(1.25, el + dy * 0.005))
        case .pinch?:
            if let s = drag.second {
                let d = max(20, hypot(s.p.x - p.x, s.p.y - p.y))
                zoom = max(0.65, min(1.6, drag.zoom0 * Float(drag.pinchD0 / d)))
            }
        default: break
        }
    }

    func touchEnded(id: Int, at p: CGPoint, cancelled: Bool, tapCount: Int) {
        if let s = drag.second, s.id == id {
            drag.second = nil
            if drag.mode == .pinch { drag.mode = .orbit }
            return
        }
        if id != drag.id { return }
        if drag.mode == .knife {
            if !cancelled {
                strokeB = p
                switch planCut(strokeA, strokeB) {
                case .success(let plan):
                    knifeAnim = KnifeAnim(plan: plan, from: kp)
                case .failure(.message(let m)):
                    onToast?(m)
                case .failure(.silent):
                    break
                }
                hover = p
            }
            onStroke?(strokeA, strokeB, false)
        }
        if drag.mode == .grab { sim.endGrab() }
        if drag.mode == .orbit && tapCount >= 2 && drag.moved < 10 { resetCamera() }
        drag.mode = nil; drag.id = -1; drag.second = nil
    }

    // ── readouts ──
    func readouts() -> Readouts {
        let massG = sim.totalRestVolume * pow(SCALE_CM, 3) * DENSITY
        // KE with the illustrative length scale: v[m/s] = v_sim × 0.035, m[kg] = share of the candy's mass
        let ke = sim.kineticEnergy() / sim.totalMass * (massG / 1000) * pow(SCALE_CM / 100, 2)
        return Readouts(massG: massG, volumePct: sim.volumeRatio() * 100, kineticMicroJ: ke * 1e6,
                        pieces: pieces.count, particles: sim.n, tets: sim.nT)
    }

    // ── MTKViewDelegate: the loop ──
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in mtkView: MTKView) {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60.0 : min(now - lastTime, 0.1))
        lastTime = now
        viewSize = mtkView.bounds.size

        if !paused {
            acc += dt * (slow ? 0.25 : 1)
            var steps = 0
            while acc >= sim.stepDt && steps < 3 { sim.step(); acc -= sim.stepDt; steps += 1 }
            if steps == 3 { acc = min(acc, sim.stepDt) }
            time += dt
        }
        // the knife may swap in a new world mid-cut, so it goes before skinning
        updateKnife(dt, paused ? 0 : dt * (slow ? 0.25 : 1))
        skin()
        followSlice(dt)
        updateCamera()
        updateLight()

        var u = Uniforms()
        u.viewProj = viewProj; u.view = view; u.invViewProj = invViewProj
        u.lightVP = lightVP; u.topVP = topVP
        u.camPos = SIMD4(camPos, time)
        u.camFwd = SIMD4(camFwd, 0)
        u.keyDir = SIMD4(keyDir, keyIntensity)
        let p = palette
        u.flesh = SIMD4(p.flesh, 1); u.fleshDeep = SIMD4(p.fleshDeep, 1); u.pale = SIMD4(p.pale, 1)
        u.skin = SIMD4(p.skin, 1); u.stripe = SIMD4(p.stripe, 1); u.seed = SIMD4(p.seed, 1)
        u.shape = SIMD4(Float(Shape.T), Float(Shape.Ro), Float(Shape.skin), Float(Shape.pale))
        u.misc = SIMD4(1.0, showMesh ? 0.32 : 0, 0, 0)
        u.bg = SIMD4(BG_RENDER, 1)
        u.shadowTint = SIMD4(p.shadowTint, 1)

        renderer.draw(in: mtkView, Renderer.FrameInput(
            uniforms: u, dyn: UnsafePointer(dyn), knifeDyn: UnsafePointer(knifeDyn),
            particles: UnsafePointer(sim.x), showMesh: showMesh, knifeVisible: knifeVisible))

        readoutT += dt
        if readoutT > 0.12 { readoutT = 0; onReadouts?(readouts()) }
    }
}
