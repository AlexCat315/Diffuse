#if os(Android)
import Android
#endif
import Foundation
import GuavaUICore
import NativeRHI

/// The push constant block every backdrop pass pushes.
///
/// Declared at file scope because the shader loader validates the reflected
/// block against it. A mismatch there throws, the loader swallows that with
/// `try?`, and every frosted panel then renders as a plain one with nothing
/// reported anywhere. Checking the reflected size against this struct makes
/// that drift impossible rather than merely unlikely.
struct NativeUIBackdropParams {
    var uvTransform: SIMD4<Float>  // xy = scale, zw = offset
    var blur: SIMD4<Float>         // x = mode, yz = uv step, w = sigma
    var shape: SIMD4<Float>        // composite: xy = half size in px, z = corner radius
                                   // reveal:   xy = half frame size in px
    var reveal: SIMD4<Float>       // reveal: xy = centre in px, z = radius, w = feather

    /// Only the reveal composite reads `reveal`, so every other pass leaves it
    /// zero and stays silent about a shape it has no use for.
    init(uvTransform: SIMD4<Float>, blur: SIMD4<Float>,
         shape: SIMD4<Float> = .zero, reveal: SIMD4<Float> = .zero) {
        self.uvTransform = uvTransform
        self.blur = blur
        self.shape = shape
        self.reveal = reveal
    }
}

/// Shader modules and binding layout for `ui_backdrop.slang`.
///
/// Separate from `NativeUIShaderResources`: the UI program samples the font
/// atlas in the vertex-colour space, this one samples a frame texture and is
/// driven entirely by push constants, so the two never share a layout.
final class NativeUIBackdropShaders {
    let device: Device
    let vertex: ShaderModule
    let fragment: ShaderModule
    let bindings: BindingLayout
    let layout: PipelineLayout
    let sampler: Sampler
    let constants: PushConstantRange

    init(device: Device) throws {
        self.device = device
        self.ownsModules = true
        let vertexArtifact = try Self.artifact(api: device.backendAPI, stage: .vertex)
        let fragmentArtifact = try Self.artifact(api: device.backendAPI, stage: .fragment)
        guard fragmentArtifact.interface.pushConstants.count == 1,
              let range = fragmentArtifact.interface.pushConstants.first,
              range.stage == .fragment, range.byteCount == MemoryLayout<NativeUIBackdropParams>.size,
              vertexArtifact.interface.pushConstants.isEmpty else {
            throw RHIError.layoutMismatch("backdrop shaders require one fragment constant block of "
                + "\(MemoryLayout<NativeUIBackdropParams>.size) bytes")
        }
        constants = range
        vertex = try device.makeShaderModule(vertexArtifact.moduleDescriptor())
        do { fragment = try device.makeShaderModule(fragmentArtifact.moduleDescriptor()) }
        catch { device.destroy(vertex); throw error }
        do {
            bindings = try device.makeBindingLayout(BindingLayoutDescriptor(reflecting: [vertexArtifact, fragmentArtifact]))
            var pipelineLayout = PipelineLayoutDescriptor(setLayouts: [bindings])
            pipelineLayout.pushConstants = [constants]
            layout = try device.makePipelineLayout(pipelineLayout)
            var descriptor = SamplerDescriptor()
            descriptor.minFilter = .linear; descriptor.magFilter = .linear
            descriptor.mipFilter = .nearest
            descriptor.addressModeU = .clampToEdge; descriptor.addressModeV = .clampToEdge
            sampler = try device.makeSampler(descriptor)
        } catch {
            device.destroy(vertex); device.destroy(fragment); throw error
        }
    }

    private let ownsModules: Bool

    /// Borrow a sibling's modules. `makeSibling` shares the compiled program
    /// the same way `NativeUIShaderResources` does, so only one owner destroys.
    init(device: Device, shaders: NativeUIBackdropShaders) {
        self.device = device
        self.vertex = shaders.vertex
        self.fragment = shaders.fragment
        self.bindings = shaders.bindings
        self.layout = shaders.layout
        self.sampler = shaders.sampler
        self.constants = shaders.constants
        self.ownsModules = false
    }

