// NativeRHI — public enumerations, bit flags and small value types.

import Foundation

public enum GraphicsAPI: String, CaseIterable, Sendable {
    case metal
    case vulkan
    case dx12

    public var displayName: String {
        switch self {
        case .metal: return "Metal"
        case .vulkan: return "Vulkan"
        case .dx12: return "DirectX 12"
        }
    }
}

public enum ShaderFormat: String, Codable, Sendable {
    case mslSource
    case metallib
    case spirv
    case dxil
}

public enum ShaderStage: String, Codable, Hashable, Sendable {
    case vertex
    case fragment
    case compute
    case task
    case mesh
}

public enum PrimitiveType: Sendable {
    case triangleList
    case triangleStrip
    case lineList
    case lineStrip
    case pointList
}

public enum FillMode: Sendable {
    case fill
    case lines
}

public enum CullMode: Sendable {
    case none
    case front
    case back
}

public enum FrontWinding: Sendable {
    case clockwise
    case counterClockwise
}

public enum CompareOp: Sendable {
    case never
    case less
    case equal
    case lessOrEqual
    case greater
    case notEqual
    case greaterOrEqual
    case always
}

public enum BlendFactor: Sendable {
    case zero
    case one
    case sourceColor
    case oneMinusSourceColor
    case destinationColor
    case oneMinusDestinationColor
    case sourceAlpha
    case oneMinusSourceAlpha
    case destinationAlpha
    case oneMinusDestinationAlpha
    case blendColor
    case oneMinusBlendColor
    case sourceAlphaSaturate
}

public enum BlendOperation: Sendable {
    case add
    case subtract
    case reverseSubtract
    case min
    case max
}

public struct AttachmentBlendState: Sendable, Equatable {
    public var enabled: Bool
    public var sourceColorBlendFactor: BlendFactor
    public var destinationColorBlendFactor: BlendFactor
    public var colorBlendOperation: BlendOperation
    public var sourceAlphaBlendFactor: BlendFactor
    public var destinationAlphaBlendFactor: BlendFactor
    public var alphaBlendOperation: BlendOperation

    public init(
        enabled: Bool = false,
        sourceColorBlendFactor: BlendFactor = .sourceAlpha,
        destinationColorBlendFactor: BlendFactor = .oneMinusSourceAlpha,
        colorBlendOperation: BlendOperation = .add,
        sourceAlphaBlendFactor: BlendFactor = .one,
        destinationAlphaBlendFactor: BlendFactor = .oneMinusSourceAlpha,
        alphaBlendOperation: BlendOperation = .add
    ) {
        self.enabled = enabled
        self.sourceColorBlendFactor = sourceColorBlendFactor
        self.destinationColorBlendFactor = destinationColorBlendFactor
        self.colorBlendOperation = colorBlendOperation
        self.sourceAlphaBlendFactor = sourceAlphaBlendFactor
        self.destinationAlphaBlendFactor = destinationAlphaBlendFactor
        self.alphaBlendOperation = alphaBlendOperation
    }

    public static let alphaBlend = AttachmentBlendState(enabled: true)
    public static let opaque = AttachmentBlendState()
}

public enum SamplerFilter: Sendable {
    case nearest
    case linear
}

public enum SamplerMipFilter: Sendable {
    case nearest
    case linear
}

public enum SamplerAddressMode: Sendable {
    case `repeat`
    case mirrorRepeat
    case clampToEdge
}

public enum VertexInputRate: Sendable {
    case perVertex
    case perInstance
}

public enum VertexFormat: Sendable {
    case float2
    case float3
    case float4
}

public enum IndexType: Sendable {
    case uint16
    case uint32
}

public enum TextureDimension: Sendable {
    case texture2D
    case texture3D
    case cube
    case texture2DArray
}

public enum TextureFormat: Sendable {
    case invalid
    case r8Unorm
    case rgba8Unorm
    case bgra8Unorm
    case bgra8UnormSRGB
    case rgba8UnormSRGB
    case rgba16Float
    case rgba32Float
    case r32Uint
    case r32Float
    case depth24Unorm
    case depth24UnormStencil8
    case depth32Float
}

/// Tracked resource usage state. Equivalent to the Zig port's packed bit
/// struct, but as an `OptionSet` so illegal states cannot be constructed.
public struct ResourceState: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let constantBuffer = ResourceState(rawValue: 1 << 0)
    public static let vertexBuffer = ResourceState(rawValue: 1 << 1)
    public static let indexBuffer = ResourceState(rawValue: 1 << 2)
    public static let indirectArgument = ResourceState(rawValue: 1 << 3)
    public static let shaderResource = ResourceState(rawValue: 1 << 4)
    public static let unorderedAccess = ResourceState(rawValue: 1 << 5)
    public static let renderTarget = ResourceState(rawValue: 1 << 6)
    public static let depthWrite = ResourceState(rawValue: 1 << 7)
    public static let depthRead = ResourceState(rawValue: 1 << 8)
    public static let copyDestination = ResourceState(rawValue: 1 << 9)
    public static let copySource = ResourceState(rawValue: 1 << 10)
    public static let present = ResourceState(rawValue: 1 << 11)
    public static let accelerationStructureRead = ResourceState(rawValue: 1 << 12)
    public static let accelerationStructureWrite = ResourceState(rawValue: 1 << 13)
    public static let resolveDestination = ResourceState(rawValue: 1 << 14)
    public static let resolveSource = ResourceState(rawValue: 1 << 15)
}

public enum QueueClass: UInt8, Sendable, CaseIterable {
    case graphics
    case compute
    case transfer

    public var index: Int {
        switch self {
        case .graphics: return 0
        case .compute: return 1
        case .transfer: return 2
        }
    }
}

public enum BarrierSyncAction: UInt8, Sendable {
    case full
    case acquire
    case release
}

public enum BarrierPassScope: UInt8, Sendable {
    case outsidePass
    case beforePass
    case afterPass
}
