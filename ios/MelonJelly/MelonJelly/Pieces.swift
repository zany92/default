// ─────────────────────────────────────────────────────────────
//  Pieces: the slice and everything cut from it.
//  Every piece is a convex "inner polygon" I in the slice's rest plane (u, w);
//  its real outline is I grown by a fixed corner radius RC (so every corner is
//  rounded, including fresh knife cuts). All pieces share one rest frame, so
//  the rind / pith / flesh shading and seeds stay exactly where they were.
// ─────────────────────────────────────────────────────────────

import Foundation
import simd

let RC = Shape.rho          // corner radius of every piece outline
let MIN_INNER_AREA = 0.004

struct PieceSim {
    var rest: [Float]
    var tets: [UInt32]
    var region: [UInt8]
}

struct PieceRender {
    var rest: [Float]
    var mat: [Float]
    var body: [UInt32]
    var seeds: [UInt32]
    var bubbles: [UInt32]
}

struct PieceCache {
    var sim: PieceSim
    var ren: PieceRender
    var emb: Embedding
}

final class Piece {
    let I: [V2]
    var cache: PieceCache?
    init(_ I: [V2]) { self.I = I }
}

func initialPiece() -> Piece {
    let a = Shape.alpha, Ri = Shape.Ri
    var I: [V2] = [V2(0, 0)]
    let a0 = Double.pi / 2 - a, a1 = Double.pi / 2 + a, n = 40
    for k in 0...n {
        let t = a0 + (a1 - a0) * Double(k) / Double(n)
        I.append(V2(cos(t) * Ri, sin(t) * Ri))
    }
    return Piece(I)
}

func polyArea(_ P: [V2]) -> Double {
    var s = 0.0
    for i in 0..<P.count { let p = P[i], q = P[(i + 1) % P.count]; s += p.x * q.y - q.x * p.y }
    return s / 2
}

// Sutherland–Hodgman against the half-plane a·u + b·w ≤ c
func clipHalf(_ P: [V2], _ a: Double, _ b: Double, _ c: Double) -> [V2] {
    var out: [V2] = []
    for i in 0..<P.count {
        let p = P[i], q = P[(i + 1) % P.count]
        let dp = a * p.x + b * p.y - c, dq = a * q.x + b * q.y - c
        if dp <= 0 { out.append(p) }
        if (dp < 0 && dq > 0) || (dp > 0 && dq < 0) {
            let t = dp / (dp - dq)
            out.append(p + (q - p) * t)
        }
    }
    var clean: [V2] = []
    for p in out {
        if let l = clean.last, simd_length(l - p) <= 1e-5 { continue }
        clean.append(p)
    }
    if clean.count > 1, simd_length(clean[0] - clean[clean.count - 1]) < 1e-5 { clean.removeLast() }
    return clean
}

// split a piece along the rest-plane line a·u + b·w = c (a, b normalised); nil if a part would be too thin
func splitPiece(_ I: [V2], _ a: Double, _ b: Double, _ c: Double) -> ([V2], [V2])? {
    let A = clipHalf(I, a, b, c - RC)
    let B = clipHalf(I, -a, -b, -(c + RC))
    if A.count < 3 || B.count < 3 || polyArea(A) < MIN_INNER_AREA || polyArea(B) < MIN_INNER_AREA { return nil }
    return (A, B)
}

// does the line pass through the piece's real outline?
func lineCrossesPiece(_ I: [V2], _ a: Double, _ b: Double, _ c: Double) -> Bool {
    var lo = Double.infinity, hi = -Double.infinity
    for p in I { let d = a * p.x + b * p.y; lo = min(lo, d); hi = max(hi, d) }
    return c > lo - RC * 0.6 && c < hi + RC * 0.6
}

// signed distance to the inner polygon (negative inside)
func sdInner(_ I: [V2], _ u: Double, _ w: Double) -> Double {
    var d = -Double.infinity
    for i in 0..<I.count {
        let p = I[i], q = I[(i + 1) % I.count]
        let ex = q.x - p.x, ew = q.y - p.y
        var l = (ex * ex + ew * ew).squareRoot(); if l == 0 { l = 1 }
        let nx = ew / l, nw = -ex / l
        d = max(d, nx * (u - p.x) + nw * (w - p.y))
    }
    return d
}
func sdPiece(_ I: [V2], _ u: Double, _ w: Double, _ inset: Double = 0) -> Double { sdInner(I, u, w) - RC + inset }