    deinit {
        guard ownsModules else { return }
        device.destroy(vertex); device.destroy(fragment); device.destroy(sampler)
    }

    private static func artifact(api: GraphicsAPI, stage: ShaderStage) throws -> ShaderArtifact {
        let target: String
        switch api { case .metal: target = "metal"; case .vulkan: target = "spirv"; case .dx12: target = "dxil" }
        guard let url = ShaderResourcesBundle.bundle.url(forResource: "ui_backdrop.\(stage.rawValue)", withExtension: "json",
            subdirectory: "Shaders/Native/\(target)") else {
            throw RHIError.unsupportedFeature("missing offline \(target) backdrop shader; rebuild native renderer shaders")
        }
        let artifact = try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: url))
        guard artifact.stage == stage else { throw RHIError.layoutMismatch("backdrop artifact stage mismatch") }
        return artifact
    }
}

/// Everything the composite needs once its offscreen passes are recorded.
struct NativeUIBackdropComposite {
    /// The blurred capture: what the panel's body frosts over.
    let texture: Texture
    /// Panel rect inside the captured region, as source uv scale and offset.
    let uvTransform: SIMD4<Float>
    let blur: SIMD4<Float>
    let shape: SIMD4<Float>
    /// The capture bound for the composite draw.
    let binding: BindingSet
    /// Clip-space rect of the panel, matching the fill that draws over it.
    let x0: Float, y0: Float, x1: Float, y1: Float
}

/// Frosted backdrops for floating panels.
///
/// A backdrop is captured where the panel's fill is about to be drawn: the
/// already-rendered frame behind the panel is downsampled into a quarter-size
/// scratch target, blurred horizontally and vertically, then composited back
/// under the fill masked to its rounded rect. Everything is sized to the panel,
/// so a menu costs a handful of small passes instead of a full-frame copy, and
/// nested panels compose for free.
///
/// The frame must live in a texture the pass may *sample*. Swapchain images are
/// render targets only, so the window keeps its frame in an owned texture and
/// hands it to the swapchain with `recordBlit`.
final class NativeUIBackdropPass {
    private enum Mode: Float {
        case downsample = 0
        case blur = 1
        case composite = 2
        case blit = 3
        case reveal = 4
    }

    /// Frost is more than a blur. Over a plain backdrop a blurred frame is the
    /// same colour as the fill, so the panel is indistinguishable from paint —
    /// the material would only ever show where the frame behind it happened to
    /// have structure. Glass lifts what it passes: colour away from its own
    /// luma, then the whole result up a little, which keeps the frost visible
    /// over any backdrop.
    private static let saturation: Float = 1.8
    private static let lift: Float = 0.08

    /// Pixels of context to capture around the panel, on one axis. The blur
    /// reaches two sigma, which is exactly its radius times two, so that is
    /// all the margin there is: a blur that only sees clamped edge pixels
    /// smears them inward, which reads as a bright halo.
    static func captureMargin(blurRadius: Float, scale: Float) -> Int {
        Int(min(128, ceil(max(0, blurRadius) * 2 * scale)))
    }

    private struct Scratch {
        var resource: TextureResource
        var bindingSet: BindingSet?
        var width: Int { resource.descriptor.width }
        var height: Int { resource.descriptor.height }
    }

    private let device: Device
    private let shaders: NativeUIBackdropShaders
    private let scratchFormat: TextureFormat
    private let offscreen: GraphicsPipeline   // scratch passes: no blending
    private let composite: GraphicsPipeline   // into the frame: alpha blended
    private let blit: GraphicsPipeline        // frame -> swapchain: no blending
    private var scratchA: Scratch?
    private var scratchB: Scratch?
    private var revealCapture: Scratch?
    private var frameBinding: BindingSet?

