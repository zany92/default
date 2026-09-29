// ─────────────────────────────────────────────────────────────
//  Metal renderer
//  passes: key-light shadow map · top-down height map (contact AO)
//          · scene (floor, seeds, bubbles, knife; MSAA) · jelly back-face depth
//          · jelly (refraction/absorption; MSAA) + mesh overlay · tone map
// ─────────────────────────────────────────────────────────────

import Metal
import MetalKit
import simd

struct Uniforms {
    var viewProj = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    var lightVP = matrix_identity_float4x4
    var topVP = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 0)
    var camFwd = SIMD4<Float>(0, 0, -1, 0)
    var keyDir = SIMD4<Float>(0, 1, 0, 1)
    var screen = SIMD4<Float>(1, 1, 1, 1)
    var flesh = SIMD4<Float>(0, 0, 0, 1)
    var fleshDeep = SIMD4<Float>(0, 0, 0, 1)
    var pale = SIMD4<Float>(0, 0, 0, 1)
    var skin = SIMD4<Float>(0, 0, 0, 1)
    var stripe = SIMD4<Float>(0, 0, 0, 1)
    var seed = SIMD4<Float>(0, 0, 0, 1)
    var shape = SIMD4<Float>(0, 0, 0, 0)
    var misc = SIMD4<Float>(1, 0, 0, 0)
    var bg = SIMD4<Float>(0, 0, 0, 1)
    var shadowTint = SIMD4<Float>(0, 0, 0, 1)
}

enum RendererError: Error { case noDevice, noLibrary, pipeline(String) }

