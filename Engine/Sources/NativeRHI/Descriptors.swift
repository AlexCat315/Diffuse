// NativeRHI — resource and pipeline descriptors.

import Foundation

public struct DeviceConfig: Sendable {
    public var preferredBackends: [GraphicsAPI]
    public var enableValidation: Bool
    public var framesInFlight: Int
    public var preferLowPower: Bool
    public var vsyncEnabled: Bool

    public init(
        preferredBackends: [GraphicsAPI] = NativeRHI.platformDefaultBackends,
        enableValidation: Bool = true,
        framesInFlight: Int = 2,
        preferLowPower: Bool = false,
        vsyncEnabled: Bool = true
    ) {
        self.preferredBackends = preferredBackends
        self.enableValidation = enableValidation
        self.framesInFlight = framesInFlight
        self.preferLowPower = preferLowPower
        self.vsyncEnabled = vsyncEnabled
    }
}

/// Maximum number of queues per class the backend can expose simultaneously.
public struct QueueLimits: Sendable, Equatable {
    public var graphics: UInt8
    public var compute: UInt8
    public var transfer: UInt8

    public init(graphics: UInt8 = 1, compute: UInt8 = 1, transfer: UInt8 = 1) {
        self.graphics = graphics
        self.compute = compute
        self.transfer = transfer
    }
}

public struct BufferDescriptor: Sendable {
    public var size: Int
    public var usage: BufferUsage
    public var label: String?

    public init(size: Int, usage: BufferUsage, label: String? = nil) {
        self.size = size
        self.usage = usage
        self.label = label
    }
}

public struct BufferUsage: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let vertex = BufferUsage(rawValue: 1 << 0)
    public static let index = BufferUsage(rawValue: 1 << 1)
    public static let indirect = BufferUsage(rawValue: 1 << 2)
    public static let uniform = BufferUsage(rawValue: 1 << 3)
    public static let storageRead = BufferUsage(rawValue: 1 << 4)
    public static let storageWrite = BufferUsage(rawValue: 1 << 5)
    public static let transferSource = BufferUsage(rawValue: 1 << 6)
    public static let transferDestination = BufferUsage(rawValue: 1 << 7)
}

public struct TextureDescriptor: Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var layers: Int
    public var mipLevels: Int
    public var sampleCount: Int
    public var format: TextureFormat
    public var usage: TextureUsage
    public var dimension: TextureDimension
    public var label: String?

    public init(
        width: Int,
        height: Int,
        format: TextureFormat,
        usage: TextureUsage,
        dimension: TextureDimension = .texture2D,
        depth: Int = 1,
        layers: Int = 1,
        mipLevels: Int = 1,
        sampleCount: Int = 1,
        label: String? = nil
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.layers = layers
        self.mipLevels = mipLevels
        self.sampleCount = sampleCount
        self.format = format
        self.usage = usage
        self.dimension = dimension
        self.label = label
    }
}

public struct TextureUsage: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let sampled = TextureUsage(rawValue: 1 << 0)
    public static let colorTarget = TextureUsage(rawValue: 1 << 1)
    public static let depthStencilTarget = TextureUsage(rawValue: 1 << 2)
    public static let storageRead = TextureUsage(rawValue: 1 << 3)
    public static let storageWrite = TextureUsage(rawValue: 1 << 4)
    public static let transferSource = TextureUsage(rawValue: 1 << 5)
    public static let transferDestination = TextureUsage(rawValue: 1 << 6)
    public static let present = TextureUsage(rawValue: 1 << 7)
}

public struct SamplerDescriptor: Sendable {
    public var minFilter: SamplerFilter
    public var magFilter: SamplerFilter
    public var mipFilter: SamplerMipFilter
    public var addressModeU: SamplerAddressMode
    public var addressModeV: SamplerAddressMode
    public var addressModeW: SamplerAddressMode
    public var compareEnabled: Bool
    public var compareOp: CompareOp

    public init(
        minFilter: SamplerFilter = .linear,
        magFilter: SamplerFilter = .linear,
        mipFilter: SamplerMipFilter = .linear,
        addressModeU: SamplerAddressMode = .repeat,
        addressModeV: SamplerAddressMode = .repeat,
        addressModeW: SamplerAddressMode = .repeat,
        compareEnabled: Bool = false,
        compareOp: CompareOp = .always
    ) {
        self.minFilter = minFilter
        self.magFilter = magFilter
        self.mipFilter = mipFilter
        self.addressModeU = addressModeU
        self.addressModeV = addressModeV
        self.addressModeW = addressModeW
        self.compareEnabled = compareEnabled
        self.compareOp = compareOp
    }
}

public struct ShaderModuleDescriptor: Sendable {
    public var stage: ShaderStage
    public var format: ShaderFormat
    public var code: Data
    public var threadgroupSize = ThreadgroupSize()
    public var entryPoint: String

