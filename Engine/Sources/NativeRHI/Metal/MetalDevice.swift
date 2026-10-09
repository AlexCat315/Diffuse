// NativeRHI Metal backend — the concrete RHIBackend.
//
// `MetalDevice` owns the `MTLDevice`, command queues, resource registries, the
// per-slot upload ring, and the swapchain surface. All work is encoded into
// `MTLCommandBuffer`s; submission is asynchronous (completion fires from
// `addCompletedHandler`), and timeline semaphores map to `MTLSharedEvent`s.

#if os(macOS)
import Metal
import QuartzCore

/// Vertex-buffer argument base index. Kept high so dynamic vertex buffers do
/// not collide with uniform-buffer argument slots (matches the reference).
let kMetalVertexBufferBaseIndex: UInt = 24

/// Swapchain/surface state, grouped so the device stays small.
final class MetalWindowSwapchain {
    let layer: CAMetalLayer
    let generation: UInt64
    var currentDrawable: CAMetalDrawable?
    var currentSwapchainTextureID: UInt32?
    var textureIDs: [Int: UInt32] = [:]

    init(layer: CAMetalLayer, generation: UInt64) { self.layer = layer; self.generation = generation }
}

public final class MetalDevice: RHIBackend {
    public let api: GraphicsAPI = .metal

    let device: MTLDevice
    let graphicsQueue: MTLCommandQueue
    let computeQueue: MTLCommandQueue
    let config: DeviceConfig
    let registries: MetalRegistries
    let libraryCache: MetalLibraryCache
    let capabilities: Capabilities
    let submissionStatus = MetalSubmissionStatus()
    let interfaces = PipelineInterfaces()
    var swapchains: [UInt32: MetalWindowSwapchain] = [:]
    var activeSlot = 0
    var uploaders: [Int: MetalFrameUploader] = [:]
    /// Lazily-grown shared staging buffer reused for immediate texture upload/readback.
    var stagingBuffer: MTLBuffer?

    private init(
        device: MTLDevice,
        graphicsQueue: MTLCommandQueue,
        computeQueue: MTLCommandQueue,
        config: DeviceConfig,
        capabilities: Capabilities
    ) {
        self.device = device
        self.graphicsQueue = graphicsQueue
        self.computeQueue = computeQueue
        self.config = config
        self.capabilities = capabilities
        self.registries = MetalRegistries()
        self.libraryCache = MetalLibraryCache(device: device)
    }

    // MARK: Creation

    public static func make(config: DeviceConfig) throws -> RHIBackend {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RHIError.unsupportedBackend("MTLCreateSystemDefaultDevice returned nil")
        }
        guard let graphicsQueue = device.makeCommandQueue() else {
            throw RHIError.outOfMemory
        }
        let computeQueue = device.makeCommandQueue() ?? graphicsQueue

        let capabilities = MetalDevice.queryCapabilities(device: device)
        return MetalDevice(
            device: device,
            graphicsQueue: graphicsQueue,
            computeQueue: computeQueue,
            config: config,
            capabilities: capabilities
        )
    }

    /// Only implemented paths are exposed, gated by native device support.
    private static func queryCapabilities(device: MTLDevice) -> Capabilities {
        // Ray tracing: the real SDK property (macOS 11+).
        // Mesh shaders use Apple7 or Mac2 family support.
        // Indirect draw: probe whether the device can create an ICB.
        let indirectDraw = MetalDevice.probeIndirectCommandBuffer(device: device)
        // 3D / cube textures: probe actual texture creation.
        let texture3D = MetalDevice.probeTexture3D(device: device)
        let textureCube = MetalDevice.probeTextureCube(device: device)

        return Capabilities {
            $0.graphics = true
            $0.compute = true
            $0.rayTracing.accelerationStructures = device.supportsRaytracing
            $0.rayTracing.computeRayQuery = device.supportsRaytracing
            $0.meshShading.mesh = device.supportsFamily(.apple7) || device.supportsFamily(.mac2)
            $0.meshShading.task = false
            $0.indirectDraw = indirectDraw
            $0.textures.texture3D = texture3D
            $0.textures.cube = textureCube
            $0.maxQueues = QueueLimits()
        }
    }

    private static func probeIndirectCommandBuffer(device: MTLDevice) -> Bool {
        let descriptor = MTLIndirectCommandBufferDescriptor()
        descriptor.commandTypes = [.draw]
        descriptor.inheritBuffers = false
        descriptor.maxVertexBufferBindCount = 0
        descriptor.maxFragmentBufferBindCount = 0
        let icb = device.makeIndirectCommandBuffer(
            descriptor: descriptor, maxCommandCount: 1, options: []
        )
        return icb != nil
    }

    private static func probeTexture3D(device: MTLDevice) -> Bool {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor) != nil
    }

    private static func probeTextureCube(device: MTLDevice) -> Bool {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .typeCube
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor) != nil
    }

    // MARK: Protocol

    public var deviceName: String { device.name }

    public func queryAdapterCapabilities() -> AdapterCapabilities {
        var result = AdapterCapabilities()
        result.rayTracing = device.supportsRaytracing
        result.meshShading = device.supportsFamily(.apple7) || device.supportsFamily(.mac2)
        return result
    }

    public func queryCapabilities() -> Capabilities {
        capabilities
    }

    public func configureSwapchain(_ handle: Swapchain, descriptor: SurfaceDescriptor) throws {
        try rhiRequire(descriptor.kind == .metalLayer, "Metal requires a CAMetalLayer surface")
        guard let raw = descriptor.nativeHandle else { throw RHIError.invalidArgument("surface nativeHandle is nil") }
        try rhiRequire([TextureFormat.bgra8Unorm, .bgra8UnormSRGB].contains(descriptor.colorFormat),
                       "CAMetalLayer requires BGRA8 or BGRA8 sRGB")
        let layer = Unmanaged<CAMetalLayer>.fromOpaque(raw).takeUnretainedValue()
        try rhiRequire(!swapchains.contains { $0.key != handle.id && $0.value.layer === layer },
                       "CAMetalLayer already has a swapchain")
        try rhiRequire(swapchains[handle.id]?.currentDrawable == nil, "present an acquired drawable before resizing")
        let generation = (swapchains[handle.id]?.generation ?? 0) + 1
        destroySwapchain(handle)
        layer.device = device
        layer.pixelFormat = mtlPixelFormat(descriptor.colorFormat)
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: descriptor.width, height: descriptor.height)
        layer.displaySyncEnabled = descriptor.vsyncEnabled
        swapchains[handle.id] = MetalWindowSwapchain(layer: layer, generation: generation)
    }

    public func destroySwapchain(_ handle: Swapchain) {
        guard let window = swapchains.removeValue(forKey: handle.id) else { return }
        for id in window.textureIDs.values { registries.textures[id] = nil }
        window.currentDrawable = nil
    }

}

#endif
