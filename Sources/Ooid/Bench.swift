import Metal
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// `Ooid --bench [--png DIR]`: renders every shader offscreen through the real
// Renderer, at a 16" MBP-sized view (1728×1117 pt × its renderScale), and
// prints GPU ms/frame against the ~0.24 ms budget (see ShaderEntry.renderScale).
// --png also writes one frame per shader after ~10 s of simulated warm-up.
// --paced FPS instead renders in real time at FPS (15 = the app at idle, i.e.
// a screensaver; 30 = active) so the GPU clocks down between frames as it does
// on screen, and prints GPU busy % and this process's CPU %.
// --only SUBSTR limits either mode to shaders whose fragment function matches.
enum Bench {
    static func run(pngDir: String?, pacedFps: Double? = nil, only: String? = nil, quality: Double = 1) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Renderer.RendererError.setupFailed("no Metal") }
        let r = try Renderer(device: device)
        r.updateMouseNormalized(SIMD2<Float>(0.62, 0.55))
        var now = CACurrentMediaTime() + 10

        print(pacedFps == nil ? "shader            render       ms/frame   budget 0.24"
                              : "shader            render       GPU busy   CPU     @ \(Int(pacedFps!)) fps")
        for (i, e) in ShaderCatalog.entries.enumerated() where only.map(e.fragmentFunction.contains) ?? true {
            r.selectShader(i)
            let scale = min(2, quality * e.renderScale)   // as MetalContentView.updateDrawableSize
            let size = CGSize(width: (1728 * scale).rounded(), height: (1117 * scale).rounded())
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                              height: Int(size.height), mipmapped: false)
            td.usage = .renderTarget
            td.storageMode = .private
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = device.makeTexture(descriptor: td)

            // One command buffer of 120 frames at 120 Hz: no CPU gaps in the GPU span.
            func frames(_ n: Int) -> Double {
                let cb = r.queue.makeCommandBuffer()!
                for _ in 0..<n { now += 1.0 / 120; r.encodeFrame(cb, into: rpd, size: size, now: now) }
                cb.commit(); cb.waitUntilCompleted()
                return (cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(n)
            }
            if let fps = pacedFps {
                let r = paced(r, rpd, size, fps: fps)
                print(e.fragmentFunction.padding(toLength: 18, withPad: " ", startingAt: 0)
                      + "\(Int(size.width))×\(Int(size.height))".padding(toLength: 13, withPad: " ", startingAt: 0)
                      + String(format: "%6.2f%%  %5.2f%%", r.gpu, r.cpu))
                continue
            }
            for _ in 0..<(pngDir == nil ? 1 : 10) { _ = frames(120) }   // clocks ramp, trails & simulations fill in
            let ms = frames(120)
            let name = e.fragmentFunction.padding(toLength: 18, withPad: " ", startingAt: 0)
            print(name + "\(Int(size.width))×\(Int(size.height))".padding(toLength: 13, withPad: " ", startingAt: 0)
                  + String(format: "%7.3f    %@", ms, ms <= 0.24 ? "ok" : "OVER"))

            if let dir = pngDir {
                _ = frames(1)
                try savePNG(rpd.colorAttachments[0].texture!, r, to: "\(dir)/\(String(format: "%02d", i + 1))_\(e.shortLabel).png")
            }
        }
    }

    // 1 s warm-up, then 4 s measured. GPU busy = summed command-buffer GPU
    // spans / wall time; CPU = this process's user+sys time / wall time.
    private static func paced(_ r: Renderer, _ rpd: MTLRenderPassDescriptor, _ size: CGSize,
                              fps: Double) -> (gpu: Double, cpu: Double) {
        func cpuTime() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        var gpu = 0.0, t0 = 0.0, c0 = 0.0
        let start = CACurrentMediaTime()
        for n in 0..<Int(5 * fps) {
            if n == Int(fps) { gpu = 0; t0 = CACurrentMediaTime(); c0 = cpuTime() }
            let cb = r.queue.makeCommandBuffer()!
            r.encodeFrame(cb, into: rpd, size: size, now: CACurrentMediaTime())
            cb.commit(); cb.waitUntilCompleted()
            gpu += cb.gpuEndTime - cb.gpuStartTime
            let next = start + Double(n + 1) / fps
            Thread.sleep(forTimeInterval: max(0, next - CACurrentMediaTime()))
        }
        let wall = CACurrentMediaTime() - t0
        return (gpu / wall * 100, (cpuTime() - c0) / wall * 100)
    }

    private static func savePNG(_ tex: MTLTexture, _ r: Renderer, to path: String) throws {
        let w = tex.width, h = tex.height
        let buf = r.device.makeBuffer(length: w * h * 4, options: .storageModeShared)!
        let cb = r.queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
            throw Renderer.RendererError.setupFailed("can't write \(path)")
        }
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
    }
}
