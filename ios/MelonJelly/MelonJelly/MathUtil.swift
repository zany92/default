// tiny mat4 helpers (column-major, Metal clip z ∈ [0,1])

import simd

enum M4 {
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovy / 2)
        var m = simd_float4x4()
        m.columns.0 = SIMD4(f / aspect, 0, 0, 0)
        m.columns.1 = SIMD4(0, f, 0, 0)
        m.columns.2 = SIMD4(0, 0, far / (near - far), -1)
        m.columns.3 = SIMD4(0, 0, near * far / (near - far), 0)
        return m
    }

    static func ortho(_ l: Float, _ r: Float, _ b: Float, _ t: Float, _ n: Float, _ f: Float) -> simd_float4x4 {
        var m = simd_float4x4()
        m.columns.0 = SIMD4(2 / (r - l), 0, 0, 0)
        m.columns.1 = SIMD4(0, 2 / (t - b), 0, 0)
        m.columns.2 = SIMD4(0, 0, 1 / (n - f), 0)
        m.columns.3 = SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), n / (n - f), 1)
        return m
    }

    static func lookAt(eye: SIMD3<Float>, at: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - at)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        var m = simd_float4x4()
        m.columns.0 = SIMD4(x.x, y.x, z.x, 0)
        m.columns.1 = SIMD4(x.y, y.y, z.y, 0)
        m.columns.2 = SIMD4(x.z, y.z, z.z, 0)
        m.columns.3 = SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        return m
    }
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ s: Float) -> Float { a + (b - a) * s }
@inline(__always) func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ s: Float) -> SIMD3<Float> { a + (b - a) * s }
@inline(__always) func ease(_ s: Float) -> Float { let s = min(1, max(0, s)); return s * s * (3 - 2 * s) }
@inline(__always) func wrapA(_ a: Float) -> Float { atan2(sin(a), cos(a)) }
