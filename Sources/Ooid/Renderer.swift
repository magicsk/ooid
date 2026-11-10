import Metal
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var res: SIMD2<Float>
    var mouse: SIMD2<Float>
    var mouseV: SIMD2<Float>
    var time: Float
    var click: Float
    var clickPos: SIMD2<Float>
    var mouseEffects: Float
    var dt: Float              // seconds since the previous frame
    var opt: SIMD4<Float>
    var col0: SIMD4<Float>
    var col1: SIMD4<Float>
    var col2: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pipelines: [MTLRenderPipelineState] = []
    private var noiseTexture: MTLTexture!
    // Pre-passes, read back by the main pass as texture(1): instanced geometry
    // summed into `accum` (flow-field rods, fireflies, phosphor trace), or the
    // Turing-pattern simulation ping-ponging between the two `sim` textures.
    private var prePipelines: [String: MTLRenderPipelineState] = [:]
    private var accum: MTLTexture?
    private var accumOwner = -1           // shader whose content `accum` holds
    private var sim: [MTLTexture] = []
    private var simFlip = 0
    private var simBudget = 0.0           // fractional simulation steps carried over
    private var turingStep: MTLComputePipelineState!
    // Optional per-shader `setup_<fragment>` kernel: computes per-frame values
    // (blob centres, ink drops…) once into `scene` instead of once per pixel.
    private var setupKernels: [MTLComputePipelineState?] = []
    private lazy var scene = device.makeBuffer(length: 64 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate)!

    // This frame's uniforms. ~100 bytes, so every encoder gets its own copy via
    // set*Bytes — no buffer ring, no in-flight semaphore, no per-frame
    // completion callback waking a thread.
    private var uniforms = Uniforms(res: .zero, mouse: .zero, mouseV: .zero, time: 0, click: 0, clickPos: .zero,
                                    mouseEffects: 1, dt: 0, opt: .zero, col0: .zero, col1: .zero, col2: .zero)
    private let uniformsSize = MemoryLayout<Uniforms>.stride

    // Rendering state
    private var currentShader: Int = 0
    private let startTime = CACurrentMediaTime()
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    // Smoothed mouse (matches the prototype's 0.12 lerp)
    private var mouse = SIMD2<Float>(0.5, 0.5)
    private var mouseTarget = SIMD2<Float>(0.5, 0.5)
    private var mouseV = SIMD2<Float>.zero

    // Click impulse
    private var click: Float = 0
    private var clickPos = SIMD2<Float>(0.5, 0.5)

    // Public accessor for overlay
    var intensity: Float = 0
    var coord: SIMD2<Float> { mouse }
    var clickStrength: Float { click }
    var currentShaderIndex: Int { currentShader }
    var onShaderChange: ((Int) -> Void)?

    // Per-shader tunable option values (4 floats each). Set by OverlayView
    // sliders; read each frame when assembling uniforms.
    var optionValues: [Int: SIMD4<Float>] = [:]
    var colorValues: [Int: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)] = [:]
    var mouseEffectsEnabled: Bool = true

    func optionValue(for shaderIndex: Int) -> SIMD4<Float> {
        return optionValues[shaderIndex] ?? ShaderCatalog.defaultOptionVector(for: shaderIndex)
    }
    func setOption(shaderIndex: Int, slot: Int, value: Float) {
        var v = optionValue(for: shaderIndex)
        switch slot {
        case 0: v.x = value
        case 1: v.y = value
        case 2: v.z = value
        case 3: v.w = value
        default: return
        }
        optionValues[shaderIndex] = v
    }
    func colorSet(for shaderIndex: Int) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        return colorValues[shaderIndex] ?? ShaderCatalog.defaultColorSet(for: shaderIndex)
    }
    func setColor(shaderIndex: Int, slot: Int, value: SIMD4<Float>) {
        var cs = colorSet(for: shaderIndex)
        switch slot {
        case 0: cs.0 = value
        case 1: cs.1 = value
        case 2: cs.2 = value
        default: return
        }
        colorValues[shaderIndex] = cs
    }
    func setColorSet(shaderIndex: Int, _ cs: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        colorValues[shaderIndex] = cs
    }

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw RendererError.setupFailed("command queue") }
        self.queue = q
        super.init()

        try buildPipelines()
        buildNoiseTexture()
    }

    enum RendererError: Error { case setupFailed(String) }

    private func buildPipelines() throws {
        // Ship shader source as a text resource. Compile at launch with fast-math on,
        // then cache one pipeline per shader. Metal caches the binary in the user's
        // shader cache after the first launch, so subsequent starts are near-instant.
        guard let url = AppResources.url(forResource: "Shaders", withExtension: "metal") else {
            throw RendererError.setupFailed("Shaders.metal resource missing")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let opts = MTLCompileOptions()
        opts.fastMathEnabled = true
        opts.languageVersion = .version3_0
        let library = try device.makeLibrary(source: source, options: opts)

        let vs = library.makeFunction(name: "vs_fullscreen")
        guard vs != nil else { throw RendererError.setupFailed("missing vs_fullscreen") }

        pipelines.removeAll(keepingCapacity: true)
        for entry in ShaderCatalog.entries {
            guard let fs = library.makeFunction(name: entry.fragmentFunction) else {
                throw RendererError.setupFailed("missing \(entry.fragmentFunction)")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            desc.rasterSampleCount = 1
            pipelines.append(try device.makeRenderPipelineState(descriptor: desc))
            setupKernels.append(try library.makeFunction(name: "setup_" + entry.fragmentFunction)
                .map { try device.makeComputePipelineState(function: $0) })
        }

        // name: (vertex, fragment, format, additive blend, fade blend)
        let pre: [(String, String, String, MTLPixelFormat, Bool)] = [
            ("rods",  "vs12_rod",      "fs12_rod",   .r16Float,  true),
            ("flies", "vs20_fly",      "fs20_fly",   .r16Float,  true),
            ("trace", "vs21_trace",    "fs21_trace", .r16Float,  true),
            ("fade",  "vs_fullscreen", "fs_fade",    .r16Float,  false),
            ("seed",  "vs_fullscreen", "fs22_seed",  .rg16Float, false),
        ]
        for (name, v, f, format, additive) in pre {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = format
            if name == "fade" {
                // dst × blendColor: scales what's there by the per-frame decay
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .zero
                d.colorAttachments[0].destinationRGBBlendFactor = .blendColor
            } else if additive {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
            }
            prePipelines[name] = try device.makeRenderPipelineState(descriptor: d)
        }
        turingStep = try device.makeComputePipelineState(function: library.makeFunction(name: "ks22_step")!)
    }

    private func makeTarget(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    // Instanced quads summed into `accum`. halfLife > 0 keeps the previous
    // frame and fades it instead of clearing — the phosphor's persistence.
    private func encodeAccum(_ cb: MTLCommandBuffer, size: CGSize, pipeline: String,
                             instances: Int, grid: SIMD4<Int32> = .zero, halfLife: Double = 0, dt: Double) {
        let w = Int(size.width), h = Int(size.height)
        var fresh = accumOwner != currentShader
        if accum?.width != w || accum?.height != h { accum = makeTarget(.r16Float, w, h); fresh = true }
        accumOwner = currentShader
        let keep = halfLife > 0 && !fresh

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = accum
        rpd.colorAttachments[0].loadAction = keep ? .load : .clear
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if keep {
            let k = Float(pow(0.5, dt / halfLife))
            enc.setRenderPipelineState(prePipelines["fade"]!)
            enc.setBlendColor(red: k, green: k, blue: k, alpha: k)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        var grid = grid
        enc.setRenderPipelineState(prePipelines[pipeline]!)
        enc.setVertexBytes(&uniforms, length: uniformsSize, index: 0)
        enc.setVertexBytes(&grid, length: MemoryLayout<SIMD4<Int32>>.size, index: 1)
        enc.setVertexTexture(noiseTexture, index: 0)
        enc.setFragmentBytes(&uniforms, length: uniformsSize, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances)
        enc.endEncoding()
    }

    // Gray–Scott reaction–diffusion on a grid at 1/3 of the drawable, ~480
    // steps a second whatever the frame rate (capped at 12 per frame, so an
    // idle 15 fps just evolves slower). Returns the latest state texture.
    private func encodeTuring(_ cb: MTLCommandBuffer, size: CGSize, dt: Double) -> MTLTexture? {
        let w = max(1, Int(size.width) / 3), h = max(1, Int(size.height) / 3)
        if sim.first?.width != w || sim.first?.height != h {
            sim = [makeTarget(.rg16Float, w, h), makeTarget(.rg16Float, w, h)]
            simFlip = 0
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = sim[0]
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(prePipelines["seed"]!)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        simBudget = min(simBudget + dt * 480, 12)
        let steps = Int(simBudget)
        simBudget -= Double(steps)
        guard steps > 0, let enc = cb.makeComputeCommandEncoder() else { return sim[simFlip] }
        enc.setComputePipelineState(turingStep)
        enc.setBytes(&uniforms, length: uniformsSize, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        for _ in 0..<steps {
            enc.setTexture(sim[simFlip], index: 0)
            simFlip ^= 1
            enc.setTexture(sim[simFlip], index: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        }
        enc.endEncoding()
        return sim[simFlip]
    }

    // 256² lattice of random bytes behind the shaders' value noise (see vnoise in
    // Shaders.metal). Deterministic hash, so the wallpaper looks the same every launch.
    private func buildNoiseTexture() {
        let n = 256
        let bytes = (0..<UInt32(n * n)).map { i -> UInt8 in
            var x = i &* 0x9E3779B9
            x ^= x >> 16; x &*= 0x7feb352d; x ^= x >> 15; x &*= 0x846ca68b; x ^= x >> 16
            return UInt8(truncatingIfNeeded: x)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
        desc.usage = .shaderRead
        noiseTexture = device.makeTexture(descriptor: desc)!
        noiseTexture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: bytes, bytesPerRow: n)
    }

    // ---------------- MTKViewDelegate ----------------
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // no-op; Uniforms are updated every frame from view.drawableSize.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        guard let cb = queue.makeCommandBuffer() else { return }
        encodeFrame(cb, into: rpd, size: view.drawableSize, now: CACurrentMediaTime())
        cb.present(drawable)
        cb.commit()
    }

    // One frame into `rpd`'s colour attachment. Split from draw(in:) so
    // Bench.swift can drive the exact same work offscreen.
    func encodeFrame(_ cb: MTLCommandBuffer, into rpd: MTLRenderPassDescriptor, size drawableSize: CGSize, now: CFTimeInterval) {
        let dt = Float(max(0, min(0.1, now - lastTime)))
        lastTime = now

        // Smooth mouse toward target with a lerp equivalent to the HTML prototype.
        // Normalise per-frame rate so animation speed is independent of refresh rate.
        let alpha = Float(1.0 - pow(1.0 - 0.12, Double(dt * 60.0)))
        let prev = mouse
        mouse += (mouseTarget - mouse) * alpha
        mouseV = mouse - prev

        // Click decay (0.94^(dt*60) so we match 60Hz reference).
        click *= Float(pow(0.94, Double(dt * 60.0)))
        if click < 0.001 { click = 0 }

        let cs = colorSet(for: currentShader)
        uniforms = Uniforms(
            res: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mouse,
            mouseV: mouseV,
            time: Float(now - startTime),
            click: click,
            clickPos: clickPos,
            mouseEffects: mouseEffectsEnabled ? 1.0 : 0.0,
            dt: dt,
            opt: optionValue(for: currentShader),
            col0: cs.0,
            col1: cs.1,
            col2: cs.2
        )

        // Update public intensity (for overlay bar)
        let speed = simd_length(mouseV) * 40.0
        intensity = min(1, speed + click * 0.6)

        var extra: MTLTexture? = nil
        switch ShaderCatalog.entries[currentShader].fragmentFunction {
        case "fs12_flowfield":
            // One rod per grid cell: 30 cells per unit of p (S12_SCALE), p.y in
            // ±1, p.x in ±aspect, plus 2 cells of margin since a rod reaches < 2
            // cells from its own.
            let aspect = Double(drawableSize.width / drawableSize.height)
            let x0 = Int32((-aspect * 30).rounded(.down)) - 2
            let x1 = Int32((aspect * 30).rounded(.down)) + 2
            let grid = SIMD4<Int32>(x0, -32, x1 - x0 + 1, 0)
            encodeAccum(cb, size: drawableSize, pipeline: "rods",
                        instances: Int(grid.z) * 65, grid: grid, dt: Double(dt))
            extra = accum
        case "fs20_fireflies":
            encodeAccum(cb, size: drawableSize, pipeline: "flies", instances: 480, dt: Double(dt))
            extra = accum
        case "fs21_phosphor":
            encodeAccum(cb, size: drawableSize, pipeline: "trace", instances: 1024,
                        halfLife: 0.12, dt: Double(dt))
            extra = accum
        case "fs22_turing":
            extra = encodeTuring(cb, size: drawableSize, dt: Double(dt))
        default:
            break
        }

        if let kernel = setupKernels[currentShader], let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(kernel)
            enc.setBytes(&uniforms, length: uniformsSize, index: 0)
            enc.setBuffer(scene, offset: 0, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }

        // Every shader writes every pixel, so the old contents don't matter.
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pipelines[currentShader])
            enc.setFragmentBytes(&uniforms, length: uniformsSize, index: 0)
            enc.setFragmentBuffer(scene, offset: 0, index: 1)
            enc.setFragmentTexture(noiseTexture, index: 0)
            enc.setFragmentTexture(extra, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    // ---------------- Input API (called from the view) ----------------
    func updateMouseNormalized(_ p: SIMD2<Float>) {
        mouseTarget = SIMD2<Float>(
            max(0, min(1, p.x)),
            max(0, min(1, p.y))
        )
    }

    func impulseClick(at p: SIMD2<Float>) {
        // Respect the global mouse-effects toggle: if mouse is disabled,
        // synthetic and real clicks both no-op. Keeps shader output
        // completely independent of cursor activity when the user wants it.
        guard mouseEffectsEnabled else { return }
        clickPos = SIMD2<Float>(
            max(0, min(1, p.x)),
            max(0, min(1, p.y))
        )
        click = 1.0
    }

    func selectShader(_ i: Int) {
        let n = pipelines.count
        guard n > 0 else { return }
        let idx = ((i % n) + n) % n
        if idx != currentShader {
            currentShader = idx
            onShaderChange?(idx)
        }
    }

    func cycleShader(_ delta: Int) {
        selectShader(currentShader + delta)
    }
}
