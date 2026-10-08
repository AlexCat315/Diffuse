// NativeRHI Metal backend — RHI → Metal value mappings.
//
// Pure free functions: every backend-neutral descriptor enum is translated to
// the corresponding Metal enum here. Keeping the mappings out of the device
// type keeps the device small and makes the translation trivially testable.

#if os(macOS)
import Metal

// MARK: Pixel formats

func mtlPixelFormat(_ format: TextureFormat) -> MTLPixelFormat {
    switch format {
    case .invalid:            return .invalid
    case .r8Unorm:            return .r8Unorm
    case .rgba8Unorm:         return .rgba8Unorm
    case .bgra8Unorm:         return .bgra8Unorm
    case .bgra8UnormSRGB:     return .bgra8Unorm_srgb
    case .rgba8UnormSRGB:     return .rgba8Unorm_srgb
    case .rgba16Float:        return .rgba16Float
    case .rgba32Float:        return .rgba32Float
    case .r32Uint:            return .r32Uint
    case .r32Float:           return .r32Float
    // Apple Silicon has no depth24-only format; d32Float is the depth target.
    case .depth24Unorm:       return .depth32Float
    // depth24Unorm_stencil8 is unsupported on Apple Silicon; use the combined
    // d32f + s8 format that every Apple GPU implements.
    case .depth24UnormStencil8: return .depth32Float_stencil8
    case .depth32Float:       return .depth32Float
    }
}

/// Bytes per pixel for a format, used to validate upload/readback strides.
func metalBytesPerPixel(_ format: TextureFormat) -> Int {
    switch format {
    case .r8Unorm:            return 1
    case .rgba8Unorm, .bgra8Unorm, .bgra8UnormSRGB, .rgba8UnormSRGB: return 4
    case .rgba16Float:        return 8
    case .rgba32Float, .r32Uint, .r32Float: return 4
    case .depth24Unorm, .depth32Float: return 4
    case .depth24UnormStencil8: return 5
    case .invalid:            return 4
    }
}

// MARK: Texture dimension / usage

func mtlTextureType(_ dimension: TextureDimension) -> MTLTextureType {
    switch dimension {
    case .texture2D:     return .type2D
    case .texture3D:    return .type3D
    case .cube:          return .typeCube
    case .texture2DArray: return .type2DArray
    }
}

func mtlTextureUsage(_ usage: TextureUsage) -> MTLTextureUsage {
    var result: MTLTextureUsage = []
    if usage.contains(.sampled) { result.insert(.shaderRead) }
    if usage.contains(.colorTarget) { result.insert(.renderTarget) }
    // Depth/stencil attachments are render-target attachments in Metal.
    if usage.contains(.depthStencilTarget) { result.insert(.renderTarget) }
    if usage.contains(.storageRead) { result.insert(.shaderRead) }
    if usage.contains(.storageWrite) { result.insert(.shaderWrite) }
    // Blit source needs shader-read on modern Metal; destination is implicit.
    if usage.contains(.transferSource) { result.insert(.shaderRead) }
    if usage.contains(.present) { result.insert(.renderTarget) }
    return result
}

// MARK: Vertex layout

func mtlVertexFormat(_ format: VertexFormat) -> MTLVertexFormat {
    switch format {
    case .float2: return .float2
    case .float3: return .float3
    case .float4: return .float4
    }
}

func mtlVertexStepFunction(_ rate: VertexInputRate) -> MTLVertexStepFunction {
    switch rate {
    case .perVertex:   return .perVertex
    case .perInstance: return .perInstance
    }
}

// MARK: Compare / blend

func mtlCompareFunction(_ op: CompareOp) -> MTLCompareFunction {
    switch op {
    case .never:       return .never
    case .less:        return .less
    case .equal:       return .equal
    case .lessOrEqual: return .lessEqual
    case .greater:     return .greater
    case .notEqual:    return .notEqual
    case .greaterOrEqual: return .greaterEqual
    case .always:      return .always
    }
}

func mtlBlendFactor(_ factor: BlendFactor) -> MTLBlendFactor {
    switch factor {
    case .zero:                return .zero
    case .one:                 return .one
    case .sourceColor:         return .sourceColor
    case .oneMinusSourceColor: return .oneMinusSourceColor
    case .destinationColor:    return .destinationColor
    case .oneMinusDestinationColor: return .oneMinusDestinationColor
    case .sourceAlpha:         return .sourceAlpha
    case .oneMinusSourceAlpha: return .oneMinusSourceAlpha
    case .destinationAlpha:    return .destinationAlpha
    case .oneMinusDestinationAlpha: return .oneMinusDestinationAlpha
    case .blendColor:          return .blendColor
    case .oneMinusBlendColor:  return .oneMinusBlendColor
    case .sourceAlphaSaturate: return .sourceAlphaSaturated
    }
}

func mtlBlendOperation(_ op: BlendOperation) -> MTLBlendOperation {
    switch op {
    case .add:             return .add
    case .subtract:       return .subtract
    case .reverseSubtract: return .reverseSubtract
    case .min:            return .min
    case .max:            return .max
    }
}

// MARK: Primitives / raster state

func mtlPrimitiveType(_ primitive: PrimitiveType) -> MTLPrimitiveType {
    switch primitive {
    case .triangleList:  return .triangle
    case .triangleStrip: return .triangleStrip
    case .lineList:       return .line
    case .lineStrip:      return .lineStrip
    case .pointList:      return .point
    }
}

func mtlCullMode(_ mode: CullMode) -> MTLCullMode {
    switch mode {
    case .none:  return .none
    case .front: return .front
    case .back:  return .back
    }
}

func mtlWinding(_ winding: FrontWinding) -> MTLWinding {
    switch winding {
    case .clockwise:       return .clockwise
    case .counterClockwise: return .counterClockwise
    }
}

func mtlTriangleFillMode(_ mode: FillMode) -> MTLTriangleFillMode {
    switch mode {
    case .fill:  return .fill
    case .lines:  return .lines
    }
}

// MARK: Index / samplers

func mtlIndexType(_ type: IndexType) -> MTLIndexType {
    switch type {
    case .uint16: return .uint16
    case .uint32: return .uint32
    }
}

func mtlSamplerMinMagFilter(_ filter: SamplerFilter) -> MTLSamplerMinMagFilter {
    switch filter {
    case .nearest: return .nearest
    case .linear:   return .linear
    }
}

func mtlSamplerMipFilter(_ filter: SamplerMipFilter) -> MTLSamplerMipFilter {
    switch filter {
    case .nearest: return .nearest
    case .linear:  return .linear
    }
}

func mtlSamplerAddressMode(_ mode: SamplerAddressMode) -> MTLSamplerAddressMode {
    switch mode {
    case .repeat:        return .repeat
    case .mirrorRepeat:  return .mirrorRepeat
    case .clampToEdge:   return .clampToEdge
    }
}

// MARK: Load actions

func mtlLoadAction(_ action: ColorLoadAction) -> MTLLoadAction {
    switch action {
    case .clear, .load, .dontCare:
        // `.dontCare` must not clear; `.load` keeps contents; only `.clear`
        // clears. The clear color itself is set separately.
        switch action {
        case .clear:  return .clear
        case .load:   return .load
        case .dontCare: return .dontCare
        }
    }
}

func mtlDepthLoadAction(_ action: DepthLoadAction) -> MTLLoadAction {
    switch action {
    case .clear:  return .clear
    case .load:    return .load
    case .dontCare: return .dontCare
    }
}

#endif
