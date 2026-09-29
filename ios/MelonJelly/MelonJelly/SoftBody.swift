// ─────────────────────────────────────────────────────────────
//  XPBD tetrahedral soft body
//  · co-rotational tet constraints → elasticity (each tet pulled toward its
//                                    best-fit rotated rest shape; recovers inversions)
//  · tet volume constraints        → near-incompressibility
//  · soft grab attachment, ground contact with friction
//  · relative-velocity damping along edges (internal viscosity)
//  Fixed step, fixed substeps, "small steps" XPBD (1 iteration / substep).
//  Hot loops run over raw buffers so the solver stays real-time on device.
// ─────────────────────────────────────────────────────────────

import Foundation
import simd

@inline(__always) private func buf<T>(_ count: Int, _ v: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: max(count, 1))
    p.initialize(repeating: v, count: max(count, 1))
    return p
}

final class Blade {
    enum Mode { case press, split }
    var mode: Mode?
    var holdY: Float = 0
    var p = SIMD3<Float>(0, 0, 0)
    var d = SIMD3<Float>(1, 0, 0)
    var n = SIMD3<Float>(0, 0, 1)
    var a0: Float = -Float(KnifeSpec.xr)
    var a1: Float = Float(KnifeSpec.Lb - KnifeSpec.xr)
    var top: Float = Float(KnifeSpec.H * 0.95)
    var halfGap: Float = 0.03
    var side: [Int8] = []
}

struct PieceFrame {
    var cw: SIMD3<Double>
    var cr: SIMD3<Double>
    var R: [Double]   // row-major 3×3, rest → world
}

final class SoftBody {
    let n: Int, nT: Int
    private(set) var nE: Int = 0
    let nComp: Int
    let comp: UnsafeMutablePointer<UInt16>
    let tets: UnsafeMutablePointer<Int>
    let rest: UnsafeMutablePointer<Float>
    let x: UnsafeMutablePointer<Float>
    let prev: UnsafeMutablePointer<Float>
    let v: UnsafeMutablePointer<Float>
    let invMass: UnsafeMutablePointer<Float>
    let mass: UnsafeMutablePointer<Float>
    let restVol: UnsafeMutablePointer<Float>
    private(set) var edges: [UInt32] = []   // pairs, also used as the line index buffer
    private var edgesP: UnsafeMutablePointer<Int>
    private var restLen: UnsafeMutablePointer<Float>
    private let tetQ: UnsafeMutablePointer<Float>
    private let tetRot: UnsafeMutablePointer<Float>
    private let tetFirm: UnsafeMutablePointer<Float>
    private(set) var totalRestVolume: Double = 0
    private(set) var totalMass: Double = 0
    private var subIndex = 0

    // parameters (tuned in sim units: metres-ish, seconds)
    let gravity: Float = -9.81
    var firmness: Float = 0.5
    var damping: Float = 0.45
    let substeps = 10
    let stepDt: Float = 1.0 / 60.0
    let friction: Float = 0.55
    let floorY: Float = 0
    let maxSpeed: Float = 12

    var blade: Blade?

    // grab state
    private let grabIdx: UnsafeMutablePointer<Int>
    private let grabW: UnsafeMutablePointer<Float>
    private let grabOff: UnsafeMutablePointer<Float>
    private var grabN = 0
    private var grabTarget = SIMD3<Float>(0, 0, 0)
    private var grabStart = SIMD3<Float>(0, 0, 0)
    private var grabRot: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    private(set) var grabbing = false

    // collision scratch
    private var cBox: [Float] = []
    private let cListA: UnsafeMutablePointer<Int>
    private let cListB: UnsafeMutablePointer<Int>

    var time: Double = 0

