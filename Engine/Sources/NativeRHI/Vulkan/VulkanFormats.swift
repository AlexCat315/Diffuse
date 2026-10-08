// NativeRHI Vulkan — RHI ↔ Vulkan format / descriptor mappings.

#if canImport(CVulkanHeaders)
import CVulkanHeaders

enum VulkanFormats {
    static func vkFormat(_ format: TextureFormat) -> VkFormat {
        switch format {
        case .invalid: return VK_FORMAT_UNDEFINED
        case .r8Unorm: return VK_FORMAT_R8_UNORM
        case .rgba8Unorm: return VK_FORMAT_R8G8B8A8_UNORM
        case .bgra8Unorm: return VK_FORMAT_B8G8R8A8_UNORM
        case .bgra8UnormSRGB: return VK_FORMAT_B8G8R8A8_SRGB
        case .rgba8UnormSRGB: return VK_FORMAT_R8G8B8A8_SRGB
        case .rgba16Float: return VK_FORMAT_R16G16B16A16_SFLOAT
        case .rgba32Float: return VK_FORMAT_R32G32B32A32_SFLOAT
        case .r32Uint: return VK_FORMAT_R32_UINT
        case .r32Float: return VK_FORMAT_R32_SFLOAT
        case .depth24Unorm: return VK_FORMAT_X8_D24_UNORM_PACK32
        case .depth24UnormStencil8: return VK_FORMAT_D24_UNORM_S8_UINT
        case .depth32Float: return VK_FORMAT_D32_SFLOAT
        }
    }

    static func isDepth(_ format: TextureFormat) -> Bool {
        switch format {
        case .depth24Unorm, .depth24UnormStencil8, .depth32Float: return true
        default: return false
        }
    }

    static func isStencil(_ format: TextureFormat) -> Bool {
        format == .depth24UnormStencil8
    }

    static func vkVertexFormat(_ format: VertexFormat) -> VkFormat {
        switch format {
        case .float2: return VK_FORMAT_R32G32_SFLOAT
        case .float3: return VK_FORMAT_R32G32B32_SFLOAT
        case .float4: return VK_FORMAT_R32G32B32A32_SFLOAT
        }
    }

    static func vkPrimitiveTopology(_ type: PrimitiveType) -> VkPrimitiveTopology {
        switch type {
        case .triangleList: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        case .triangleStrip: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        case .lineList: return VK_PRIMITIVE_TOPOLOGY_LINE_LIST
        case .lineStrip: return VK_PRIMITIVE_TOPOLOGY_LINE_STRIP
        case .pointList: return VK_PRIMITIVE_TOPOLOGY_POINT_LIST
        }
    }

    static func vkCullMode(_ mode: CullMode) -> VkCullModeFlags {
        switch mode {
        case .none: return VK_CULL_MODE_NONE.rawValue
        case .front: return VK_CULL_MODE_FRONT_BIT.rawValue
        case .back: return VK_CULL_MODE_BACK_BIT.rawValue
        }
    }

    static func vkFrontFace(_ winding: FrontWinding) -> VkFrontFace {
        switch winding {
        case .clockwise: return VK_FRONT_FACE_CLOCKWISE
        case .counterClockwise: return VK_FRONT_FACE_COUNTER_CLOCKWISE
        }
    }

    static func vkCompareOp(_ op: CompareOp) -> VkCompareOp {
        switch op {
        case .never: return VK_COMPARE_OP_NEVER
        case .equal: return VK_COMPARE_OP_EQUAL
        case .less: return VK_COMPARE_OP_LESS
        case .lessOrEqual: return VK_COMPARE_OP_LESS_OR_EQUAL
        case .greater: return VK_COMPARE_OP_GREATER
        case .notEqual: return VK_COMPARE_OP_NOT_EQUAL
        case .greaterOrEqual: return VK_COMPARE_OP_GREATER_OR_EQUAL
        case .always: return VK_COMPARE_OP_ALWAYS
        }
    }

    static func vkBlendFactor(_ factor: BlendFactor) -> VkBlendFactor {
        switch factor {
        case .zero: return VK_BLEND_FACTOR_ZERO
        case .one: return VK_BLEND_FACTOR_ONE
        case .sourceColor: return VK_BLEND_FACTOR_SRC_COLOR
        case .oneMinusSourceColor: return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR
        case .destinationColor: return VK_BLEND_FACTOR_DST_COLOR
        case .oneMinusDestinationColor: return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR
        case .sourceAlpha: return VK_BLEND_FACTOR_SRC_ALPHA
        case .oneMinusSourceAlpha: return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        case .destinationAlpha: return VK_BLEND_FACTOR_DST_ALPHA
        case .oneMinusDestinationAlpha: return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
        case .blendColor: return VK_BLEND_FACTOR_CONSTANT_COLOR
        case .oneMinusBlendColor: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR
        case .sourceAlphaSaturate: return VK_BLEND_FACTOR_SRC_ALPHA_SATURATE
        }
    }

    static func vkBlendOp(_ op: BlendOperation) -> VkBlendOp {
        switch op {
        case .add: return VK_BLEND_OP_ADD
        case .subtract: return VK_BLEND_OP_SUBTRACT
        case .reverseSubtract: return VK_BLEND_OP_REVERSE_SUBTRACT
        case .min: return VK_BLEND_OP_MIN
        case .max: return VK_BLEND_OP_MAX
        }
    }

    static func vkFilter(_ filter: SamplerFilter) -> VkFilter {
        filter == .nearest ? VK_FILTER_NEAREST : VK_FILTER_LINEAR
    }

    static func vkSamplerMipmapMode(_ mode: SamplerMipFilter) -> VkSamplerMipmapMode {
        mode == .nearest ? VK_SAMPLER_MIPMAP_MODE_NEAREST : VK_SAMPLER_MIPMAP_MODE_LINEAR
    }

    static func vkSamplerAddressMode(_ mode: SamplerAddressMode) -> VkSamplerAddressMode {
        switch mode {
        case .repeat: return VK_SAMPLER_ADDRESS_MODE_REPEAT
        case .mirrorRepeat: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
        case .clampToEdge: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        }
    }

    static func vkIndexType(_ type: IndexType) -> VkIndexType {
        type == .uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32
    }
}

#endif // canImport(CVulkanHeaders)