struct OutlineSample { var q: V2; var n: V2 }

// outline samples: base point q on I and outward normal n; the outline at offset d is q + n·d
func pieceSamples(_ I: [V2], _ spacing: Double, _ maxAngleStep: Double) -> [OutlineSample] {
    var out: [OutlineSample] = []
    let N = I.count
    var edgeN: [(Double, Double, Double)] = []
    for i in 0..<N {
        let p = I[i], q = I[(i + 1) % N]
        let ex = q.x - p.x, ew = q.y - p.y
        var l = (ex * ex + ew * ew).squareRoot(); if l == 0 { l = 1 }
        edgeN.append((ew / l, -ex / l, l))
    }
    for i in 0..<N {
        let n0 = edgeN[(i - 1 + N) % N], n1 = edgeN[i]
        let a0 = atan2(n0.1, n0.0), a1 = atan2(n1.1, n1.0)
        var da = a1 - a0
        while da < 0 { da += Double.pi * 2 }
        if da > Double.pi * 1.5 { da = 0 }
        let na = max(1, Int(ceil(max(RC * da / spacing, da / maxAngleStep))))
        for k in 0..<na {
            let t = a0 + da * Double(k) / Double(na)
            out.append(OutlineSample(q: I[i], n: V2(cos(t), sin(t))))
        }
        let nl = max(1, Int(ceil(n1.2 / spacing)))
        if nl > 1 {
            for k in 1..<nl {
                let t = Double(k) / Double(nl), p = I[i], q = I[(i + 1) % N]
                out.append(OutlineSample(q: p + (q - p) * t, n: V2(n1.0, n1.1)))
            }
        }
    }
    return out
}

func bboxLattice(_ I: [V2], _ pad: Double, _ spacing: Double, _ keep: (Double, Double) -> Bool) -> [Double] {
    var u0 = Double.infinity, u1 = -Double.infinity, w0 = Double.infinity, w1 = -Double.infinity
    for p in I { u0 = min(u0, p.x); u1 = max(u1, p.x); w0 = min(w0, p.y); w1 = max(w1, p.y) }
    u0 -= pad; u1 += pad; w0 -= pad; w1 += pad
    var pts: [Double] = []
    let dy = spacing * 3.0.squareRoot() / 2
    var row = 0
    var w = w0
    while w <= w1 {
        var u = u0 + Double(row % 2) * spacing / 2
        while u <= u1 {
            if keep(u, w) { pts.append(u); pts.append(w) }
            u += spacing
        }
        w += dy; row += 1
    }
    return pts
}

private func regionOf(_ x: Float, _ z: Float) -> UInt8 {
    let depth = Shape.Ro - (Double(x) * Double(x) + Double(z) * Double(z)).squareRoot()
    return depth < Shape.skin + 0.03 ? 2 : depth < Shape.pale ? 1 : 0
}