    init(device: Device, shaders: NativeUIBackdropShaders, format: TextureFormat, samples: Int) throws {
        self.device = device
        self.shaders = shaders
        self.scratchFormat = format
        var raster = RasterizationState(); raster.cullMode = .none
        let layout = VertexLayoutDescriptor(attributes: [
            VertexAttribute(location: 0, format: .float2, offset: 0),
            VertexAttribute(location: 1, format: .float2, offset: 8)
        ], bufferLayouts: [VertexBufferLayout(stride: 16)])
        offscreen = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(
            layout: shaders.layout, vertex: shaders.vertex, fragment: shaders.fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: format)], depthFormat: nil,
            rasterization: raster, depthStencil: nil, vertexLayout: layout, label: "native-ui-backdrop"))
        // The composite draws into the frame's own target, so it has to carry
        // the window's sample count; the scratch passes stay single sample.
        var compositeDescriptor = GraphicsPipelineDescriptor(
            layout: shaders.layout, vertex: shaders.vertex, fragment: shaders.fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: format, blend: .alphaBlend)],
            depthFormat: nil, rasterization: raster, depthStencil: nil, vertexLayout: layout,
            label: "native-ui-backdrop-composite")
        compositeDescriptor.sampleCount = samples
        composite = try device.makeGraphicsPipeline(compositeDescriptor)
        blit = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(
            layout: shaders.layout, vertex: shaders.vertex, fragment: shaders.fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: format)], depthFormat: nil,
            rasterization: raster, depthStencil: nil, vertexLayout: layout,
            label: "native-ui-backdrop-blit"))
    }

    deinit {
        device.destroy(offscreen); device.destroy(composite); device.destroy(blit)
    }

    // MARK: - Recording

    /// Blur the frame behind `backdrop` and return what the main pass has to
    /// draw underneath the panel's fill. Returns `nil` when there is nothing to
    /// sample (no source, an empty panel, or a zero-sized frame region).
    func record(_ backdrop: UIBackdrop, source: Texture?, frame: SIMD2<Int>, logical: SIMD2<Float>,
                into commands: CommandBuffer) throws -> NativeUIBackdropComposite? {
        guard let source, frame.x > 0, frame.y > 0, backdrop.opacity > 0 else { return nil }
        let scaleX = Float(frame.x) / max(logical.x, 0.0001)
        let scaleY = Float(frame.y) / max(logical.y, 0.0001)
        let panel = pixelRect(backdrop.rect, scaleX: scaleX, scaleY: scaleY, frame: frame)
        guard panel.width > 0 && panel.height > 0 else { return nil }
        // Sample past the panel's edges: a blur that only sees clamped edge
        // pixels smears them inward, which reads as a bright halo.
        let marginX = Self.captureMargin(blurRadius: backdrop.blurRadius, scale: scaleX)
        let marginY = Self.captureMargin(blurRadius: backdrop.blurRadius, scale: scaleY)
        let capture = clamp(PixelRect(x: panel.x - marginX, y: panel.y - marginY,
                                      width: panel.width + marginX * 2, height: panel.height + marginY * 2),
                            frame: frame)
        let factor = downsampleFactor(for: capture)
        let width = max(1, Int(ceil(Float(capture.width) / Float(factor))))
        let height = max(1, Int(ceil(Float(capture.height) / Float(factor))))
        let a = try scratch(&scratchA, width: width, height: height)
        let b = try scratch(&scratchB, width: width, height: height)
        // `blurRadius` is a CSS-style gaussian radius: one standard deviation
        // in points, so a tap has to reach about two of them.
        let sigma = max(backdrop.blurRadius * min(scaleX, scaleY) / Float(factor), 0.5)
        // Spaced taps ride on bilinear filtering: 13 samples covering two sigma
        // instead of one sample per pixel inside it.
        let tapStep = max(1, sigma / 3)
        let captureUV = SIMD4(Float(capture.width) / Float(frame.x),
                              Float(capture.height) / Float(frame.y),
                              Float(capture.x) / Float(frame.x),
                              Float(capture.y) / Float(frame.y))

        try draw(target: a, pipeline: offscreen, binding: try bindingSet(for: source),
                 quad: try uploadQuad(x0: -1, y0: 1, x1: 1, y1: -1),
                 params: NativeUIBackdropParams(uvTransform: captureUV,
                                blur: SIMD4(Mode.downsample.rawValue, 1 / Float(frame.x), 1 / Float(frame.y), 0),
                                shape: .zero),
                 label: "backdrop-downsample",
                 into: commands)
        // Horizontal, then vertical: two 13-tap passes instead of one 169-tap
        // square, and the quarter-size target makes each tap reach four pixels.
        try draw(target: b, pipeline: offscreen, binding: try bindingSet(for: a.resource.texture),
                 quad: try uploadQuad(x0: -1, y0: 1, x1: 1, y1: -1),
                 params: NativeUIBackdropParams(uvTransform: SIMD4(1, 1, 0, 0),
                                blur: SIMD4(Mode.blur.rawValue, tapStep / Float(width), 0, sigma),
                                shape: .zero),
                 label: "backdrop-blur-h",
                 into: commands)
        try draw(target: a, pipeline: offscreen, binding: try bindingSet(for: b.resource.texture),
                 quad: try uploadQuad(x0: -1, y0: 1, x1: 1, y1: -1),
                 params: NativeUIBackdropParams(uvTransform: SIMD4(1, 1, 0, 0),
                                blur: SIMD4(Mode.blur.rawValue, 0, tapStep / Float(height), sigma),
                                shape: .zero),
                 label: "backdrop-blur-v",
                 into: commands)

        let radius = backdrop.cornerRadius * min(scaleX, scaleY)
        let blurred = a.resource.texture
        let binding = try bindingSet(for: blurred)
        return NativeUIBackdropComposite(
            texture: blurred,
            uvTransform: SIMD4(Float(panel.width) / Float(capture.width),
                               Float(panel.height) / Float(capture.height),
                               Float(panel.x - capture.x) / Float(capture.width),
                               Float(panel.y - capture.y) / Float(capture.height)),
            blur: SIMD4(Mode.composite.rawValue, Self.saturation, 0, Self.lift),
            shape: SIMD4(Float(panel.width) / 2, Float(panel.height) / 2, radius, min(1, backdrop.opacity)),
            binding: binding,
            x0: clipX(panel.x, frame: frame.x), y0: clipY(panel.y, frame: frame.y),
            x1: clipX(panel.x + panel.width, frame: frame.x), y1: clipY(panel.y + panel.height, frame: frame.y))
    }

    /// Draw a captured backdrop at the start of a main pass, under the panel.
    func draw(_ composite: NativeUIBackdropComposite, in pass: inout RenderPassEncoder) throws {
        let quad = try uploadQuad(x0: composite.x0, y0: composite.y0, x1: composite.x1, y1: composite.y1)
        pass.setPipeline(self.composite)
        pass.setVertexBuffer(quad.buffer, offset: quad.offset)
        pass.setBindingSet(composite.binding)
        pass.pushConstant(stage: .fragment, slot: shaders.constants.slot,
                          value: NativeUIBackdropParams(uvTransform: composite.uvTransform,
                                        blur: composite.blur,
                                        shape: composite.shape))
        pass.draw(vertexCount: 6)
    }

    /// Hand an owned frame to the swapchain, which is a render target only.
    func recordBlit(source: Texture, into commands: CommandBuffer, target: RenderColorTarget,
                    size: SIMD2<Int>) throws {
        try recordCopy(source: source, target: target, size: size, label: "backdrop-blit", into: commands)
    }

    // MARK: - Reveal

    /// Retain the frame that is on screen right now, so `drawReveal` can put it
    /// back over a later one.
    ///
    /// This has to be the first thing recorded in a frame: `source` is the very
    /// target the UI is about to clear and redraw, so a pass recorded ahead of
    /// this one would retain the frame being replaced instead of the one to
    /// keep. Returns the retained texture, or nil when there is nothing to hold.
    @discardableResult
    func recordRevealCapture(source: Texture, viewport: NativeUIViewport,
                             into commands: CommandBuffer) throws -> Texture? {
        let size = viewport.pixels
        guard size.x > 0, size.y > 0 else { return nil }
        // Its own target, not one of the blur scratch pair: the retained frame
        // has to outlive the capture, and a panel drawn mid-reveal must not be
        // able to recycle it.
        if revealCapture?.width != size.x || revealCapture?.height != size.y {
            var descriptor = TextureDescriptor(width: size.x, height: size.y,
                                               format: scratchFormat, usage: [.colorTarget, .sampled])
            descriptor.label = "native-ui-reveal-capture"
            revealCapture = Scratch(resource: try TextureResource(device: device, descriptor: descriptor),
                                    bindingSet: nil)
        }
        guard let capture = revealCapture else { return nil }
        let retained = capture.resource.texture
        try recordCopy(source: source, target: RenderColorTarget(texture: retained, loadAction: .dontCare, store: true),
                       size: size, label: "ui-reveal-capture", into: commands)
        return retained
    }

    /// Composite a retained frame outside the growing disc.
    /// The current frame is already in the target, so this is one full-screen
    /// quad and coverage keeps the retained frame outside the growing disc,
    /// leaving the new frame visible inside it.
    func drawReveal(_ reveal: UIReveal, source: Texture, viewport: NativeUIViewport,
                    in pass: inout RenderPassEncoder) throws {
        let size = viewport.pixels
        let quad = try uploadQuad(x0: -1, y0: 1, x1: 1, y1: -1)
        // The shader works in physical pixels because that is what `distance`
        // has to be measured in for the edge to land on a real pixel boundary.
        // Scale the origin on each axis; the smaller density keeps the reveal
        // circular when a host reports a non-uniform logical-to-pixel ratio.
        let scale = SIMD2<Float>(Float(size.x) / max(viewport.logical.x, 0.0001),
                                 Float(size.y) / max(viewport.logical.y, 0.0001))
        pass.setPipeline(composite)
        pass.setViewport(Viewport(width: Double(size.x), height: Double(size.y)))
        pass.setVertexBuffer(quad.buffer, offset: quad.offset)
        pass.setBindingSet(try revealBinding(for: source))
        pass.pushConstant(stage: .fragment, slot: shaders.constants.slot,
                          value: NativeUIBackdropParams(
                            uvTransform: SIMD4(1, 1, 0, 0),
                            blur: SIMD4(Mode.reveal.rawValue, 0, 0, 0),
                            shape: SIMD4(Float(size.x) / 2, Float(size.y) / 2, 0, 0),
                            reveal: SIMD4(reveal.centerX * scale.x, reveal.centerY * scale.y,
                                          reveal.radius * min(scale.x, scale.y),
                                          max(reveal.feather * min(scale.x, scale.y), 0.5))))
        pass.draw(vertexCount: 6)
    }

    private func revealBinding(for texture: Texture) throws -> BindingSet {
        if let set = revealCapture?.bindingSet, revealCapture?.resource.texture == texture { return set }
        let set = try makeBindingSet(texture: texture)
        revealCapture?.bindingSet = set
        return set
    }

    func clearRevealCapture() { revealCapture = nil }

    private func recordCopy(source: Texture, target: RenderColorTarget, size: SIMD2<Int>,
                            label: String, into commands: CommandBuffer) throws {
        let quad = try uploadQuad(x0: -1, y0: 1, x1: 1, y1: -1)
        let binding = try bindingSet(for: source)
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [target], label: label)) { pass in
            pass.setPipeline(blit)
            pass.setViewport(Viewport(width: Double(size.x), height: Double(size.y)))
            pass.setVertexBuffer(quad.buffer, offset: quad.offset)
            pass.setBindingSet(binding)
            pass.pushConstant(stage: .fragment, slot: shaders.constants.slot,
                              value: NativeUIBackdropParams(uvTransform: SIMD4(1, 1, 0, 0),
                                            blur: SIMD4(Mode.blit.rawValue, 0, 0, 0),
                                            shape: .zero))
            pass.draw(vertexCount: 6)
        }
    }

    // MARK: - Internals

    private struct PixelRect { var x: Int, y: Int, width: Int, height: Int }

    private func pixelRect(_ rect: UIRect, scaleX: Float, scaleY: Float, frame: SIMD2<Int>) -> PixelRect {
        let minX = Int(floor(rect.minX * scaleX)), minY = Int(floor(rect.minY * scaleY))
        let maxX = Int(ceil(rect.maxX * scaleX)), maxY = Int(ceil(rect.maxY * scaleY))
        return clamp(PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), frame: frame)
    }

    private func clamp(_ rect: PixelRect, frame: SIMD2<Int>) -> PixelRect {
        let minX = max(0, min(frame.x, rect.x)), minY = max(0, min(frame.y, rect.y))
        let maxX = max(0, min(frame.x, rect.x + rect.width))
        let maxY = max(0, min(frame.y, rect.y + rect.height))
        return PixelRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// 4x while the region is large enough that quarter-size taps still cover
    /// the blur; stepping down keeps small panels from being under-sampled.
    private func downsampleFactor(for rect: PixelRect) -> Int {
        let smallest = min(rect.width, rect.height)
        if smallest >= 96 { return 4 }
        if smallest >= 48 { return 2 }
        return 1
    }

    private func clipX(_ x: Int, frame width: Int) -> Float {
        Float(x) / Float(max(1, width)) * 2 - 1
    }

    private func clipY(_ y: Int, frame height: Int) -> Float {
        1 - Float(y) / Float(max(1, height)) * 2
    }

    private func draw(target: Scratch, pipeline: GraphicsPipeline, binding: BindingSet,
                      quad: UploadLocation, params: NativeUIBackdropParams, label: String,
                      into commands: CommandBuffer) throws {
        let descriptor = RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: target.resource.texture, loadAction: .dontCare, store: true)],
            label: label)
        commands.renderPass(descriptor: descriptor) { pass in
            pass.setPipeline(pipeline)
            pass.setViewport(Viewport(width: Double(target.width), height: Double(target.height)))
            pass.setVertexBuffer(quad.buffer, offset: quad.offset)
            pass.setBindingSet(binding)
            pass.pushConstant(stage: .fragment, slot: shaders.constants.slot, value: params)
            pass.draw(vertexCount: 6)
        }
    }

    private func uploadQuad(x0: Float, y0: Float, x1: Float, y1: Float) throws -> UploadLocation {
        let vertices: [Float] = [
            x0, y0, 0, 0,  x1, y0, 1, 0,  x1, y1, 1, 1,
            x0, y0, 0, 0,  x1, y1, 1, 1,  x0, y1, 0, 1
        ]
        return try vertices.withUnsafeBytes { try device.uploadTransient($0) }
    }

    private func scratch(_ slot: inout Scratch?, width: Int, height: Int) throws -> Scratch {
        if let existing = slot, existing.width >= width, existing.height >= height { return existing }
        // Scratch targets share the frame's format so every sRGB encode and
        // decode stays the hardware's job and the frost matches its panel.
        var descriptor = TextureDescriptor(width: width, height: height,
                                           format: scratchFormat, usage: [.colorTarget, .sampled])
        descriptor.label = "native-ui-backdrop-scratch"
        let value = Scratch(resource: try TextureResource(device: device, descriptor: descriptor),
                            bindingSet: nil)
        slot = value
        return value
    }

    private func bindingSet(for texture: Texture) throws -> BindingSet {
        if scratchA?.resource.texture == texture {
            if let set = scratchA?.bindingSet { return set }
            let set = try makeBindingSet(texture: texture); scratchA?.bindingSet = set; return set
        }
        if scratchB?.resource.texture == texture {
            if let set = scratchB?.bindingSet { return set }
            let set = try makeBindingSet(texture: texture); scratchB?.bindingSet = set; return set
        }
        if frameTexture == texture, let frameBinding { return frameBinding }
        let set = try makeBindingSet(texture: texture)
        frameTexture = texture
        frameBinding = set
        return set
    }

    private var frameTexture: Texture?

    private func makeBindingSet(texture: Texture) throws -> BindingSet {
        try device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 1, resource: .texture(texture)),
            BindingSetEntry(slot: 2, resource: .sampler(shaders.sampler))
        ]))
    }
}
