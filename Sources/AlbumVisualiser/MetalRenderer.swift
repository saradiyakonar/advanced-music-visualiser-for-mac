import AppKit
import CoreImage
import MetalKit
import QuartzCore
import VisualiserCore

/// Draws one full-screen pass per frame from the animator's current VisualFrame.
final class MetalRenderer: NSObject, MTKViewDelegate {
    /// Cover half-side as a fraction of the screen's shorter dimension (cover side = 50%).
    static let coverHalf: Float = 0.25

    struct Uniforms {
        var colours: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var colourCount: Float
        var resolution: SIMD2<Float>
        var time: Float
        var flow: Float
        var coverScale: Float
        var glowScale: Float
        var glowOpacity: Float
        var edgeEnergy: Float
        var glitch: Float
        var slices: Float
        var serial: Float
        var dim: Float
        var tilt: Float
        var coverHalf: Float
        var coverVisible: Float
        var impact: Float
        var impactProgress: Float
        var pointer: SIMD2<Float>
    }

    var animator = VisualAnimator()
    var paused = false
    /// False in lyrics mode: only the background and edge glow are drawn.
    var coverVisible = true
    var effectStrength: Float = 1
    var pointer = SIMD2<Float>(repeating: 0)
    private var smoothPointer = SIMD2<Float>(repeating: 0)
    private var visualTime: Double = 0
    /// Live band levels, already delayed to match the speakers.
    var levelsProvider: (() -> BandLevels?)?
    private(set) var palette: [RGB] = PaletteExtractor.fallback
    private var smoother = LevelSmoother()
    private var lastFrameTime: Double?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let loader: MTKTextureLoader
    private var cover: MTLTexture?
    private var blurredCover: MTLTexture?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        do {
            let lib = try device.makeLibrary(source: Shaders.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Album Visualiser: shader setup failed: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        super.init()
        view.device = device
        view.delegate = self
    }

    func setArtwork(_ image: CGImage, palette: [RGB]) {
        self.palette = palette.isEmpty ? PaletteExtractor.fallback : palette
        cover = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .generateMipmaps: true,
        ])
        if let b = Self.gaussianBlur(image, context: ciContext) {
            blurredCover = try? loader.newTexture(cgImage: b, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - (lastFrameTime ?? now))
        lastFrameTime = now
        let levels = levelsProvider?().map { smoother.update($0, dt: dt) }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let still = paused || reduced
        if !still { visualTime += dt }
        smoothPointer += ((still ? .zero : pointer) - smoothPointer) * Float(1 - exp(-dt * 5))
        let f = animator.frame(at: now, paused: still, levels: levels)
        let impact = still ? 0 : f.impact * effectStrength

        let pal = Array(palette.prefix(4))
        func c(_ i: Int) -> SIMD4<Float> { let x = pal[min(i, pal.count - 1)]; return SIMD4(x.r, x.g, x.b, 1) }
        // Edge swell: the beat envelope (recovered from frameOpacity) plus some live bass.
        let edgeEnergy = min(1, max(0, (f.frameOpacity - 0.25) / 0.75) + 0.4 * (levels?.bass ?? 0))
        var u = Uniforms(
            colours: (c(0), c(1), c(2), c(3)),
            colourCount: Float(pal.count),
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Float(visualTime.truncatingRemainder(dividingBy: 10_000)),
            flow: still ? 0 : Float(f.colourFlow.truncatingRemainder(dividingBy: 1)),
            coverScale: still ? 1 : 1 + (f.coverScale - 1) * effectStrength + impact * 0.09, glowScale: f.glowScale, glowOpacity: f.glowOpacity,
            edgeEnergy: still ? 0.1 : min(1, edgeEnergy * effectStrength + impact * 0.5), glitch: f.glitchAmount * effectStrength, slices: f.slicesVisible ? 1 : 0,
            serial: Float(f.beatSerial % 10_000), dim: paused ? 0.55 : 1, tilt: f.tilt,
            coverHalf: Self.coverHalf, coverVisible: coverVisible ? 1 : 0,
            impact: impact, impactProgress: f.impactProgress, pointer: smoothPointer)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(cover, index: 0)
        enc.setFragmentTexture(blurredCover ?? cover, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if let handler = snapshotHandler {
            snapshotHandler = nil
            let tex = drawable.texture
            cmd.addCompletedHandler { _ in
                if let img = Self.image(from: tex) { DispatchQueue.main.async { handler(img) } }
            }
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// A heavy, smooth Gaussian blur of the cover for the lyrics background (once per track).
    static func gaussianBlur(_ image: CGImage, context: CIContext) -> CGImage? {
        let input = CIImage(cgImage: image)
        let side = CGFloat(min(image.width, image.height))
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)   // no dark fringe at the edges
        f.setValue(side * 0.045, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(out, from: input.extent)
    }

    /// Debug: called once with the next rendered frame (needs `framebufferOnly = false`).
    var snapshotHandler: ((CGImage) -> Void)?

    private static func image(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height, row = w * 4
        var bytes = [UInt8](repeating: 0, count: row * h)
        tex.getBytes(&bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        return ctx.makeImage()
    }
}