// ── per-piece simulation mesh: Delaunay of the outline, extruded into prisms → tets ──
func buildPieceSim(_ I: [V2], h: Double = 0.15, layers: Int = 3) -> PieceSim {
    let T = Shape.T
    let bs = pieceSamples(I, h, 0.5)
    var P2: [Double] = []
    for s in bs {
        let x = s.q.x + s.n.x * RC, z = s.q.y + s.n.y * RC
        var dup = false
        var j = 0
        while j < P2.count {
            let dx = P2[j] - x, dz = P2[j + 1] - z
            if (dx * dx + dz * dz).squareRoot() < h * 0.45 { dup = true; break }
            j += 2
        }
        if !dup { P2.append(x); P2.append(z) }
    }
    let all = P2 + bboxLattice(I, RC, h) { u, w in sdPiece(I, u, w) < -h * 0.55 }
    let tri2 = delaunay(all)
    var t2: [Int] = []
    var i = 0
    while i < tri2.count {
        let a = tri2[i], b = tri2[i + 1], c = tri2[i + 2]
        let ax = all[2 * a], ay = all[2 * a + 1], bx = all[2 * b], by = all[2 * b + 1], cx = all[2 * c], cy = all[2 * c + 1]
        let area = abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) / 2
        let l2 = max((bx - ax) * (bx - ax) + (by - ay) * (by - ay), max((cx - bx) * (cx - bx) + (cy - by) * (cy - by), (ax - cx) * (ax - cx) + (ay - cy) * (ay - cy)))
        if area / l2 > 0.1 { t2.append(contentsOf: [a, b, c]) }
        i += 3
    }
    var used = [Int](repeating: -1, count: all.count / 2)
    var v2: [Double] = []
    for v in t2 where used[v] < 0 { used[v] = v2.count / 2; v2.append(all[2 * v]); v2.append(all[2 * v + 1]) }
    let tris = t2.map { used[$0] }
    let n2 = v2.count / 2, nL = layers + 1
    var rest = [Float](repeating: 0, count: n2 * nL * 3)
    for l in 0..<nL {
        for i in 0..<n2 {
            let k = (l * n2 + i) * 3
            rest[k] = Float(v2[2 * i]); rest[k + 1] = Float(T * Double(l) / Double(layers)); rest[k + 2] = Float(v2[2 * i + 1])
        }
    }
    var tets: [Int] = []
    for l in 0..<layers {
        var i = 0
        while i < tris.count {
            let s = [tris[i], tris[i + 1], tris[i + 2]].sorted()
            let a = l * n2 + s[0], b = l * n2 + s[1], c = l * n2 + s[2]
            tets.append(contentsOf: [a, b, c, a + n2, b, c, a + n2, b + n2, c, a + n2, b + n2, c + n2])
            i += 3
        }
    }
    var t = 0
    while t < tets.count {
        if tetVolume(rest, tets[t], tets[t + 1], tets[t + 2], tets[t + 3]) < 0 { tets.swapAt(t + 2, t + 3) }
        t += 4
    }
    let nP = n2 * nL
    var region = [UInt8](repeating: 0, count: nP)
    for i in 0..<nP { region[i] = regionOf(rest[3 * i], rest[3 * i + 2]) }
    return PieceSim(rest: rest, tets: tets.map { UInt32($0) }, region: region)
}

// ── seeds and bubbles, generated once in the shared rest frame ──
struct Prop {
    var mat: Float
    var cx: Double, cz: Double, rad: Double
    var pos: [Float], nrm: [Float], idx: [UInt32]
}

