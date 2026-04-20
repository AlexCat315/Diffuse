import CWGPUBridge

// MARK: - Texture Format

public enum GPUTextureFormat: Sendable {
    case bgra8Unorm
    case rgba8Unorm
    case rgba16Float
    case depth24Plus
    case depth32Float

    var bridgeValue: WGPUBridgeTextureFormat {
        switch self {
        case .bgra8Unorm:   return WGPUBridge_TextureFormat_BGRA8Unorm
        case .rgba8Unorm:   return WGPUBridge_TextureFormat_RGBA8Unorm
        case .rgba16Float:  return WGPUBridge_TextureFormat_RGBA16Float
        case .depth24Plus:  return WGPUBridge_TextureFormat_Depth24Plus
        case .depth32Float: return WGPUBridge_TextureFormat_Depth32Float
        }
    }
}

// MARK: - Present Mode

public enum GPUPresentMode: Sendable {
    case fifo
    case fifoRelaxed
    case immediate
    case mailbox

    var bridgeValue: WGPUBridgePresentMode {
        switch self {
        case .fifo:        return WGPUBridge_PresentMode_Fifo
        case .fifoRelaxed: return WGPUBridge_PresentMode_FifoRelaxed
        case .immediate:   return WGPUBridge_PresentMode_Immediate
        case .mailbox:     return WGPUBridge_PresentMode_Mailbox
        }
    }
}

// MARK: - Load / Store Op

public enum GPULoadOp: Sendable {
    case clear
    case load

    var bridgeValue: WGPUBridgeLoadOp {
        switch self {
        case .clear: return WGPUBridge_LoadOp_Clear
        case .load:  return WGPUBridge_LoadOp_Load
        }
    }
}

public enum GPUStoreOp: Sendable {
    case store
    case discard

    var bridgeValue: WGPUBridgeStoreOp {
        switch self {
        case .store:   return WGPUBridge_StoreOp_Store
        case .discard: return WGPUBridge_StoreOp_Discard
        }
    }
}

// MARK: - Primitive Topology

public enum GPUPrimitiveTopology: Sendable {
    case triangleList
    case triangleStrip
    case lineList
    case lineStrip
    case pointList

    var bridgeValue: WGPUBridgePrimitiveTopology {
        switch self {
        case .triangleList:  return WGPUBridge_PrimitiveTopology_TriangleList
        case .triangleStrip: return WGPUBridge_PrimitiveTopology_TriangleStrip
        case .lineList:      return WGPUBridge_PrimitiveTopology_LineList
        case .lineStrip:     return WGPUBridge_PrimitiveTopology_LineStrip
        case .pointList:     return WGPUBridge_PrimitiveTopology_PointList
        }
    }
}

// MARK: - Vertex Format

public enum GPUVertexFormat: Sendable {
    case float32
    case float32x2
    case float32x3
    case float32x4
    case uint32

    var bridgeValue: WGPUBridgeVertexFormat {
        switch self {
        case .float32:   return WGPUBridge_VertexFormat_Float32
        case .float32x2: return WGPUBridge_VertexFormat_Float32x2
        case .float32x3: return WGPUBridge_VertexFormat_Float32x3
        case .float32x4: return WGPUBridge_VertexFormat_Float32x4
        case .uint32:    return WGPUBridge_VertexFormat_Uint32
        }
    }
}

// MARK: - Cull Mode

public enum GPUCullMode: Sendable {
    case none
    case front
    case back

    var bridgeValue: WGPUBridgeCullMode {
        switch self {
        case .none:  return WGPUBridge_CullMode_None
        case .front: return WGPUBridge_CullMode_Front
        case .back:  return WGPUBridge_CullMode_Back
        }
    }
}

// MARK: - Color

public struct GPUColor: Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = GPUColor(r: 0, g: 0, b: 0, a: 1)
    public static let white = GPUColor(r: 1, g: 1, b: 1, a: 1)
    public static let clear = GPUColor(r: 0, g: 0, b: 0, a: 0)

    var bridgeValue: WGPUBridgeColor {
        WGPUBridgeColor(r: r, g: g, b: b, a: a)
    }
}

// MARK: - Vertex Attribute Descriptor

public struct GPUVertexAttribute: Sendable {
    public var format: GPUVertexFormat
    public var offset: UInt64
    public var shaderLocation: UInt32

    public init(format: GPUVertexFormat, offset: UInt64, shaderLocation: UInt32) {
        self.format = format
        self.offset = offset
        self.shaderLocation = shaderLocation
    }
}

// MARK: - Vertex Buffer Layout Descriptor

public struct GPUVertexBufferLayout: Sendable {
    public var arrayStride: UInt64
    public var attributes: [GPUVertexAttribute]

    public init(arrayStride: UInt64, attributes: [GPUVertexAttribute]) {
        self.arrayStride = arrayStride
        self.attributes = attributes
    }
}

// MARK: - Buffer Usage

public struct GPUBufferUsage: OptionSet, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let copyDst = GPUBufferUsage(rawValue: 0x0008)
    public static let index   = GPUBufferUsage(rawValue: 0x0010)
    public static let vertex  = GPUBufferUsage(rawValue: 0x0020)
    public static let uniform = GPUBufferUsage(rawValue: 0x0040)
}

// MARK: - Texture Usage

public struct GPUTextureUsage: OptionSet, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let copySrc          = GPUTextureUsage(rawValue: 0x01)
    public static let copyDst          = GPUTextureUsage(rawValue: 0x02)
    public static let textureBinding   = GPUTextureUsage(rawValue: 0x04)
    public static let renderAttachment = GPUTextureUsage(rawValue: 0x10)
}