final class Renderer {
    static let msaa = 4
    static let maxInFlight = 3
    static let uniformIndex = 4

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: Renderer.maxInFlight)
    private var frameIndex = 0

    // pipelines
    private var pDepth: MTLRenderPipelineState!
    private var pBackground: MTLRenderPipelineState!
    private var pProps: MTLRenderPipelineState!
    private var pBack: MTLRenderPipelineState!
    private var pCopy: MTLRenderPipelineState!
    private var pJelly: MTLRenderPipelineState!
    private var pLines: MTLRenderPipelineState!
    private var pPost: MTLRenderPipelineState!
    private var dsWriteLess: MTLDepthStencilState!
    private var dsAlways: MTLDepthStencilState!
    private var dsWriteGreater: MTLDepthStencilState!

    // per-frame ring of CPU-written buffers
    private struct FrameBuffers {
        var uniforms: MTLBuffer
        var dyn: MTLBuffer?
        var knife: MTLBuffer?
        var particles: MTLBuffer?
    }
    private var frames: [FrameBuffers] = []

    // mesh-sized static buffers
    private var staticBuf: MTLBuffer?
    private var indexBuf: MTLBuffer?
    private var lineIdx: MTLBuffer?
    private var lineCount = 0
    private var nV = 0
    private var nParticles = 0
    private var body = DrawRange(first: 0, count: 0)
    private var seeds = DrawRange(first: 0, count: 0)
    private var bubbles = DrawRange(first: 0, count: 0)

    // knife
    private var knifeStatic: MTLBuffer?
    private var knifeIdx: MTLBuffer?
    private var knifeCount = 0
    private var nK = 0

    // targets
    private let shadowSize = 1024, topSize = 512
    private var shadowTex: MTLTexture!
    private var topTex: MTLTexture!
    private var msScene: MTLTexture?
    private var msDepth: MTLTexture?
    private var sceneTex: MTLTexture?
    private var backTex: MTLTexture?
    private var backDepth: MTLTexture?
    private var msHdr: MTLTexture?
    private var hdrTex: MTLTexture?
    private(set) var width = 0, height = 0

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw RendererError.noDevice }
        queue = q
        try buildPipelines()
        for _ in 0..<Renderer.maxInFlight {
            frames.append(FrameBuffers(uniforms: device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!))
        }
        shadowTex = makeTex(.depth32Float, shadowSize, shadowSize, samples: 1, usage: [.renderTarget, .shaderRead])
        topTex = makeTex(.depth32Float, topSize, topSize, samples: 1, usage: [.renderTarget, .shaderRead])
    }

    private func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int, usage: MTLTextureUsage) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        if samples > 1 { d.textureType = .type2DMultisample; d.sampleCount = samples }
        return device.makeTexture(descriptor: d)!
    }

    private func buildPipelines() throws {
        guard let lib = device.makeDefaultLibrary() else { throw RendererError.noLibrary }
        let f = { (name: String) -> MTLFunction in lib.makeFunction(name: name)! }

        let meshVD = MTLVertexDescriptor()
        meshVD.attributes[0].format = .float3; meshVD.attributes[0].offset = 0; meshVD.attributes[0].bufferIndex = 0
        meshVD.attributes[1].format = .float3; meshVD.attributes[1].offset = 12; meshVD.attributes[1].bufferIndex = 0
        meshVD.attributes[2].format = .float3; meshVD.attributes[2].offset = 0; meshVD.attributes[2].bufferIndex = 1
        meshVD.attributes[3].format = .float; meshVD.attributes[3].offset = 12; meshVD.attributes[3].bufferIndex = 1
        meshVD.layouts[0].stride = 24
        meshVD.layouts[1].stride = 16
        let posVD = MTLVertexDescriptor()
        posVD.attributes[0].format = .float3; posVD.attributes[0].offset = 0; posVD.attributes[0].bufferIndex = 0
        posVD.layouts[0].stride = 24
        let lineVD = MTLVertexDescriptor()
        lineVD.attributes[0].format = .float3; lineVD.attributes[0].offset = 0; lineVD.attributes[0].bufferIndex = 0
        lineVD.layouts[0].stride = 12

        func make(_ label: String, _ vs: String, _ fs: String?, vd: MTLVertexDescriptor?, color: MTLPixelFormat?,
                  depth: MTLPixelFormat, samples: Int, blend: Bool = false, lines: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = f(vs)
            if let fs { d.fragmentFunction = f(fs) }
            d.vertexDescriptor = vd
            if let color {
                d.colorAttachments[0].pixelFormat = color
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                    c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            d.depthAttachmentPixelFormat = depth
            d.rasterSampleCount = samples
            if lines { d.inputPrimitiveTopology = .line }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.pipeline("\(label): \(error)") }
        }
        let HDR = MTLPixelFormat.rgba16Float
        let ms = Renderer.msaa
        pDepth = try make("depth", "vsDepth", nil, vd: posVD, color: nil, depth: .depth32Float, samples: 1)
        pBackground = try make("background", "vsFullNdc", "fsBackground", vd: nil, color: HDR, depth: .depth32Float, samples: ms)
        pProps = try make("props", "vsMesh", "fsProps", vd: meshVD, color: HDR, depth: .depth32Float, samples: ms)
        pBack = try make("back", "vsBack", "fsBack", vd: posVD, color: .r32Float, depth: .depth32Float, samples: 1)
        pCopy = try make("copy", "vsFull", "fsCopy", vd: nil, color: HDR, depth: .depth32Float, samples: ms)
        pJelly = try make("jelly", "vsJelly", "fsJelly", vd: meshVD, color: HDR, depth: .depth32Float, samples: ms)
        pLines = try make("lines", "vsLine", "fsLine", vd: lineVD, color: HDR, depth: .depth32Float, samples: ms, blend: true, lines: true)
        pPost = try make("post", "vsFull", "fsPost", vd: nil, color: .bgra8Unorm, depth: .invalid, samples: 1)

        let dl = MTLDepthStencilDescriptor(); dl.depthCompareFunction = .less; dl.isDepthWriteEnabled = true
        dsWriteLess = device.makeDepthStencilState(descriptor: dl)
        let da = MTLDepthStencilDescriptor(); da.depthCompareFunction = .always; da.isDepthWriteEnabled = false
        dsAlways = device.makeDepthStencilState(descriptor: da)
        let dg = MTLDepthStencilDescriptor(); dg.depthCompareFunction = .greater; dg.isDepthWriteEnabled = true
        dsWriteGreater = device.makeDepthStencilState(descriptor: dg)
    }

    private func buffer<T>(_ data: [T]) -> MTLBuffer? {
        let len = max(16, data.count * MemoryLayout<T>.stride)
        if data.isEmpty { return device.makeBuffer(length: len, options: .storageModeShared) }
        return data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    // the knife is a small rigid mesh posed on the CPU each frame
    func setKnife(_ k: KnifeMesh) {
        nK = k.rest.count / 3
        var st = [Float](repeating: 0, count: nK * 4)
        for i in 0..<nK { st[4 * i] = k.rest[3 * i]; st[4 * i + 1] = k.rest[3 * i + 1]; st[4 * i + 2] = k.rest[3 * i + 2]; st[4 * i + 3] = k.mat[i] }
        knifeStatic = buffer(st)
        knifeIdx = buffer(k.index)
        knifeCount = k.index.count
        for i in frames.indices { frames[i].knife = device.makeBuffer(length: max(16, nK * 24), options: .storageModeShared) }
    }

    // (re)build every mesh-sized GPU buffer — at start and after each knife cut, never while dragging
    func setMesh(_ mesh: RenderMesh, edges: [UInt32], nParticles: Int) {
        nV = mesh.rest.count / 3
        self.nParticles = nParticles
        var st = [Float](repeating: 0, count: nV * 4)
        for i in 0..<nV { st[4 * i] = mesh.rest[3 * i]; st[4 * i + 1] = mesh.rest[3 * i + 1]; st[4 * i + 2] = mesh.rest[3 * i + 2]; st[4 * i + 3] = mesh.mat[i] }
        staticBuf = buffer(st)
        indexBuf = buffer(mesh.index)
        lineIdx = buffer(edges)
        lineCount = edges.count
        body = mesh.body; seeds = mesh.seeds; bubbles = mesh.bubbles
        for i in frames.indices {
            frames[i].dyn = device.makeBuffer(length: max(16, nV * 24), options: .storageModeShared)
            frames[i].particles = device.makeBuffer(length: max(16, nParticles * 12), options: .storageModeShared)
        }
    }

    private func resize(_ w: Int, _ h: Int) {
        let w = max(1, w), h = max(1, h)
        if w == width && h == height { return }
        width = w; height = h
        let ms = Renderer.msaa
        msScene = makeTex(.rgba16Float, w, h, samples: ms, usage: [.renderTarget])
        msDepth = makeTex(.depth32Float, w, h, samples: ms, usage: [.renderTarget])
        sceneTex = makeTex(.rgba16Float, w, h, samples: 1, usage: [.renderTarget, .shaderRead])
        backTex = makeTex(.r32Float, w, h, samples: 1, usage: [.renderTarget, .shaderRead])
        backDepth = makeTex(.depth32Float, w, h, samples: 1, usage: [.renderTarget])
        msHdr = makeTex(.rgba16Float, w, h, samples: ms, usage: [.renderTarget])
        hdrTex = makeTex(.rgba16Float, w, h, samples: 1, usage: [.renderTarget, .shaderRead])
    }

    struct FrameInput {
        var uniforms: Uniforms
        var dyn: UnsafePointer<Float>
        var knifeDyn: UnsafePointer<Float>?
        var particles: UnsafePointer<Float>
        var showMesh: Bool
        var knifeVisible: Bool
    }

    func drawableSize(for view: MTKView) -> (Int, Int) { (Int(view.drawableSize.width), Int(view.drawableSize.height)) }

    func draw(in view: MTKView, _ input: FrameInput) {
        let (w, h) = drawableSize(for: view)
        if w < 1 || h < 1 { return }
        inFlight.wait()
        resize(w, h)
        frameIndex = (frameIndex + 1) % Renderer.maxInFlight
        let fb = frames[frameIndex]
        guard let dynBuf = fb.dyn, let particleBuf = fb.particles, let staticBuf, let indexBuf,
              let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }

        var u = input.uniforms
        u.screen = SIMD4(Float(w), Float(h), 1 / Float(w), 1 / Float(h))
        memcpy(fb.uniforms.contents(), &u, MemoryLayout<Uniforms>.stride)
        memcpy(dynBuf.contents(), input.dyn, nV * 24)
        let knife = input.knifeVisible && fb.knife != nil && input.knifeDyn != nil && knifeStatic != nil
        if knife, let kb = fb.knife, let kd = input.knifeDyn { memcpy(kb.contents(), kd, nK * 24) }
        if input.showMesh { memcpy(particleBuf.contents(), input.particles, nParticles * 12) }

        let bodyAndSeeds = body.count + seeds.count
        let U = Renderer.uniformIndex
        cmd.addCompletedHandler { [weak self] _ in self?.inFlight.signal() }

        // shadow map from the key light, and a top-down height map for contact occlusion
        for (tex, m) in [(shadowTex!, u.lightVP), (topTex!, u.topVP)] {
            let rp = MTLRenderPassDescriptor()
            rp.depthAttachment.texture = tex
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1
            rp.depthAttachment.storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.setRenderPipelineState(pDepth)
            enc.setDepthStencilState(dsWriteLess)
            enc.setCullMode(.none)
            enc.setDepthBias(2, slopeScale: 2, clamp: 0)
            var mm = m
            enc.setVertexBytes(&mm, length: MemoryLayout<simd_float4x4>.stride, index: U)
            enc.setVertexBuffer(dynBuf, offset: 0, index: 0)
            if bodyAndSeeds > 0 {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: bodyAndSeeds, indexType: .uint32, indexBuffer: indexBuf, indexBufferOffset: 0)
            }
            // the knife casts a shadow but stays out of the contact-occlusion height map
            if knife && tex === shadowTex, let kb = fb.knife, let ki = knifeIdx {
                enc.setVertexBuffer(kb, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: knifeCount, indexType: .uint32, indexBuffer: ki, indexBufferOffset: 0)
            }
            enc.endEncoding()
        }

        // scene behind / inside the jelly
        do {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = msScene
            rp.colorAttachments[0].resolveTexture = sceneTex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1000)
            rp.colorAttachments[0].storeAction = .multisampleResolve
            rp.depthAttachment.texture = msDepth
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1
            rp.depthAttachment.storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setFrontFacing(.counterClockwise)
                enc.setVertexBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentTexture(shadowTex, index: 0)
                enc.setFragmentTexture(topTex, index: 1)
                enc.setRenderPipelineState(pBackground)
                enc.setDepthStencilState(dsAlways)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.setRenderPipelineState(pProps)
                enc.setDepthStencilState(dsWriteLess)
                enc.setCullMode(.back)
                enc.setVertexBuffer(dynBuf, offset: 0, index: 0)
                enc.setVertexBuffer(staticBuf, offset: 0, index: 1)
                if seeds.count > 0 {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: seeds.count, indexType: .uint32, indexBuffer: indexBuf, indexBufferOffset: seeds.first * 4)
                }
                if bubbles.count > 0 {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: bubbles.count, indexType: .uint32, indexBuffer: indexBuf, indexBufferOffset: bubbles.first * 4)
                }
                // the knife lives in the scene pass, so the part buried in the jelly is seen refracted through it
                if knife, let kb = fb.knife, let ks = knifeStatic, let ki = knifeIdx {
                    enc.setVertexBuffer(kb, offset: 0, index: 0)
                    enc.setVertexBuffer(ks, offset: 0, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: knifeCount, indexType: .uint32, indexBuffer: ki, indexBufferOffset: 0)
                }
                enc.endEncoding()
            }
        }

        // farthest back face depth
        do {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = backTex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = backDepth
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 0
            rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setFrontFacing(.counterClockwise)
                enc.setCullMode(.front)
                enc.setRenderPipelineState(pBack)
                enc.setDepthStencilState(dsWriteGreater)
                enc.setVertexBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentBuffer(fb.uniforms, offset: 0, index: U)
                enc.setVertexBuffer(dynBuf, offset: 0, index: 0)
                if body.count > 0 {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: body.count, indexType: .uint32, indexBuffer: indexBuf, indexBufferOffset: 0)
                }
                enc.endEncoding()
            }
        }

        // jelly
        do {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = msHdr
            rp.colorAttachments[0].resolveTexture = hdrTex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .multisampleResolve
            rp.depthAttachment.texture = msDepth
            rp.depthAttachment.loadAction = .load
            rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setFrontFacing(.counterClockwise)
                enc.setVertexBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentTexture(sceneTex, index: 0)
                enc.setFragmentTexture(backTex, index: 1)
                enc.setRenderPipelineState(pCopy)
                enc.setDepthStencilState(dsAlways)
                enc.setCullMode(.none)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.setRenderPipelineState(pJelly)
                enc.setDepthStencilState(dsWriteLess)
                enc.setCullMode(.back)
                enc.setVertexBuffer(dynBuf, offset: 0, index: 0)
                enc.setVertexBuffer(staticBuf, offset: 0, index: 1)
                if body.count > 0 {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: body.count, indexType: .uint32, indexBuffer: indexBuf, indexBufferOffset: 0)
                }
                if input.showMesh, let li = lineIdx, lineCount > 0 {
                    enc.setRenderPipelineState(pLines)
                    enc.setDepthStencilState(dsAlways)
                    enc.setCullMode(.none)
                    enc.setVertexBuffer(particleBuf, offset: 0, index: 0)
                    enc.drawIndexedPrimitives(type: .line, indexCount: lineCount, indexType: .uint32, indexBuffer: li, indexBufferOffset: 0)
                }
                enc.endEncoding()
            }
        }

        // tone map to the drawable
        if let rp = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(pPost)
                enc.setFragmentBuffer(fb.uniforms, offset: 0, index: U)
                enc.setFragmentTexture(hdrTex, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cmd.present(drawable)
        }
        cmd.commit()
    }
}