    init(mesh: SimMesh, firmness: Float = 0.5, damping: Float = 0.45) {
        self.n = mesh.rest.count / 3
        self.nT = mesh.tets.count / 4
        nComp = max(mesh.nComp, 1)
        self.firmness = firmness
        self.damping = damping
        let n = mesh.rest.count / 3, nT = mesh.tets.count / 4
        comp = buf(n, 0)
        tets = buf(nT * 4, 0)
        rest = buf(n * 3, 0)
        x = buf(n * 3, 0); prev = buf(n * 3, 0); v = buf(n * 3, 0)
        invMass = buf(n, 0); mass = buf(n, 0); restVol = buf(nT, 0)
        tetQ = buf(nT * 12, 0); tetRot = buf(nT * 4, 0); tetFirm = buf(nT, 1)
        grabIdx = buf(n, 0); grabW = buf(n, 0); grabOff = buf(n * 3, 0)
        cListA = buf(n, 0); cListB = buf(n, 0)
        edgesP = buf(1, 0); restLen = buf(1, 0)
        // every stored property is set from here on
        for i in 0..<n { comp[i] = i < mesh.comp.count ? mesh.comp[i] : 0 }
        for i in 0..<(nT * 4) { tets[i] = Int(mesh.tets[i]) }
        for i in 0..<(n * 3) { rest[i] = mesh.rest[i] }

        let density: Float = 1.0
        var vol = 0.0
        for t in 0..<nT {
            let vt = tetVol(rest, t)
            restVol[t] = vt; vol += Double(vt)
            for k in 0..<4 { mass[tets[4 * t + k]] += vt * density / 4 }
        }
        totalRestVolume = vol
        for i in 0..<n {
            if mass[i] <= 0 { mass[i] = 1e-6 }
            invMass[i] = 1 / mass[i]; totalMass += Double(mass[i])
        }

        // unique edges
        var set = Set<Int>()
        var keys: [Int] = []
        let pairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
        for t in 0..<nT {
            for (a, b) in pairs {
                var i = tets[4 * t + a], j = tets[4 * t + b]
                if i > j { swap(&i, &j) }
                let k = i * 1_048_576 + j
                if set.insert(k).inserted { keys.append(k) }
            }
        }
        nE = keys.count
        var e = [Int](repeating: 0, count: nE * 2)
        var rl = [Float](repeating: 0, count: nE)
        for (q, k) in keys.enumerated() {
            let i = k / 1_048_576, j = k % 1_048_576
            e[2 * q] = i; e[2 * q + 1] = j
            let dx = rest[3 * i] - rest[3 * j], dy = rest[3 * i + 1] - rest[3 * j + 1], dz = rest[3 * i + 2] - rest[3 * j + 2]
            rl[q] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        // shuffle edge order a little (reduces Gauss–Seidel directional bias)
        if nE > 1 {
            for k in stride(from: nE - 1, to: 0, by: -1) {
                let r = (k * 2654435761) % (k + 1)
                e.swapAt(2 * k, 2 * r); e.swapAt(2 * k + 1, 2 * r + 1)
                rl.swapAt(k, r)
            }
        }
        edgesP.deallocate(); restLen.deallocate()
        edgesP = buf(nE * 2, 0); restLen = buf(nE, 0)
        for i in 0..<(nE * 2) { edgesP[i] = e[i] }
        for i in 0..<nE { restLen[i] = rl[i] }
        edges = e.map { UInt32($0) }

        // co-rotational tet elasticity: rest shape about the centroid, warm-started rotation
        for t in 0..<nT {
            let id = [tets[4 * t], tets[4 * t + 1], tets[4 * t + 2], tets[4 * t + 3]]
            var c = SIMD3<Float>(0, 0, 0), M: Float = 0
            for q in id { let mv = mass[q]; M += mv; c += SIMD3(rest[3 * q], rest[3 * q + 1], rest[3 * q + 2]) * mv }
            c /= M
            for k in 0..<4 {
                tetQ[12 * t + 3 * k] = rest[3 * id[k]] - c.x
                tetQ[12 * t + 3 * k + 1] = rest[3 * id[k] + 1] - c.y
                tetQ[12 * t + 3 * k + 2] = rest[3 * id[k] + 2] - c.z
            }
            tetRot[4 * t + 3] = 1
            var rg = 0
            for q in id { rg += Int(mesh.region[q]) }
            tetFirm[t] = rg >= 6 ? 0.3 : rg >= 3 ? 0.5 : rg >= 1 ? 0.75 : 1.0
        }
        reset(drop: 0)
    }

    deinit {
        comp.deallocate(); tets.deallocate(); rest.deallocate(); x.deallocate(); prev.deallocate(); v.deallocate()
        invMass.deallocate(); mass.deallocate(); restVol.deallocate(); edgesP.deallocate(); restLen.deallocate()
        tetQ.deallocate(); tetRot.deallocate(); tetFirm.deallocate()
        grabIdx.deallocate(); grabW.deallocate(); grabOff.deallocate(); cListA.deallocate(); cListB.deallocate()
    }

    @inline(__always) func tetVol(_ p: UnsafeMutablePointer<Float>, _ t: Int) -> Float {
        let a = tets[4 * t], b = tets[4 * t + 1], c = tets[4 * t + 2], d = tets[4 * t + 3]
        let ax = p[3 * a], ay = p[3 * a + 1], az = p[3 * a + 2]
        let b0 = p[3 * b] - ax, b1 = p[3 * b + 1] - ay, b2 = p[3 * b + 2] - az
        let c0 = p[3 * c] - ax, c1 = p[3 * c + 1] - ay, c2 = p[3 * c + 2] - az
        let d0 = p[3 * d] - ax, d1 = p[3 * d + 1] - ay, d2 = p[3 * d + 2] - az
        return (b0 * (c1 * d2 - c2 * d1) - b1 * (c0 * d2 - c2 * d0) + b2 * (c0 * d1 - c1 * d0)) / 6
    }

    func reset(drop: Float = 0.35) {
        for i in 0..<n {
            x[3 * i] = rest[3 * i]
            x[3 * i + 1] = rest[3 * i + 1] + drop
            x[3 * i + 2] = rest[3 * i + 2]
        }
        prev.update(from: x, count: n * 3)
        v.update(repeating: 0, count: n * 3)
        for t in 0..<nT { tetRot[4 * t] = 0; tetRot[4 * t + 1] = 0; tetRot[4 * t + 2] = 0; tetRot[4 * t + 3] = 1 }
        endGrab()
    }

    // stiffness mapping: firmness 0..1 → compliance (log scale)
    func shapeCompliance() -> Float {
        let a: Float = logf(3.0), b: Float = logf(0.05)
        return expf(a + (b - a) * firmness)
    }
    func volCompliance() -> Float { 1e-4 * (1 - 0.7 * firmness) }
    // damping 0..1 → rate (1/s) of relative-velocity decay along edges
    func dampRate() -> Float { 2 + 40 * damping * damping }

    func nudge(strength: Float = 1) {
        // small hop with a twist — every particle gets v = v_lin + ω × (x − c)
        let c = centroid()
        let vy = 2.2 * strength, wx = 2.4 * strength, wz = -1.5 * strength, wy = 1.2 * strength
        for i in 0..<n {
            let rx = x[3 * i] - c.x, ry = x[3 * i + 1] - c.y, rz = x[3 * i + 2] - c.z
            v[3 * i] += wy * rz - wz * ry
            v[3 * i + 1] += vy + wz * rx - wx * rz
            v[3 * i + 2] += wx * ry - wy * rx
        }
    }

    func centroid() -> SIMD3<Float> {
        var s = SIMD3<Float>(0, 0, 0), m: Float = 0
        for i in 0..<n {
            let w = mass[i]; m += w
            s += SIMD3(x[3 * i], x[3 * i + 1], x[3 * i + 2]) * w
        }
        return s / m
    }

    // ── grabbing ──
    func beginGrab(_ hit: SIMD3<Float>, radius: Float = 0.4) {
        grabN = 0
        var nearest = -1, nd = Float.infinity
        for i in 0..<n {
            let d = simd_length(SIMD3(x[3 * i], x[3 * i + 1], x[3 * i + 2]) - hit)
            if d < nd { nd = d; nearest = i }
        }
        let cg = nearest >= 0 ? comp[nearest] : 0   // only the piece that was touched
        for i in 0..<n where comp[i] == cg {
            let dx = x[3 * i] - hit.x, dy = x[3 * i + 1] - hit.y, dz = x[3 * i + 2] - hit.z
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d < radius {
                let f = 1 - d / radius
                let k = grabN; grabN += 1
                grabIdx[k] = i; grabW[k] = f * f * (3 - 2 * f)
                grabOff[3 * k] = dx; grabOff[3 * k + 1] = dy; grabOff[3 * k + 2] = dz
            }
        }
        if grabN == 0 && nearest >= 0 {
            grabIdx[0] = nearest; grabW[0] = 1
            grabOff[0] = x[3 * nearest] - hit.x; grabOff[1] = x[3 * nearest + 1] - hit.y; grabOff[2] = x[3 * nearest + 2] - hit.z
            grabN = 1
        }
        grabTarget = hit
        grabStart = hit
        grabRot = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        grabbing = true
    }

    func moveGrab(_ target: SIMD3<Float>, rot: [Float]?) {
        grabTarget = target
        // bounded reach: a strong stretch, never an unbounded one
        let dv = target - grabStart
        let d = simd_length(dv), maxReach: Float = 2.2
        if d > maxReach { grabTarget = grabStart + dv * (maxReach / d) }
        if let rot { grabRot = rot }
        // never drive the held patch into the floor: lift the whole patch instead of crushing it
        let R = grabRot
        var lowest = Float.infinity
        for k in 0..<grabN { lowest = min(lowest, R[3] * grabOff[3 * k] + R[4] * grabOff[3 * k + 1] + R[5] * grabOff[3 * k + 2]) }
        if lowest.isFinite { grabTarget.y = max(grabTarget.y, floorY + 0.004 - lowest) }
    }

    func endGrab() { grabbing = false; grabN = 0 }

    // ── simulation ──
    func step() {
        let dt = stepDt / Float(substeps)
        for _ in 0..<substeps { substep(dt) }
        time += Double(stepDt)
        // settling: once the jelly is nearly still, bleed off the last residual jitter
        if !grabbing {
            let ke = kineticEnergy() / totalMass
            if ke < 2e-3 {
                let f = Float(max(0.86, 1 - 0.14 * (1 - ke / 2e-3)))
                for i in 0..<(n * 3) { v[i] *= f }
            }
        }
        // safety: any non-finite value → reset gently
        var i = 0
        while i < n * 3 {
            if !x[i].isFinite { reset(drop: 0.2); break }
            i += 97
        }
    }

    private func substep(_ dt: Float) {
        let g = gravity * dt
        // light air drag; while held, the hand steadies the slice a little more
        let rate: Float = grabbing ? 2.5 : 0.08
        let air = expf(-rate * dt)
        for i in 0..<n {
            let k = 3 * i
            v[k + 1] += g
            v[k] *= air; v[k + 1] *= air; v[k + 2] *= air
            prev[k] = x[k]; prev[k + 1] = x[k + 1]; prev[k + 2] = x[k + 2]
            x[k] += v[k] * dt; x[k + 1] += v[k + 1] * dt; x[k + 2] += v[k + 2] * dt
        }
        if grabbing { solveGrab(dt) }
        solveTets(dt)
        solveVolumes(dt)
        if nComp > 1 {
            if subIndex & 1 == 0 { collidePieces() }
            subIndex += 1
        }
        if let b = blade, b.mode != nil { solveBlade(b) }
        solveFloor()
        let inv = 1 / dt, vmax = maxSpeed
        var i = 0
        while i < 3 * n {
            var vx = (x[i] - prev[i]) * inv, vy = (x[i + 1] - prev[i + 1]) * inv, vz = (x[i + 2] - prev[i + 2]) * inv
            let sp = (vx * vx + vy * vy + vz * vz).squareRoot()
            if sp > vmax { let f = vmax / sp; vx *= f; vy *= f; vz *= f }
            v[i] = vx; v[i + 1] = vy; v[i + 2] = vz
            i += 3
        }
        dampEdges(dt)
    }

    // The visible knife. Before the cut it presses a rounded groove under its edge (the jelly
    // squashes before it gives); after the cut it wedges the two new faces apart as it sinks.
    private func solveBlade(_ b: Blade) {
        let px = b.p.x, py = b.p.y, pz = b.p.z
        let dx = b.d.x, dz = b.d.z, nx = b.n.x, nz = b.n.z
        let press = b.mode == .press
        let W: Float = press ? 0.12 : b.halfGap, WP: Float = 0.12
        for i in 0..<n {
            let k = 3 * i
            let rx = x[k] - px, rz = x[k + 2] - pz
            let along = rx * dx + rz * dz
            if along < b.a0 || along > b.a1 { continue }
            let h = x[k + 1] - py
            if h > b.top { continue }
            let z = rx * nx + rz * nz, az = abs(z)
            if !press && az < WP {
                // the cut lips stay held down at the depth of the break-through while the blade passes
                let hmax = b.holdY + 0.1 * (az / WP) * (az / WP)
                if x[k + 1] > hmax { x[k + 1] = hmax }
            }
            if az >= W { continue }
            if press {
                let hmax = 0.1 * (az / W) * (az / W)
                if h > hmax { x[k + 1] = py + hmax }
            } else if h > -0.03 {
                let ci = Int(comp[i])
                var s: Float = ci < b.side.count ? Float(b.side[ci]) : 0
                if s == 0 { s = z >= 0 ? 1 : -1 }
                // eased: a few millimetres per substep, so the faces are wedged apart rather than kicked
                let push = max(-0.003, min(0.003, s * W - z))
                x[k] += nx * push; x[k + 2] += nz * push
            }
        }
    }

    private func solveGrab(_ dt: Float) {
        let a = 2e-6 / (dt * dt)
        let R = grabRot, T = grabTarget
        for k in 0..<grabN {
            let i = grabIdx[k], w = invMass[i]
            let ox = grabOff[3 * k], oy = grabOff[3 * k + 1], oz = grabOff[3 * k + 2]
            let tx = T.x + R[0] * ox + R[1] * oy + R[2] * oz
            let ty = max(T.y + R[3] * ox + R[4] * oy + R[5] * oz, floorY + 0.005)
            let tz = T.z + R[6] * ox + R[7] * oy + R[8] * oz
            var f = grabW[k] * w / (w + a)
            // pressing down near the table: yield instead of crushing the jelly underneath
            if ty < x[3 * i + 1] && ty < 0.45 { f *= max(0.12, ty / 0.45) }
            x[3 * i] += (tx - x[3 * i]) * f
            x[3 * i + 1] += (ty - x[3 * i + 1]) * f
            x[3 * i + 2] += (tz - x[3 * i + 2]) * f
        }
    }

    // Per-tet co-rotational shape matching: find the rotation that best maps the rest tet onto the
    // current one (Müller et al. 2016, warm-started quaternion), then pull the four corners toward the
    // rotated rest shape with XPBD compliance. Inverted tets are always pushed back to a proper shape.
    private func solveTets(_ dt: Float) {
        let base = shapeCompliance() / (dt * dt)
        let Q = tetRot
        for t in 0..<nT {
            let a = 3 * tets[4 * t], b = 3 * tets[4 * t + 1], c = 3 * tets[4 * t + 2], d = 3 * tets[4 * t + 3]
            let ma = mass[a / 3], mb = mass[b / 3], mc = mass[c / 3], md = mass[d / 3]
            let M = ma + mb + mc + md
            let cx = (x[a] * ma + x[b] * mb + x[c] * mc + x[d] * md) / M
            let cy = (x[a + 1] * ma + x[b + 1] * mb + x[c + 1] * mc + x[d + 1] * md) / M
            let cz = (x[a + 2] * ma + x[b + 2] * mb + x[c + 2] * mc + x[d + 2] * md) / M
            let T = 12 * t
            // A = Σ m p qᵀ (mass-weighted covariance of current vs rest, both about their centroids)
            var f00: Float = 0, f01: Float = 0, f02: Float = 0, f10: Float = 0, f11: Float = 0, f12: Float = 0, f20: Float = 0, f21: Float = 0, f22: Float = 0
            func acc(_ p: Int, _ m: Float, _ qo: Int) {
                let px = (x[p] - cx) * m, py = (x[p + 1] - cy) * m, pz = (x[p + 2] - cz) * m
                let q0 = tetQ[qo], q1 = tetQ[qo + 1], q2 = tetQ[qo + 2]
                f00 += px * q0; f01 += px * q1; f02 += px * q2
                f10 += py * q0; f11 += py * q1; f12 += py * q2
                f20 += pz * q0; f21 += pz * q1; f22 += pz * q2
            }
            acc(a, ma, T); acc(b, mb, T + 3); acc(c, mc, T + 6); acc(d, md, T + 9)
            var qx = Q[4 * t], qy = Q[4 * t + 1], qz = Q[4 * t + 2], qw = Q[4 * t + 3]
            var r00: Float = 1, r01: Float = 0, r02: Float = 0, r10: Float = 0, r11: Float = 1, r12: Float = 0, r20: Float = 0, r21: Float = 0, r22: Float = 1
            for _ in 0..<2 {
                r00 = 1 - 2 * (qy * qy + qz * qz); r01 = 2 * (qx * qy - qw * qz); r02 = 2 * (qx * qz + qw * qy)
                r10 = 2 * (qx * qy + qw * qz); r11 = 1 - 2 * (qx * qx + qz * qz); r12 = 2 * (qy * qz - qw * qx)
                r20 = 2 * (qx * qz - qw * qy); r21 = 2 * (qy * qz + qw * qx); r22 = 1 - 2 * (qx * qx + qy * qy)
                let ox = (r10 * f20 - r20 * f10) + (r11 * f21 - r21 * f11) + (r12 * f22 - r22 * f12)
                let oy = (r20 * f00 - r00 * f20) + (r21 * f01 - r01 * f21) + (r22 * f02 - r02 * f22)
                let oz = (r00 * f10 - r10 * f00) + (r01 * f11 - r11 * f01) + (r02 * f12 - r12 * f02)
                let den = abs(r00 * f00 + r10 * f10 + r20 * f20 + r01 * f01 + r11 * f11 + r21 * f21 + r02 * f02 + r12 * f12 + r22 * f22) + 1e-12
                let wx = ox / den, wy = oy / den, wz = oz / den
                let w = (wx * wx + wy * wy + wz * wz).squareRoot()
                if w < 1e-6 { break }
                // small-angle quaternion step (renormalised below); large jumps are clamped
                let sc: Float = w > 1 ? 0.5 / w : 0.5
                let ax = wx * sc, ay = wy * sc, az = wz * sc
                let nx = qx + ax * qw + ay * qz - az * qy
                let ny = qy - ax * qz + ay * qw + az * qx
                let nz = qz + ax * qy - ay * qx + az * qw
                let nw = qw - ax * qx - ay * qy - az * qz
                let nl = 1 / (nx * nx + ny * ny + nz * nz + nw * nw).squareRoot()
                qx = nx * nl; qy = ny * nl; qz = nz * nl; qw = nw * nl
            }
            r00 = 1 - 2 * (qy * qy + qz * qz); r01 = 2 * (qx * qy - qw * qz); r02 = 2 * (qx * qz + qw * qy)
            r10 = 2 * (qx * qy + qw * qz); r11 = 1 - 2 * (qx * qx + qz * qz); r12 = 2 * (qy * qz - qw * qx)
            r20 = 2 * (qx * qz - qw * qy); r21 = 2 * (qy * qz + qw * qx); r22 = 1 - 2 * (qx * qx + qy * qy)
            Q[4 * t] = qx; Q[4 * t + 1] = qy; Q[4 * t + 2] = qz; Q[4 * t + 3] = qw
            // the same fraction for all four corners keeps linear and angular momentum intact
            let f = 1 / (1 + base * tetFirm[t] * M * 0.25)
            func pull(_ p: Int, _ qo: Int) {
                let q0 = tetQ[qo], q1 = tetQ[qo + 1], q2 = tetQ[qo + 2]
                x[p] += (cx + r00 * q0 + r01 * q1 + r02 * q2 - x[p]) * f
                x[p + 1] += (cy + r10 * q0 + r11 * q1 + r12 * q2 - x[p + 1]) * f
                x[p + 2] += (cz + r20 * q0 + r21 * q1 + r22 * q2 - x[p + 2]) * f
            }
            pull(a, T); pull(b, T + 3); pull(c, T + 6); pull(d, T + 9)
        }
    }

    private func solveVolumes(_ dt: Float) {
        let alpha0 = volCompliance() / (dt * dt)
        for t in 0..<nT {
            let a = tets[4 * t], b = tets[4 * t + 1], c = tets[4 * t + 2], d = tets[4 * t + 3]
            let A = 3 * a, B = 3 * b, Cc = 3 * c, D = 3 * d
            // gradients (Müller): g_a = (d-b)×(c-b), g_b = (c-a)×(d-a), g_c = (d-a)×(b-a), g_d = (b-a)×(c-a)
            let bax = x[B] - x[A], bay = x[B + 1] - x[A + 1], baz = x[B + 2] - x[A + 2]
            let cax = x[Cc] - x[A], cay = x[Cc + 1] - x[A + 1], caz = x[Cc + 2] - x[A + 2]
            let dax = x[D] - x[A], day = x[D + 1] - x[A + 1], daz = x[D + 2] - x[A + 2]
            let dbx = x[D] - x[B], dby = x[D + 1] - x[B + 1], dbz = x[D + 2] - x[B + 2]
            let cbx = x[Cc] - x[B], cby = x[Cc + 1] - x[B + 1], cbz = x[Cc + 2] - x[B + 2]
            let gax = dby * cbz - dbz * cby, gay = dbz * cbx - dbx * cbz, gaz = dbx * cby - dby * cbx
            let gbx = cay * daz - caz * day, gby = caz * dax - cax * daz, gbz = cax * day - cay * dax
            let gcx = day * baz - daz * bay, gcy = daz * bax - dax * baz, gcz = dax * bay - day * bax
            let gdx = bay * caz - baz * cay, gdy = baz * cax - bax * caz, gdz = bax * cay - bay * cax
            let V = (dax * gdx + day * gdy + daz * gdz) / 6
            let wa = invMass[a], wb = invMass[b], wc = invMass[c], wd = invMass[d]
            var wsum = wa * (gax * gax + gay * gay + gaz * gaz)
            wsum += wb * (gbx * gbx + gby * gby + gbz * gbz)
            wsum += wc * (gcx * gcx + gcy * gcy + gcz * gcz)
            wsum += wd * (gdx * gdx + gdy * gdy + gdz * gdz)
            if wsum < 1e-12 { continue }
            let r0 = restVol[t]
            // anti-inversion: elements far below rest volume get a rigid (compliance-free) correction
            let alpha: Float = V < 0.25 * r0 ? 0 : alpha0
            let C = 6 * (V - r0)
            let s = -C / (wsum + alpha)
            x[A] += gax * s * wa; x[A + 1] += gay * s * wa; x[A + 2] += gaz * s * wa
            x[B] += gbx * s * wb; x[B + 1] += gby * s * wb; x[B + 2] += gbz * s * wb
            x[Cc] += gcx * s * wc; x[Cc + 1] += gcy * s * wc; x[Cc + 2] += gcz * s * wc
            x[D] += gdx * s * wd; x[D + 1] += gdy * s * wd; x[D + 2] += gdz * s * wd
        }
    }

    // pieces push each other apart: particle spheres of different pieces may not overlap.
    // Only pairs of pieces whose bounding boxes touch are examined, and only the particles
    // inside the shared region — so pieces lying apart cost almost nothing.
    private func collidePieces() {
        let D: Float = 0.13
        if cBox.count != nComp * 6 { cBox = [Float](repeating: 0, count: nComp * 6) }
        for c in 0..<nComp {
            cBox[6 * c] = .infinity; cBox[6 * c + 1] = .infinity; cBox[6 * c + 2] = .infinity
            cBox[6 * c + 3] = -.infinity; cBox[6 * c + 4] = -.infinity; cBox[6 * c + 5] = -.infinity
        }
        for p in 0..<n {
            let o = 6 * Int(comp[p])
            for k in 0..<3 {
                let q = x[3 * p + k]
                if q < cBox[o + k] { cBox[o + k] = q }
                if q > cBox[o + 3 + k] { cBox[o + 3 + k] = q }
            }
        }
        let LA = cListA, LB = cListB
        for A in 0..<nComp {
            for B in (A + 1)..<max(A + 1, nComp) {
                var lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(0, 0, 0)
                var overlap = true
                for k in 0..<3 {
                    lo[k] = max(cBox[6 * A + k], cBox[6 * B + k]) - D
                    hi[k] = min(cBox[6 * A + 3 + k], cBox[6 * B + 3 + k]) + D
                    if lo[k] > hi[k] { overlap = false; break }
                }
                if !overlap { continue }
                var na = 0, nb = 0
                for p in 0..<n {
                    let c = Int(comp[p])
                    if c != A && c != B { continue }
                    let px = x[3 * p], py = x[3 * p + 1], pz = x[3 * p + 2]
                    if px < lo.x || px > hi.x || py < lo.y || py > hi.y || pz < lo.z || pz > hi.z { continue }
                    if c == A { LA[na] = p; na += 1 } else { LB[nb] = p; nb += 1 }
                }
                for i in 0..<na {
                    let p = LA[i]
                    for j in 0..<nb {
                        let q = LB[j]
                        let dx = x[3 * q] - x[3 * p], dy = x[3 * q + 1] - x[3 * p + 1], dz = x[3 * q + 2] - x[3 * p + 2]
                        let d2 = dx * dx + dy * dy + dz * dz
                        if d2 >= D * D || d2 < 1e-12 { continue }
                        let d = d2.squareRoot(), wp = invMass[p], wq = invMass[q]
                        // gentle: a few millimetres per pass, so freshly cut faces ease apart instead of popping
                        let push = min(D - d, 0.006) / (d * (wp + wq))
                        x[3 * p] -= dx * push * wp; x[3 * p + 1] -= dy * push * wp; x[3 * p + 2] -= dz * push * wp
                        x[3 * q] += dx * push * wq; x[3 * q + 1] += dy * push * wq; x[3 * q + 2] += dz * push * wq
                    }
                }
            }
        }
    }

    // best-fit rigid frame (rest → world) of one piece: centroids and a rotation matrix (row-major)
    func pieceFrame(_ c: Int) -> PieceFrame {
        var M = 0.0
        var cw = SIMD3<Double>(0, 0, 0), cr = SIMD3<Double>(0, 0, 0)
        for i in 0..<n where Int(comp[i]) == c {
            let m = Double(mass[i]); M += m
            cw += SIMD3(Double(x[3 * i]), Double(x[3 * i + 1]), Double(x[3 * i + 2])) * m
            cr += SIMD3(Double(rest[3 * i]), Double(rest[3 * i + 1]), Double(rest[3 * i + 2])) * m
        }
        cw /= M; cr /= M
        var A = [Double](repeating: 0, count: 9)
        for i in 0..<n where Int(comp[i]) == c {
            let m = Double(mass[i])
            for r in 0..<3 {
                for k in 0..<3 {
                    A[3 * r + k] += m * (Double(x[3 * i + r]) - cw[r]) * (Double(rest[3 * i + k]) - cr[k])
                }
            }
        }
        // Müller et al. rotation extraction, iterated from identity
        var qx = 0.0, qy = 0.0, qz = 0.0, qw = 1.0
        var R = [Double](repeating: 0, count: 9)
        for _ in 0..<40 {
            R[0] = 1 - 2 * (qy * qy + qz * qz); R[1] = 2 * (qx * qy - qw * qz); R[2] = 2 * (qx * qz + qw * qy)
            R[3] = 2 * (qx * qy + qw * qz); R[4] = 1 - 2 * (qx * qx + qz * qz); R[5] = 2 * (qy * qz - qw * qx)
            R[6] = 2 * (qx * qz - qw * qy); R[7] = 2 * (qy * qz + qw * qx); R[8] = 1 - 2 * (qx * qx + qy * qy)
            var ox = 0.0, oy = 0.0, oz = 0.0, den = 0.0
            for col in 0..<3 {
                let rx = R[col], ry = R[3 + col], rz = R[6 + col], ax = A[col], ay = A[3 + col], az = A[6 + col]
                ox += ry * az - rz * ay; oy += rz * ax - rx * az; oz += rx * ay - ry * ax; den += rx * ax + ry * ay + rz * az
            }
            let s = 1 / (abs(den) + 1e-12)
            let wx = ox * s, wy = oy * s, wz = oz * s, w = (wx * wx + wy * wy + wz * wz).squareRoot()
            if w < 1e-9 { break }
            let h = min(w, 2) / 2, sn = sin(h) / w, cs = cos(h)
            let ax = wx * sn, ay = wy * sn, az = wz * sn
            let nx = cs * qx + ax * qw + ay * qz - az * qy, ny = cs * qy - ax * qz + ay * qw + az * qx
            let nz = cs * qz + ax * qy - ay * qx + az * qw, nw = cs * qw - ax * qx - ay * qy - az * qz
            let l = (nx * nx + ny * ny + nz * nz + nw * nw).squareRoot()
            qx = nx / l; qy = ny / l; qz = nz / l; qw = nw / l
        }
        R[0] = 1 - 2 * (qy * qy + qz * qz); R[1] = 2 * (qx * qy - qw * qz); R[2] = 2 * (qx * qz + qw * qy)
        R[3] = 2 * (qx * qy + qw * qz); R[4] = 1 - 2 * (qx * qx + qz * qz); R[5] = 2 * (qy * qz - qw * qx)
        R[6] = 2 * (qx * qz - qw * qy); R[7] = 2 * (qy * qz + qw * qx); R[8] = 1 - 2 * (qx * qx + qy * qy)
        return PieceFrame(cw: cw, cr: cr, R: R)
    }

    private func solveFloor() {
        let fy = floorY, mu = friction
        for i in 0..<n {
            let k = 3 * i
            let pen = fy - x[k + 1]
            if pen <= 0 { continue }
            x[k + 1] = fy
            // Coulomb-style positional friction
            let dx = x[k] - prev[k], dz = x[k + 2] - prev[k + 2]
            let dl = (dx * dx + dz * dz).squareRoot()
            if dl < 1e-12 { continue }
            // static friction for micro-slip, kinetic friction otherwise (never locks in large strain)
            let f: Float = dl < mu * pen ? 1 : mu * pen / dl
            x[k] -= dx * f; x[k + 2] -= dz * f
        }
    }

    private func dampEdges(_ dt: Float) {
        let k = 1 - expf(-dampRate() * dt)
        for e in 0..<nE {
            let i = edgesP[2 * e], j = edgesP[2 * e + 1]
            let I = 3 * i, J = 3 * j
            var nx = x[J] - x[I], ny = x[J + 1] - x[I + 1], nz = x[J + 2] - x[I + 2]
            let l = (nx * nx + ny * ny + nz * nz).squareRoot()
            if l < 1e-9 { continue }
            nx /= l; ny /= l; nz /= l
            let rv = (v[J] - v[I]) * nx + (v[J + 1] - v[I + 1]) * ny + (v[J + 2] - v[I + 2]) * nz
            let wi = invMass[i], wj = invMass[j], ws = wi + wj
            let imp = rv * k / ws
            v[I] += nx * imp * wi; v[I + 1] += ny * imp * wi; v[I + 2] += nz * imp * wi
            v[J] -= nx * imp * wj; v[J + 1] -= ny * imp * wj; v[J + 2] -= nz * imp * wj
        }
    }

    // ── diagnostics ──
    func volumeRatio() -> Double {
        var s = 0.0
        for t in 0..<nT { s += Double(tetVol(x, t)) }
        return s / totalRestVolume
    }

    func kineticEnergy() -> Double {
        var e = 0.0
        for i in 0..<n {
            let k = 3 * i
            e += 0.5 * Double(mass[i]) * Double(v[k] * v[k] + v[k + 1] * v[k + 1] + v[k + 2] * v[k + 2])
        }
        return e
    }
}
