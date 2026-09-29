// ─────────────────────────────────────────────────────────────
//  The knife: a small nakiri-style vegetable knife
//  local frame: +x along the blade toward the tip, +y up, edge on y = 0,
//  blade face normals ±z. The handle runs along −x.
//  materials: 3.0 ground edge bevel · 3.45 blade flat · 3.7 bolster · 5 handle
// ─────────────────────────────────────────────────────────────

import Foundation

enum KnifeSpec {
    static let Lb = 1.72        // blade length
    static let H = 0.63         // blade height at the heel
    static let xr = 0.86        // reference point on the edge that follows the cut (blade middle)
    static let handleLen = 0.84
}

struct KnifeMesh {
    var rest: [Float]
    var nrm: [Float]
    var mat: [Float]
    var index: [UInt32]
}

func knifeHandleCentre(_ p: Double) -> Double { 0.56 - 0.028 * p * p } // p ∈ [0,1] from bolster to butt

func buildKnifeMesh() -> KnifeMesh {
    let Lb = KnifeSpec.Lb, H = KnifeSpec.H
    var pos: [Double] = [], mat: [Float] = [], idx: [UInt32] = []
    @discardableResult
    func add(_ x: Double, _ y: Double, _ z: Double, _ m: Float) -> Int {
        pos += [x, y, z]; mat.append(m); return pos.count / 3 - 1
    }
    func P(_ i: Int) -> (Double, Double, Double) { (pos[3 * i], pos[3 * i + 1], pos[3 * i + 2]) }
    // add a triangle, flipping its winding if needed so it faces along `out`
    func tri(_ a: Int, _ b: Int, _ c: Int, _ out: (Double, Double, Double)) {
        let A = P(a), B = P(b), C = P(c)
        let e1 = (B.0 - A.0, B.1 - A.1, B.2 - A.2), e2 = (C.0 - A.0, C.1 - A.1, C.2 - A.2)
        let n = (e1.1 * e2.2 - e1.2 * e2.1, e1.2 * e2.0 - e1.0 * e2.2, e1.0 * e2.1 - e1.1 * e2.0)
        if n.0 * out.0 + n.1 * out.1 + n.2 * out.2 < 0 { idx += [UInt32(a), UInt32(c), UInt32(b)] } else { idx += [UInt32(a), UInt32(b), UInt32(c)] }
    }
    func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ out: (Double, Double, Double)) { tri(a, b, c, out); tri(a, c, d, out) }

    // ── blade ──
    // profile: straight edge with a small lift at the very front, flat spine that drops into a rounded nose
    func bottom(_ u: Double) -> Double { let s = max(0, (u - 0.86) / 0.14); return 0.06 * s * s }
    func top(_ u: Double) -> Double { let s = max(0, (u - 0.72) / 0.28); return H * (1 - 0.05 * u) - H * 0.34 * pow(s, 2.2) }
    // half thickness across the height: thin ground bevel, then a flat grind to the spine
    func half(_ u: Double, _ v: Double) -> Double {
        let taper = 1 - 0.45 * max(0, (u - 0.7) / 0.3)
        let t = v < 0.2 ? 0.0009 + (0.0062 - 0.0009) * (v / 0.2) : 0.0062 + 0.0095 * pow((v - 0.2) / 0.8, 0.9)
        return t * taper
    }
    let vs: [Double] = [0, 0.05, 0.11, 0.16, 0.2, 0.215, 0.3, 0.45, 0.6, 0.75, 0.88, 0.95, 1]
    let nu = 44
    let us = (0...nu).map { Double($0) / Double(nu) }
    var grid: [Int: [[Int]]] = [1: [], -1: []]
    for sg in [1, -1] {
        for i in 0...nu {
            let u = us[i]
            var row: [Int] = []
            for v in vs {
                let y = bottom(u) + (top(u) - bottom(u)) * v
                row.append(add(u * Lb, y, Double(sg) * half(u, v), v <= 0.2 ? 3.0 : 3.45))
            }
            grid[sg]!.append(row)
        }
        for i in 0..<nu {
            for j in 0..<(vs.count - 1) {
                let g = grid[sg]!
                quad(g[i][j], g[i + 1][j], g[i + 1][j + 1], g[i][j + 1], (0, 0, Double(sg)))
            }
        }
    }
    let J = vs.count - 1
    let gP = grid[1]!, gN = grid[-1]!
    // spine, edge, nose and heel strips (duplicated vertices so the creases stay sharp)
    func strip(_ count: Int, _ getA: (Int) -> (Double, Double, Double), _ getB: (Int) -> (Double, Double, Double),
               _ outFn: (Int) -> (Double, Double, Double), _ m: Float) {
        var pa = -1, pb = -1
        for i in 0...count {
            let A = getA(i), B = getB(i)
            let a = add(A.0, A.1, A.2, m), b = add(B.0, B.1, B.2, m)
            if pa >= 0 { quad(pa, a, b, pb, outFn(i)) }
            pa = a; pb = b
        }
    }
    strip(nu, { P(gP[$0][J]) }, { P(gN[$0][J]) }, { i in
        let u = us[i]
        return (-(top(min(1, u + 0.01)) - top(u)) / (0.01 * Lb), 1, 0)
    }, 3.45)
    strip(nu, { P(gP[$0][0]) }, { P(gN[$0][0]) }, { _ in (0, -1, 0) }, 3.0)
    strip(J, { P(gP[nu][$0]) }, { P(gN[nu][$0]) }, { _ in (1, 0, 0) }, 3.45)
    strip(J, { P(gP[0][$0]) }, { P(gN[0][$0]) }, { _ in (-1, 0, 0) }, 3.45)

    // ── bolster: a short polished block between blade and handle ──
    func box(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ z0: Double, _ z1: Double, _ m: Float) {
        let c: [(Double, Double, Double)] = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
        let faces: [(Int, Int, Int, Int, (Double, Double, Double))] = [
            (0, 1, 2, 3, (0, 0, -1)), (4, 5, 6, 7, (0, 0, 1)), (0, 1, 5, 4, (0, -1, 0)),
            (3, 2, 6, 7, (0, 1, 0)), (0, 3, 7, 4, (-1, 0, 0)), (1, 2, 6, 5, (1, 0, 0)),
        ]
        for (a, b, cc, d, out) in faces {
            let ia = add(c[a].0, c[a].1, c[a].2, m), ib = add(c[b].0, c[b].1, c[b].2, m)
            let ic = add(c[cc].0, c[cc].1, c[cc].2, m), id = add(c[d].0, c[d].1, c[d].2, m)
            quad(ia, ib, ic, id, out)
        }
    }
    box(-0.07, 0.004, 0.45, H * 0.985, -0.026, 0.026, 3.7)

    // ── handle: slightly swelling oval section, dropping a touch toward the butt ──
    let L = KnifeSpec.handleLen, NR = 26, NT = 22, x0 = -0.07
    func sec(_ p: Double) -> (c: Double, a: Double, b: Double) {
        (knifeHandleCentre(p), 0.08 * (1 + 0.1 * sin(Double.pi * p) + 0.05 * p), 0.054 * (1 + 0.14 * sin(Double.pi * p)))
    }
    var ring: [[Int]] = []
    for i in 0...NR {
        let p = Double(i) / Double(NR), x = x0 - p * L, s = sec(p)
        var r: [Int] = []
        for k in 0..<NT {
            let th = Double(k) / Double(NT) * Double.pi * 2
            r.append(add(x, s.c + sin(th) * s.a, cos(th) * s.b, 5))
        }
        ring.append(r)
    }
    for i in 0..<NR {
        for k in 0..<NT {
            let k2 = (k + 1) % NT
            let a = ring[i][k], b = ring[i + 1][k], c = ring[i + 1][k2], d = ring[i][k2]
            let A = P(a), cy = sec(Double(i) / Double(NR)).c
            quad(a, b, c, d, (0, A.1 - cy, A.2))
        }
    }
    // end caps (flat)
    for (p, dir) in [(0.0, 1.0), (1.0, -1.0)] {
        let i = Int((p * Double(NR)).rounded()), x = x0 - p * L, s = sec(p)
        let centre = add(x + dir * 0.004, s.c, 0, 5)
        let rim = ring[i].map { v -> Int in let q = P(v); return add(q.0, q.1, q.2, 5) }
        for k in 0..<NT { tri(centre, rim[k], rim[(k + 1) % NT], (dir, 0, 0)) }
    }

    // smooth normals per vertex (creases come from the duplicated vertices)
    let nV = pos.count / 3
    var nrm = [Double](repeating: 0, count: nV * 3)
    var t = 0
    while t < idx.count {
        let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
        let A = P(a), B = P(b), C = P(c)
        let e1 = (B.0 - A.0, B.1 - A.1, B.2 - A.2), e2 = (C.0 - A.0, C.1 - A.1, C.2 - A.2)
        let n = (e1.1 * e2.2 - e1.2 * e2.1, e1.2 * e2.0 - e1.0 * e2.2, e1.0 * e2.1 - e1.1 * e2.0)
        for v in [a, b, c] { nrm[3 * v] += n.0; nrm[3 * v + 1] += n.1; nrm[3 * v + 2] += n.2 }
        t += 3
    }
    for v in 0..<nV {
        var l = (nrm[3 * v] * nrm[3 * v] + nrm[3 * v + 1] * nrm[3 * v + 1] + nrm[3 * v + 2] * nrm[3 * v + 2]).squareRoot()
        if l == 0 { l = 1 }
        nrm[3 * v] /= l; nrm[3 * v + 1] /= l; nrm[3 * v + 2] /= l
    }
    return KnifeMesh(rest: pos.map { Float($0) }, nrm: nrm.map { Float($0) }, mat: mat, index: idx)
}