    public init(
        stage: ShaderStage,
        format: ShaderFormat,
        code: Data,
        entryPoint: String = "main"
    ) {
        self.stage = stage
        self.format = format
        self.code = code
        self.entryPoint = entryPoint
    }

    /// Convenience for MSL source shipped as a string.
    public init(metalSource: String, stage: ShaderStage, entryPoint: String = "main") {
        self.init(stage: stage, format: .mslSource, code: Data(metalSource.utf8), entryPoint: entryPoint)
    }
}

public enum BindingType: String, Codable, Hashable, Sendable {
    case sampler
    case texture
    case storageTexture
    case uniformBuffer
    case storageBuffer
    case accelerationStructure
}

public struct BindingLayoutEntry: Sendable {
    public var buffer = BufferBindingLayout()
    public var slot: UInt32
    public var type: BindingType
    public var visibility: ShaderVisibility
    public var arraySize: UInt32

    public init(slot: UInt32, type: BindingType, visibility: ShaderVisibility, arraySize: UInt32 = 1) {
        self.slot = slot
        self.type = type
        self.visibility = visibility
        self.arraySize = arraySize
    }
}

public struct BindingLayoutDescriptor: Sendable {
    public var entries: [BindingLayoutEntry]
    public var label: String?

    public init(entries: [BindingLayoutEntry], label: String? = nil) {
        self.entries = entries
        self.label = label
    }
}

public enum BindingResource: Hashable, Sendable {
    case sampler(Sampler)
    case texture(Texture)
    case storageTexture(Texture)
    case uniformBuffer(buffer: Buffer, offset: Int = 0)
    case storageBuffer(buffer: Buffer, offset: Int = 0)
    case accelerationStructure(AccelerationStructure)

    /// The resource kind the state tracker should observe.
    var tracksAs: (handle: any RHIHandle, type: BindingType)? {
        switch self {
        case .sampler: return nil
        case .texture(let t): return (t, .texture)
        case .storageTexture(let t): return (t, .storageTexture)
        case .uniformBuffer(let b, _): return (b, .uniformBuffer)
        case .storageBuffer(let b, _): return (b, .storageBuffer)
        case .accelerationStructure(let a): return (a, .accelerationStructure)
        }
    }
}

public struct BindingSetEntry: Hashable, Sendable {
    public var slot: UInt32
    public var resource: BindingResource

    public init(slot: UInt32, resource: BindingResource) {
        self.slot = slot
        self.resource = bindingResourceIgnoringDefaultOffset(resource)
    }
}

/// Normalizes the convenience `offset = 0` default so two entries that differ
/// only by an omitted vs explicit zero offset compare equal (cache key stable).
private func bindingResourceIgnoringDefaultOffset(_ resource: BindingResource) -> BindingResource {
    switch resource {
    case .uniformBuffer(let b, let offset) where offset == 0:
        return .uniformBuffer(buffer: b)
    case .storageBuffer(let b, let offset) where offset == 0:
        return .storageBuffer(buffer: b)
    default:
        return resource
    }
}

public struct BindingSetDescriptor: Sendable {
    public var entries: [BindingSetEntry]
    public var label: String?

    public init(entries: [BindingSetEntry], label: String? = nil) {
        self.entries = entries
        self.label = label
    }
}

public struct PipelineLayoutDescriptor: Sendable {
    public var setLayouts: [BindingLayout]
    public var pushConstants: [PushConstantRange] = []
    public var label: String?

    public init(setLayouts: [BindingLayout], label: String? = nil) {
        self.setLayouts = setLayouts
        self.label = label
    }
}

/// Backend-neutral view of a resolved binding set entry. The backend encoder
/// uses this to bind concrete GPU resources at argument `slot`.
public struct ResolvedBindingEntry: Sendable {
    public var slot: UInt32
    public var type: BindingType
    public var visibility: ShaderVisibility
    public var resource: BindingResource

    public init(slot: UInt32, type: BindingType, visibility: ShaderVisibility, resource: BindingResource) {
        self.slot = slot
        self.type = type
        self.visibility = visibility
        self.resource = resource
    }
}

public struct DepthStencilState: Sendable, Equatable {
    public var depthCompare: CompareOp
    public var depthWriteEnabled: Bool

    public init(depthCompare: CompareOp = .less, depthWriteEnabled: Bool = true) {
        self.depthCompare = depthCompare
        self.depthWriteEnabled = depthWriteEnabled
    }
}

public struct RasterizationState: Sendable, Equatable {
    public var fillMode: FillMode
    public var cullMode: CullMode
    public var frontWinding: FrontWinding

    public init(
        fillMode: FillMode = .fill,
        cullMode: CullMode = .none,
        frontWinding: FrontWinding = .counterClockwise
    ) {
        self.fillMode = fillMode
        self.cullMode = cullMode
        self.frontWinding = frontWinding
    }
}