let globalProps: [Prop] = {
    let T = Shape.T
    var R = Mulberry32(9)
    var list: [Prop] = []
    struct Seed { var r, th: Double; var face: Int; var s: Double }
    var seeds: [Seed] = []
    let rows: [(r: Double, n: Int)] = [(0.46, 2), (0.68, 3), (0.9, 4), (1.12, 5), (1.33, 5)]
    for face in [1, -1] {
        for row in rows {
            let maxTh = Shape.alpha - (0.12 + 0.07) / row.r - 0.02
            for i in 0..<row.n {
                let t = row.n == 1 ? 0 : (Double(i) / Double(row.n - 1)) * 2 - 1
                let r = row.r + (R.next() - 0.5) * 0.08
                let th = t * maxTh * 0.88 + (R.next() - 0.5) * 0.06 + (face < 0 ? 0.05 : 0)
                let s = 0.85 + R.next() * 0.3
                seeds.append(Seed(r: r, th: th, face: face, s: s))
            }
        }
    }
    seeds.append(Seed(r: 0.9, th: 0.12, face: 0, s: 0.9))
    seeds.append(Seed(r: 1.12, th: -0.2, face: 0, s: 0.8))
    let nt = 10, nph = 12
    for sd in seeds {
        let L = 0.15 * sd.s, W = 0.088 * sd.s, H = 0.042 * sd.s
        let cx = sin(sd.th) * sd.r, cz = cos(sd.th) * sd.r
        let ax = (sin(sd.th), 0.0, cos(sd.th)), lx = (cos(sd.th), 0.0, -sin(sd.th))
        let tilt = (R.next() - 0.5) * 0.25
        let cy = sd.face > 0 ? T - H * 0.64 : sd.face < 0 ? H * 0.64 : T * (0.35 + R.next() * 0.25)
        var pos: [Float] = [], nrm: [Float] = [], idx: [UInt32] = []
        for i in 0...nt {
            let t = Double.pi * Double(i) / Double(nt), s = (1 - cos(t)) / 2
            let prof = pow(max(sin(t), 0), 0.9) * (0.38 + 0.62 * pow(s, 0.7))
            for j in 0..<nph {
                let ph = 2 * Double.pi * Double(j) / Double(nph)
                let la = cos(ph) * prof * W / 2, up = sin(ph) * prof * H / 2, al = (s - 0.5) * L, upT = up + al * tilt * 0.3
                pos += [Float(cx + ax.0 * al + lx.0 * la), Float(cy + upT), Float(cz + ax.2 * al + lx.2 * la)]
                nrm += [Float(ax.0 * al / L + lx.0 * la / W), Float(upT / H), Float(ax.2 * al / L + lx.2 * la / W)]
            }
        }
        for i in 0..<nt {
            for j in 0..<nph {
                let a = i * nph + j, bb = i * nph + (j + 1) % nph, c = a + nph, d = bb + nph
                idx += [a, bb, c, bb, d, c].map { UInt32($0) }
            }
        }
        list.append(Prop(mat: 1, cx: cx, cz: cz, rad: L * 0.5, pos: pos, nrm: nrm, idx: idx))
    }
    var bub: [(Double, Double, Double, Double)] = []
    for _ in 0..<9 {
        let r = 0.45 + R.next() * 0.85
        let th = (R.next() * 2 - 1) * (Shape.alpha - 0.14 / r) * 0.9
        let ra = R.next(), rb = R.next()
        let rad = 0.009 + ra * rb * 0.02
        let y = R.next() < 0.6 ? T - 0.035 - R.next() * 0.16 : 0.05 + R.next() * 0.14
        bub.append((sin(th) * r, y, cos(th) * r, rad))
    }
    bub.append((0.22, T - 0.06, 0.45, 0.012))
    bub.append((-0.2, T - 0.09, 1.05, 0.016))
    let bs = 8, bp = 12
    for (x, y, z, r) in bub {
        var pos: [Float] = [], nrm: [Float] = [], idx: [UInt32] = []
        for i in 0...bs {
            let t = Double.pi * Double(i) / Double(bs)
            for j in 0..<bp {
                let ph = 2 * Double.pi * Double(j) / Double(bp)
                let nx = sin(t) * cos(ph), ny = cos(t), nz = sin(t) * sin(ph)
                pos += [Float(x + nx * r), Float(y + ny * r), Float(z + nz * r)]
                nrm += [Float(nx), Float(ny), Float(nz)]
            }
        }
        for i in 0..<bs {
            for j in 0..<bp {
                let a = i * bp + j, bb = i * bp + (j + 1) % bp, c = a + bp, d = bb + bp
                idx += [a, bb, c, bb, d, c].map { UInt32($0) }
            }
        }
        list.append(Prop(mat: 2, cx: x, cz: z, rad: r, pos: pos, nrm: nrm, idx: idx))
    }
    return list
}()

