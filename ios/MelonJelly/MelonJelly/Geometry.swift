// ─────────────────────────────────────────────────────────────
//  Geometry: the rounded watermelon wedge, Delaunay triangulation,
//  lattices, and the barycentric embedding that ties every render
//  vertex to a simulation tetrahedron.
// ─────────────────────────────────────────────────────────────

import Foundation
import simd

typealias V2 = SIMD2<Double>

enum Shape {
    static let alpha = 32.0 * Double.pi / 180 // half angle of the wedge
    static let Ri = 1.62                      // inner sector radius (before rounding)
    static let rho = 0.17                     // in-plane corner rounding
    static let T = 0.58                       // thickness
    static let bevel = 0.13                   // rounding of the top / bottom edges
    static let skin = 0.075                   // green skin band depth
    static let pale = 0.25                    // skin + pale layer depth
    static let Ro = Ri + rho
}

// seeded PRNG (mulberry32) so the specimen is identical on each launch
struct Mulberry32 {
    private var s: UInt32
    init(_ seed: UInt32) { s = seed }
    mutating func next() -> Double {
        s = s &+ 0x6D2B79F5
        var t = s
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

// ── Bowyer–Watson Delaunay (convex point sets, a few thousand points) ──
// pts: flat [x0, y0, x1, y1, …]; returns CCW triangles as flat indices
func delaunay(_ pts: [Double]) -> [Int] {
    let n = pts.count / 2
    if n < 3 { return [] }
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for i in 0..<n {
        minX = min(minX, pts[2 * i]); maxX = max(maxX, pts[2 * i])
        minY = min(minY, pts[2 * i + 1]); maxY = max(maxY, pts[2 * i + 1])
    }
    let d = max(maxX - minX, maxY - minY) * 20
    let mx = (minX + maxX) / 2, my = (minY + maxY) / 2
    var P = pts
    P.append(contentsOf: [mx - d, my - d, mx + d, my - d, mx, my + d])

    struct Tri { var a, b, c: Int; var x, y, r2: Double }
    func mk(_ a: Int, _ b: Int, _ c: Int) -> Tri {
        let ax = P[2 * a], ay = P[2 * a + 1], bx = P[2 * b], by = P[2 * b + 1], cx = P[2 * c], cy = P[2 * c + 1]
        let D = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        let a2 = ax * ax + ay * ay, b2 = bx * bx + by * by, c2 = cx * cx + cy * cy
        let ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / D
        let uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / D
        return Tri(a: a, b: b, c: c, x: ux, y: uy, r2: (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy))
    }
    var tris = [mk(n, n + 1, n + 2)]
    var edgeCount: [Int: Int] = [:]
    var edgeOrder: [(Int, Int)] = []
    for i in 0..<n {
        let px = P[2 * i], py = P[2 * i + 1]
        var keep: [Tri] = []
        keep.reserveCapacity(tris.count + 4)
        edgeCount.removeAll(keepingCapacity: true)
        edgeOrder.removeAll(keepingCapacity: true)
        for t in tris {
            let dx = px - t.x, dy = py - t.y
            if dx * dx + dy * dy < t.r2 * (1 + 1e-9) {
                for (e0, e1) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let k = e0 < e1 ? e0 * 100003 + e1 : e1 * 100003 + e0
                    if let c = edgeCount[k] { edgeCount[k] = c + 1 } else { edgeCount[k] = 1; edgeOrder.append((e0, e1)) }
                }
            } else {
                keep.append(t)
            }
        }
        tris = keep
        for (e0, e1) in edgeOrder {
            let k = e0 < e1 ? e0 * 100003 + e1 : e1 * 100003 + e0
            if edgeCount[k] == 1 { tris.append(mk(e0, e1, i)) }
        }
    }
    var res: [Int] = []
    res.reserveCapacity(tris.count * 3)
    for t in tris {
        if t.a >= n || t.b >= n || t.c >= n { continue }
        let ax = P[2 * t.a], ay = P[2 * t.a + 1]
        let cr = (P[2 * t.b] - ax) * (P[2 * t.c + 1] - ay) - (P[2 * t.b + 1] - ay) * (P[2 * t.c] - ax)
        if cr > 0 { res.append(contentsOf: [t.a, t.b, t.c]) } else { res.append(contentsOf: [t.a, t.c, t.b]) }
    }
    return res
}

func tetVolume(_ p: [Float], _ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
    let ax = Double(p[3 * a]), ay = Double(p[3 * a + 1]), az = Double(p[3 * a + 2])
    let b0 = Double(p[3 * b]) - ax, b1 = Double(p[3 * b + 1]) - ay, b2 = Double(p[3 * b + 2]) - az
    let c0 = Double(p[3 * c]) - ax, c1 = Double(p[3 * c + 1]) - ay, c2 = Double(p[3 * c + 2]) - az
    let d0 = Double(p[3 * d]) - ax, d1 = Double(p[3 * d + 1]) - ay, d2 = Double(p[3 * d + 2]) - az
    return (b0 * (c1 * d2 - c2 * d1) - b1 * (c0 * d2 - c2 * d0) + b2 * (c0 * d1 - c1 * d0)) / 6
}

// ── Barycentric embedding of points into tets ──
struct Embedding {
    var tetOf: [Int]
    var w: [Float]   // 4 weights per point
}

func embed(simRest: [Float], tets: [UInt32], verts: [Float]) -> Embedding {
    let nT = tets.count / 4, nV = verts.count / 3
    let cell = 0.2
    var grid: [Int: [Int]] = [:]
    func key(_ i: Int, _ j: Int, _ k: Int) -> Int { (i + 512) * 1048576 + (j + 512) * 1024 + (k + 512) }
    var inv = [Double](repeating: 0, count: nT * 9)
    for t in 0..<nT {
        var mn = [Double.infinity, Double.infinity, Double.infinity]
        var mx = [-Double.infinity, -Double.infinity, -Double.infinity]
        let id = [Int(tets[4 * t]), Int(tets[4 * t + 1]), Int(tets[4 * t + 2]), Int(tets[4 * t + 3])]
        for v in id { for c in 0..<3 { let q = Double(simRest[3 * v + c]); mn[c] = min(mn[c], q); mx[c] = max(mx[c], q) } }
        for i in Int(floor(mn[0] / cell))...Int(floor(mx[0] / cell)) {
            for j in Int(floor(mn[1] / cell))...Int(floor(mx[1] / cell)) {
                for k in Int(floor(mn[2] / cell))...Int(floor(mx[2] / cell)) {
                    grid[key(i, j, k), default: []].append(t)
                }
            }
        }
        let a = id[0]
        var m: [Double] = []
        for c in 1..<4 { for r in 0..<3 { m.append(Double(simRest[3 * id[c] + r]) - Double(simRest[3 * a + r])) } }
        let M = [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]
        let det = M[0] * (M[4] * M[8] - M[5] * M[7]) - M[1] * (M[3] * M[8] - M[5] * M[6]) + M[2] * (M[3] * M[7] - M[4] * M[6])
        let id2 = 1 / det
        let I = 9 * t
        inv[I + 0] = (M[4] * M[8] - M[5] * M[7]) * id2; inv[I + 1] = (M[2] * M[7] - M[1] * M[8]) * id2; inv[I + 2] = (M[1] * M[5] - M[2] * M[4]) * id2
        inv[I + 3] = (M[5] * M[6] - M[3] * M[8]) * id2; inv[I + 4] = (M[0] * M[8] - M[2] * M[6]) * id2; inv[I + 5] = (M[2] * M[3] - M[0] * M[5]) * id2
        inv[I + 6] = (M[3] * M[7] - M[4] * M[6]) * id2; inv[I + 7] = (M[1] * M[6] - M[0] * M[7]) * id2; inv[I + 8] = (M[0] * M[4] - M[1] * M[3]) * id2
    }
    func bary(_ t: Int, _ x: Double, _ y: Double, _ z: Double) -> SIMD4<Double> {
        let a = Int(tets[4 * t])
        let dx = x - Double(simRest[3 * a]), dy = y - Double(simRest[3 * a + 1]), dz = z - Double(simRest[3 * a + 2])
        let I = 9 * t
        let b1 = inv[I] * dx + inv[I + 1] * dy + inv[I + 2] * dz
        let b2 = inv[I + 3] * dx + inv[I + 4] * dy + inv[I + 5] * dz
        let b3 = inv[I + 6] * dx + inv[I + 7] * dy + inv[I + 8] * dz
        return SIMD4(1 - b1 - b2 - b3, b1, b2, b3)
    }
    var tetOf = [Int](repeating: 0, count: nV)
    var w = [Float](repeating: 0, count: nV * 4)
    for v in 0..<nV {
        let x = Double(verts[3 * v]), y = Double(verts[3 * v + 1]), z = Double(verts[3 * v + 2])
        var best = -1, bestScore = -Double.infinity, bestB = SIMD4<Double>(1, 0, 0, 0)
        func tryT(_ t: Int) {
            let bb = bary(t, x, y, z)
            let s = min(min(bb.x, bb.y), min(bb.z, bb.w))
            if s > bestScore { bestScore = s; best = t; bestB = bb }
        }
        let ci = Int(floor(x / cell)), cj = Int(floor(y / cell)), ck = Int(floor(z / cell))
        var r = 0
        while r <= 2 && bestScore < -1e-4 {
            for i in (ci - r)...(ci + r) {
                for j in (cj - r)...(cj + r) {
                    for k in (ck - r)...(ck + r) {
                        if max(abs(i - ci), max(abs(j - cj), abs(k - ck))) != r { continue }
                        if let l = grid[key(i, j, k)] { for t in l { tryT(t) } }
                    }
                }
            }
            r += 1
        }
        if best < 0 { for t in 0..<nT { tryT(t) } }
        tetOf[v] = max(best, 0)
        w[4 * v] = Float(bestB.x); w[4 * v + 1] = Float(bestB.y); w[4 * v + 2] = Float(bestB.z); w[4 * v + 3] = Float(bestB.w)
    }
    return Embedding(tetOf: tetOf, w: w)
}