/// HLSL input semantic for DXIL. Slang's default user varying mapping uses TEXCOORD.
public struct VertexSemantic: Sendable {
    public var name = "TEXCOORD"
    public var index: UInt32
    public init(index: UInt32) { self.index = index }
}

public struct VertexAttribute: Sendable {
    public var semantic: VertexSemantic
    public var location: UInt32
    public var format: VertexFormat
    public var offset: Int
    public var bufferIndex: UInt32

    public init(location: UInt32, format: VertexFormat, offset: Int, bufferIndex: UInt32 = 0) {
        self.semantic = VertexSemantic(index: location)
        self.location = location
        self.format = format
        self.offset = offset
        self.bufferIndex = bufferIndex
    }
}

public struct VertexBufferLayout: Sendable {
    public var stride: Int
    public var stepRate: VertexInputRate

    public init(stride: Int, stepRate: VertexInputRate = .perVertex) {
        self.stride = stride
        self.stepRate = stepRate
    }
}

public struct VertexLayoutDescriptor: Sendable {
    public var attributes: [VertexAttribute]
    public var bufferLayouts: [VertexBufferLayout]

    public init(attributes: [VertexAttribute], bufferLayouts: [VertexBufferLayout]) {
        self.attributes = attributes
        self.bufferLayouts = bufferLayouts
    }
}

/// One color attachment slot of a graphics pipeline. Multiple entries give
/// MRT rendering (the Zig original supported a single color target).
public struct ColorAttachmentDescriptor: Sendable {
    public var format: TextureFormat
    public var blend: AttachmentBlendState

    public init(format: TextureFormat, blend: AttachmentBlendState = .opaque) {
        self.format = format
        self.blend = blend
    }
}

public struct GraphicsPipelineDescriptor: Sendable {
    public var layout: PipelineLayout
    public var vertex: ShaderModule
    public var fragment: ShaderModule?
    public var colorAttachments: [ColorAttachmentDescriptor]
    public var depthFormat: TextureFormat?
    public var stencilFormat: TextureFormat?
    public var primitive: PrimitiveType
    public var rasterization: RasterizationState
    public var depthStencil: DepthStencilState?
    public var vertexLayout: VertexLayoutDescriptor?
    public var label: String?

    public init(
        layout: PipelineLayout,
        vertex: ShaderModule,
        fragment: ShaderModule? = nil,
        colorAttachments: [ColorAttachmentDescriptor] = [],
        depthFormat: TextureFormat? = .depth32Float,
        stencilFormat: TextureFormat? = nil,
        primitive: PrimitiveType = .triangleList,
        rasterization: RasterizationState = RasterizationState(),
        depthStencil: DepthStencilState? = DepthStencilState(),
        vertexLayout: VertexLayoutDescriptor? = nil,
        label: String? = nil
    ) {
        self.layout = layout
        self.vertex = vertex
        self.fragment = fragment
        self.colorAttachments = colorAttachments
        self.depthFormat = depthFormat
        self.stencilFormat = stencilFormat
        self.primitive = primitive
        self.rasterization = rasterization
        self.depthStencil = depthStencil
        self.vertexLayout = vertexLayout
        self.label = label
    }
}

public struct ComputePipelineDescriptor: Sendable {
    public var layout: PipelineLayout
    public var shader: ShaderModule
    public var label: String?

    public init(layout: PipelineLayout, shader: ShaderModule, label: String? = nil) {
        self.layout = layout
        self.shader = shader
        self.label = label
    }
}

/// Backend-neutral swapchain surface. Apple backends interpret `nativeHandle`
/// as a `CAMetalLayer`; Win32/Linux backends will use HWND/Xlib/Wayland handles.
///
/// The opaque pointer is an unmanaged platform object whose lifetime is owned
/// by the caller; the RHI only reads it during `configureSurface`, so it is
/// safe to carry across the device's lock.
public struct SurfaceDescriptor: @unchecked Sendable {
    /// Xlib Display*. On Linux nativeHandle holds the Window integer as a pointer bit pattern.
    public var display: UnsafeMutableRawPointer? = nil
    public var nativeHandle: UnsafeMutableRawPointer?
    public var width: Int
    public var height: Int
    public var colorFormat: TextureFormat
    public var vsyncEnabled: Bool

    public init(
        nativeHandle: UnsafeMutableRawPointer?,
        width: Int = 0,
        height: Int = 0,
        colorFormat: TextureFormat = .bgra8UnormSRGB,
        vsyncEnabled: Bool = true
    ) {
        self.nativeHandle = nativeHandle
        self.width = width
        self.height = height
        self.colorFormat = colorFormat
        self.vsyncEnabled = vsyncEnabled
    }
}