// ── per-piece render mesh: rounded walls, two caps, and the seeds/bubbles that lie inside it ──
func buildPieceRender(_ I: [V2]) -> PieceRender {
    let T = Shape.T, b = Shape.bevel
    var pos: [Float] = [], nrm: [Float] = [], mat: [Float] = []
    var body: [UInt32] = [], seeds: [UInt32] = [], bubbles: [UInt32] = []
    @discardableResult
    func add(_ x: Double, _ y: Double, _ z: Double, _ m: Float, _ nx: Double, _ ny: Double, _ nz: Double) -> UInt32 {
        pos += [Float(x), Float(y), Float(z)]; nrm += [Float(nx), Float(ny), Float(nz)]; mat.append(m)
        return UInt32(pos.count / 3 - 1)
    }
    let samples = pieceSamples(I, 0.03, 0.1)
    let N = samples.count
    let qb = 8, qs = 3
    struct Ring { var d, y, ny, nr: Double }
    var rings: [Ring] = []
    for j in 0...qb {
        let ps = -Double.pi / 2 + (Double.pi / 2) * Double(j) / Double(qb)
        rings.append(Ring(d: RC - b + b * cos(ps), y: b + b * sin(ps), ny: sin(ps), nr: cos(ps)))
    }
    for j in 1..<qs { rings.append(Ring(d: RC, y: b + (T - 2 * b) * Double(j) / Double(qs), ny: 0, nr: 1)) }
    for j in 0...qb {
        let ps = (Double.pi / 2) * Double(j) / Double(qb)
        rings.append(Ring(d: RC - b + b * cos(ps), y: T - b + b * sin(ps), ny: sin(ps), nr: cos(ps)))
    }
    var ringStart: [Int] = []
    for r in rings {
        ringStart.append(pos.count / 3)
        for s in samples {
            add(s.q.x + s.n.x * r.d, r.y, s.q.y + s.n.y * r.d, 0, s.n.x * r.nr, r.ny, s.n.y * r.nr)
        }
    }
    for j in 0..<(rings.count - 1) {
        for k in 0..<N {
            let a = ringStart[j] + k, bb = ringStart[j] + (k + 1) % N, c = ringStart[j + 1] + k, d = ringStart[j + 1] + (k + 1) % N
            body += [a, c, bb, bb, c, d].map { UInt32($0) }
        }
    }
    let inset = RC - b
    var capPts: [Double] = []
    for s in samples { capPts.append(s.q.x + s.n.x * inset); capPts.append(s.q.y + s.n.y * inset) }
    let sp = 0.048
    let cp = capPts + bboxLattice(I, RC, sp) { u, w in sdPiece(I, u, w, b) < -sp * 0.6 }
    let ctri = delaunay(cp)
    let topRing = ringStart[rings.count - 1], botRing = ringStart[0]
    var topMap: [UInt32] = [], botMap: [UInt32] = []
    for i in 0..<(cp.count / 2) {
        if i < N {
            topMap.append(UInt32(topRing + i)); botMap.append(UInt32(botRing + i))
        } else {
            topMap.append(add(cp[2 * i], T, cp[2 * i + 1], 0, 0, 1, 0))
            botMap.append(add(cp[2 * i], 0, cp[2 * i + 1], 0, 0, -1, 0))
        }
    }
    var i = 0
    while i < ctri.count {
        let a = ctri[i], c1 = ctri[i + 1], c2 = ctri[i + 2]
        body += [topMap[a], topMap[c2], topMap[c1]]
        body += [botMap[a], botMap[c1], botMap[c2]]
        i += 3
    }
    // seeds and bubbles that sit wholly inside this piece
    for pr in globalProps {
        if sdPiece(I, pr.cx, pr.cz) + pr.rad > -0.02 { continue }
        let base = UInt32(pos.count / 3)
        var k = 0
        while k < pr.pos.count {
            pos += [pr.pos[k], pr.pos[k + 1], pr.pos[k + 2]]
            nrm += [pr.nrm[k], pr.nrm[k + 1], pr.nrm[k + 2]]
            mat.append(pr.mat)
            k += 3
        }
        if pr.mat == 1 { seeds += pr.idx.map { $0 + base } } else { bubbles += pr.idx.map { $0 + base } }
    }
    // windings agree with analytic outward normals (CCW = front)
    func fix(_ idx: inout [UInt32]) {
        var i = 0
        while i < idx.count {
            let a = Int(idx[i]), b1 = Int(idx[i + 1]), c = Int(idx[i + 2])
            let e1x = pos[3 * b1] - pos[3 * a], e1y = pos[3 * b1 + 1] - pos[3 * a + 1], e1z = pos[3 * b1 + 2] - pos[3 * a + 2]
            let e2x = pos[3 * c] - pos[3 * a], e2y = pos[3 * c + 1] - pos[3 * a + 1], e2z = pos[3 * c + 2] - pos[3 * a + 2]
            let fx = e1y * e2z - e1z * e2y, fy = e1z * e2x - e1x * e2z, fz = e1x * e2y - e1y * e2x
            var d: Float = 0
            for v in [a, b1, c] { d += fx * nrm[3 * v] + fy * nrm[3 * v + 1] + fz * nrm[3 * v + 2] }
            if d < 0 { idx.swapAt(i + 1, i + 2) }
            i += 3
        }
    }
    fix(&body); fix(&seeds); fix(&bubbles)
    return PieceRender(rest: pos, mat: mat, body: body, seeds: seeds, bubbles: bubbles)
}

