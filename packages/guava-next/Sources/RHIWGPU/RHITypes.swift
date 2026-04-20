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
    case uint8x4
    case unorm8x4
    case snorm8x4
    case uint16x2
    case uint16x4
    case sint16x2
    case snorm16x2
    case float16x2
    case float16x4

    var bridgeValue: WGPUBridgeVertexFormat {
        switch self {
        case .float32:   return WGPUBridge_VertexFormat_Float32
        case .float32x2: return WGPUBridge_VertexFormat_Float32x2
        case .float32x3: return WGPUBridge_VertexFormat_Float32x3
        case .float32x4: return WGPUBridge_VertexFormat_Float32x4
        case .uint32:    return WGPUBridge_VertexFormat_Uint32
        case .uint8x4:   return WGPUBridge_VertexFormat_Uint8x4
        case .unorm8x4:  return WGPUBridge_VertexFormat_Unorm8x4
        case .snorm8x4:  return WGPUBridge_VertexFormat_Snorm8x4
        case .uint16x2:  return WGPUBridge_VertexFormat_Uint16x2
        case .uint16x4:  return WGPUBridge_VertexFormat_Uint16x4
        case .sint16x2:  return WGPUBridge_VertexFormat_Sint16x2
        case .snorm16x2: return WGPUBridge_VertexFormat_Snorm16x2
        case .float16x2: return WGPUBridge_VertexFormat_Float16x2
        case .float16x4: return WGPUBridge_VertexFormat_Float16x4
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

// MARK: - Front Face

public enum GPUFrontFace: Sendable {
    case ccw
    case cw

    var bridgeValue: WGPUBridgeFrontFace {
        switch self {
        case .ccw: return WGPUBridge_FrontFace_CCW
        case .cw:  return WGPUBridge_FrontFace_CW
        }
    }
}

// MARK: - Texture View Dimension

public enum GPUTextureViewDimension: Sendable {
    case d2
    case d2Array
    case cube
    case cubeArray
    case d3

    var bridgeValue: WGPUBridgeTextureViewDimension {
        switch self {
        case .d2:        return WGPUBridge_TextureViewDimension_2D
        case .d2Array:   return WGPUBridge_TextureViewDimension_2DArray
        case .cube:      return WGPUBridge_TextureViewDimension_Cube
        case .cubeArray: return WGPUBridge_TextureViewDimension_CubeArray
        case .d3:        return WGPUBridge_TextureViewDimension_3D
        }
    }
}

// MARK: - Stencil Operation

public enum GPUStencilOp: Sendable {
    case keep
    case zero
    case replace
    case invert
    case incrClamp
    case decrClamp
    case incrWrap
    case decrWrap

    var bridgeValue: WGPUBridgeStencilOp {
        switch self {
        case .keep:      return WGPUBridge_StencilOp_Keep
        case .zero:      return WGPUBridge_StencilOp_Zero
        case .replace:   return WGPUBridge_StencilOp_Replace
        case .invert:    return WGPUBridge_StencilOp_Invert
        case .incrClamp: return WGPUBridge_StencilOp_IncrClamp
        case .decrClamp: return WGPUBridge_StencilOp_DecrClamp
        case .incrWrap:  return WGPUBridge_StencilOp_IncrWrap
        case .decrWrap:  return WGPUBridge_StencilOp_DecrWrap
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
    public static let storage = GPUBufferUsage(rawValue: 0x0080)
    public static let mapRead = GPUBufferUsage(rawValue: 0x0001)
    public static let copySrc = GPUBufferUsage(rawValue: 0x0004)
    public static let indirect = GPUBufferUsage(rawValue: 0x0100)
}

// MARK: - Texture Usage

public struct GPUTextureUsage: OptionSet, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let copySrc          = GPUTextureUsage(rawValue: 0x01)
    public static let copyDst          = GPUTextureUsage(rawValue: 0x02)
    public static let textureBinding   = GPUTextureUsage(rawValue: 0x04)
    public static let storageBinding   = GPUTextureUsage(rawValue: 0x08)
    public static let renderAttachment = GPUTextureUsage(rawValue: 0x10)
}

// MARK: - Blend

public enum GPUBlendOp: Sendable {
    case add, subtract, reverseSubtract, min, max

    var bridgeValue: WGPUBridgeBlendOp {
        switch self {
        case .add:             return WGPUBridge_BlendOp_Add
        case .subtract:        return WGPUBridge_BlendOp_Subtract
        case .reverseSubtract: return WGPUBridge_BlendOp_ReverseSubtract
        case .min:             return WGPUBridge_BlendOp_Min
        case .max:             return WGPUBridge_BlendOp_Max
        }
    }
}

public enum GPUBlendFactor: Sendable {
    case zero, one, src, oneMinusSrc
    case srcAlpha, oneMinusSrcAlpha
    case dst, oneMinusDst
    case dstAlpha, oneMinusDstAlpha

    var bridgeValue: WGPUBridgeBlendFactor {
        switch self {
        case .zero:             return WGPUBridge_BlendFactor_Zero
        case .one:              return WGPUBridge_BlendFactor_One
        case .src:              return WGPUBridge_BlendFactor_Src
        case .oneMinusSrc:      return WGPUBridge_BlendFactor_OneMinusSrc
        case .srcAlpha:         return WGPUBridge_BlendFactor_SrcAlpha
        case .oneMinusSrcAlpha: return WGPUBridge_BlendFactor_OneMinusSrcAlpha
        case .dst:              return WGPUBridge_BlendFactor_Dst
        case .oneMinusDst:      return WGPUBridge_BlendFactor_OneMinusDst
        case .dstAlpha:         return WGPUBridge_BlendFactor_DstAlpha
        case .oneMinusDstAlpha: return WGPUBridge_BlendFactor_OneMinusDstAlpha
        }
    }
}

public struct GPUBlendComponent: Sendable {
    public var operation: GPUBlendOp
    public var srcFactor: GPUBlendFactor
    public var dstFactor: GPUBlendFactor

    public init(operation: GPUBlendOp = .add,
                srcFactor: GPUBlendFactor = .one,
                dstFactor: GPUBlendFactor = .zero) {
        self.operation = operation
        self.srcFactor = srcFactor
        self.dstFactor = dstFactor
    }
}

public struct GPUBlendState: Sendable {
    public var color: GPUBlendComponent
    public var alpha: GPUBlendComponent

    public init(color: GPUBlendComponent, alpha: GPUBlendComponent) {
        self.color = color
        self.alpha = alpha
    }

    public static let alphaBlending = GPUBlendState(
        color: GPUBlendComponent(operation: .add, srcFactor: .srcAlpha, dstFactor: .oneMinusSrcAlpha),
        alpha: GPUBlendComponent(operation: .add, srcFactor: .one, dstFactor: .oneMinusSrcAlpha)
    )

    public static let premultipliedAlpha = GPUBlendState(
        color: GPUBlendComponent(operation: .add, srcFactor: .one, dstFactor: .oneMinusSrcAlpha),
        alpha: GPUBlendComponent(operation: .add, srcFactor: .one, dstFactor: .oneMinusSrcAlpha)
    )

    var bridgeValue: WGPUBridgeBlendState {
        WGPUBridgeBlendState(
            color: WGPUBridgeBlendComponent(
                operation: color.operation.bridgeValue,
                src_factor: color.srcFactor.bridgeValue,
                dst_factor: color.dstFactor.bridgeValue
            ),
            alpha: WGPUBridgeBlendComponent(
                operation: alpha.operation.bridgeValue,
                src_factor: alpha.srcFactor.bridgeValue,
                dst_factor: alpha.dstFactor.bridgeValue
            )
        )
    }
}

// MARK: - Index Format

public enum GPUIndexFormat: Sendable {
    case uint16
    case uint32

    var bridgeValue: WGPUBridgeIndexFormat {
        switch self {
        case .uint16: return WGPUBridge_IndexFormat_Uint16
        case .uint32: return WGPUBridge_IndexFormat_Uint32
        }
    }
}

// MARK: - Filter / Address Mode

public enum GPUFilterMode: Sendable {
    case nearest, linear

    var bridgeValue: WGPUBridgeFilterMode {
        switch self {
        case .nearest: return WGPUBridge_FilterMode_Nearest
        case .linear:  return WGPUBridge_FilterMode_Linear
        }
    }
}

public enum GPUAddressMode: Sendable {
    case clampToEdge, `repeat`, mirrorRepeat

    var bridgeValue: WGPUBridgeAddressMode {
        switch self {
        case .clampToEdge:  return WGPUBridge_AddressMode_ClampToEdge
        case .repeat:       return WGPUBridge_AddressMode_Repeat
        case .mirrorRepeat: return WGPUBridge_AddressMode_MirrorRepeat
        }
    }
}

// MARK: - Shader Stage

public struct GPUShaderStage: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let vertex   = GPUShaderStage(rawValue: 0x01)
    public static let fragment = GPUShaderStage(rawValue: 0x02)
    public static let compute  = GPUShaderStage(rawValue: 0x04)
}

// MARK: - Binding Type

public enum GPUBindingType: Sendable {
    case uniformBuffer
    case storageBuffer
    case readOnlyStorageBuffer
    case sampler
    case sampledTexture

    var bridgeValue: WGPUBridgeBindingType {
        switch self {
        case .uniformBuffer:         return WGPUBridge_BindingType_UniformBuffer
        case .storageBuffer:         return WGPUBridge_BindingType_StorageBuffer
        case .readOnlyStorageBuffer: return WGPUBridge_BindingType_ReadOnlyStorageBuffer
        case .sampler:               return WGPUBridge_BindingType_Sampler
        case .sampledTexture:        return WGPUBridge_BindingType_SampledTexture
        }
    }
}

// MARK: - Compare Function

public struct GPUColorAttachment {
    public var view: GPUTextureView
    public var loadOp: GPULoadOp
    public var storeOp: GPUStoreOp
    public var clearColor: GPUColor

    public init(view: GPUTextureView,
                loadOp: GPULoadOp = .clear,
                storeOp: GPUStoreOp = .store,
                clearColor: GPUColor = .black) {
        self.view = view
        self.loadOp = loadOp
        self.storeOp = storeOp
        self.clearColor = clearColor
    }
}

public enum GPUCompareFunction: Sendable {
    case never
    case less
    case equal
    case lessEqual
    case greater
    case notEqual
    case greaterEqual
    case always

    var bridgeValue: WGPUBridgeCompareFunction {
        switch self {
        case .never:        return WGPUBridge_CompareFunction_Never
        case .less:         return WGPUBridge_CompareFunction_Less
        case .equal:        return WGPUBridge_CompareFunction_Equal
        case .lessEqual:    return WGPUBridge_CompareFunction_LessEqual
        case .greater:      return WGPUBridge_CompareFunction_Greater
        case .notEqual:     return WGPUBridge_CompareFunction_NotEqual
        case .greaterEqual: return WGPUBridge_CompareFunction_GreaterEqual
        case .always:       return WGPUBridge_CompareFunction_Always
        }
    }
}

// MARK: - Stencil Face State

public struct GPUStencilFaceState: Sendable {
    public var compare: GPUCompareFunction
    public var failOp: GPUStencilOp
    public var depthFailOp: GPUStencilOp
    public var passOp: GPUStencilOp

    public init(compare: GPUCompareFunction = .always,
                failOp: GPUStencilOp = .keep,
                depthFailOp: GPUStencilOp = .keep,
                passOp: GPUStencilOp = .keep) {
        self.compare = compare
        self.failOp = failOp
        self.depthFailOp = depthFailOp
        self.passOp = passOp
    }

    var bridgeValue: WGPUBridgeStencilFaceState {
        WGPUBridgeStencilFaceState(
            compare: compare.bridgeValue,
            fail_op: failOp.bridgeValue,
            depth_fail_op: depthFailOp.bridgeValue,
            pass_op: passOp.bridgeValue
        )
    }
}

// MARK: - Depth Stencil Pipeline State

public struct GPUDepthStencilPipelineState: Sendable {
    public var format: GPUTextureFormat
    public var depthWriteEnabled: Bool
    public var depthCompare: GPUCompareFunction
    public var stencilFront: GPUStencilFaceState
    public var stencilBack: GPUStencilFaceState
    public var stencilReadMask: UInt32
    public var stencilWriteMask: UInt32

    public init(format: GPUTextureFormat = .depth32Float,
                depthWriteEnabled: Bool = true,
                depthCompare: GPUCompareFunction = .less,
                stencilFront: GPUStencilFaceState = .init(),
                stencilBack: GPUStencilFaceState = .init(),
                stencilReadMask: UInt32 = 0xFFFFFFFF,
                stencilWriteMask: UInt32 = 0xFFFFFFFF) {
        self.format = format
        self.depthWriteEnabled = depthWriteEnabled
        self.depthCompare = depthCompare
        self.stencilFront = stencilFront
        self.stencilBack = stencilBack
        self.stencilReadMask = stencilReadMask
        self.stencilWriteMask = stencilWriteMask
    }

    var bridgeValue: WGPUBridgeDepthStencilPipelineState {
        WGPUBridgeDepthStencilPipelineState(
            format: format.bridgeValue,
            depth_write_enabled: depthWriteEnabled ? 1 : 0,
            depth_compare: depthCompare.bridgeValue,
            stencil_front: stencilFront.bridgeValue,
            stencil_back: stencilBack.bridgeValue,
            stencil_read_mask: stencilReadMask,
            stencil_write_mask: stencilWriteMask
        )
    }
}