@discardableResult
func ensureCache(_ piece: Piece) -> PieceCache {
    if let c = piece.cache { return c }
    let sim = buildPieceSim(piece.I)
    let ren = buildPieceRender(piece.I)
    let emb = embed(simRest: sim.rest, tets: sim.tets, verts: ren.rest)
    let c = PieceCache(sim: sim, ren: ren, emb: emb)
    piece.cache = c
    return c
}

// ── the world: every piece concatenated into one simulation and one render mesh ──
struct SimMesh {
    var rest: [Float]
    var tets: [UInt32]
    var region: [UInt8]
    var comp: [UInt16]
    var nComp: Int
}

struct DrawRange { var first: Int; var count: Int }

struct RenderMesh {
    var rest: [Float]
    var mat: [Float]
    var index: [UInt32]
    var vComp: [UInt16]
    var body: DrawRange
    var seeds: DrawRange
    var bubbles: DrawRange
}

struct World {
    var sim: SimMesh
    var render: RenderMesh
    var skinIdx: [UInt32]
    var skinW: [Float]
}

func buildWorld(_ pieces: [Piece]) -> World {
    var nP = 0, nT = 0, nV = 0, nB = 0, nS = 0, nU = 0
    for p in pieces {
        let c = ensureCache(p)
        nP += c.sim.rest.count / 3; nT += c.sim.tets.count / 4; nV += c.ren.rest.count / 3
        nB += c.ren.body.count; nS += c.ren.seeds.count; nU += c.ren.bubbles.count
    }
    var rest = [Float](), tets = [UInt32](), region = [UInt8](), comp = [UInt16]()
    rest.reserveCapacity(nP * 3); tets.reserveCapacity(nT * 4); region.reserveCapacity(nP); comp.reserveCapacity(nP)
    var rRest = [Float](), rMat = [Float](), vComp = [UInt16]()
    rRest.reserveCapacity(nV * 3); rMat.reserveCapacity(nV); vComp.reserveCapacity(nV)
    var bodyI = [UInt32](), seedI = [UInt32](), bubI = [UInt32]()
    var skinIdx = [UInt32](), skinW = [Float]()
    skinIdx.reserveCapacity(nV * 4); skinW.reserveCapacity(nV * 4)
    var po = 0, vo = 0
    for (k, p) in pieces.enumerated() {
        let c = p.cache!
        let np = c.sim.rest.count / 3, nv = c.ren.rest.count / 3
        rest += c.sim.rest; region += c.sim.region; comp += [UInt16](repeating: UInt16(k), count: np)
        tets += c.sim.tets.map { $0 + UInt32(po) }
        rRest += c.ren.rest; rMat += c.ren.mat; vComp += [UInt16](repeating: UInt16(k), count: nv)
        for v in 0..<nv {
            let t = c.emb.tetOf[v]
            for j in 0..<4 {
                skinIdx.append(c.sim.tets[4 * t + j] + UInt32(po))
                skinW.append(c.emb.w[4 * v + j])
            }
        }
        bodyI += c.ren.body.map { $0 + UInt32(vo) }
        seedI += c.ren.seeds.map { $0 + UInt32(vo) }
        bubI += c.ren.bubbles.map { $0 + UInt32(vo) }
        po += np; vo += nv
    }
    return World(
        sim: SimMesh(rest: rest, tets: tets, region: region, comp: comp, nComp: pieces.count),
        render: RenderMesh(rest: rRest, mat: rMat, index: bodyI + seedI + bubI, vComp: vComp,
                           body: DrawRange(first: 0, count: nB),
                           seeds: DrawRange(first: nB, count: nS),
                           bubbles: DrawRange(first: nB + nS, count: nU)),
        skinIdx: skinIdx, skinW: skinW)
}
