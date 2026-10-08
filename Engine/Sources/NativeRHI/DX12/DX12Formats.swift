import CDX12Bridge

extension TextureFormat {
    var dx12: UInt32 {
        switch self {
        case .invalid: 0; case .r8Unorm: 1; case .rgba8Unorm: 2; case .bgra8Unorm: 3
        case .bgra8UnormSRGB: 4; case .rgba8UnormSRGB: 5; case .rgba16Float: 6; case .rgba32Float: 7
        case .r32Uint: 8; case .r32Float: 9; case .depth24Unorm: 10; case .depth24UnormStencil8: 11; case .depth32Float: 12
        }
    }
}
extension ShaderStage { var dx12: UInt32 { switch self { case .vertex: 0; case .fragment: 1; case .compute: 2; case .task: 3; case .mesh: 4 } } }
extension BindingType { var dx12: UInt32 { switch self { case .sampler: 0; case .texture: 1; case .storageTexture: 2; case .uniformBuffer: 3; case .storageBuffer: 4; case .accelerationStructure: 5 } } }
extension CompareOp { var dx12: UInt32 { switch self { case .never: 0; case .less: 1; case .equal: 2; case .lessOrEqual: 3; case .greater: 4; case .notEqual: 5; case .greaterOrEqual: 6; case .always: 7 } } }
extension BlendFactor {
    var dx12: UInt32 { switch self {
    case .zero: 0; case .one: 1; case .sourceColor: 2; case .oneMinusSourceColor: 3; case .destinationColor: 4; case .oneMinusDestinationColor: 5
    case .sourceAlpha: 6; case .oneMinusSourceAlpha: 7; case .destinationAlpha: 8; case .oneMinusDestinationAlpha: 9; case .blendColor: 10; case .oneMinusBlendColor: 11; case .sourceAlphaSaturate: 12
    } }
}
extension BlendOperation { var dx12: UInt32 { switch self { case .add: 0; case .subtract: 1; case .reverseSubtract: 2; case .min: 3; case .max: 4 } } }
extension SamplerAddressMode { var dx12: UInt32 { switch self { case .repeat: 0; case .mirrorRepeat: 1; case .clampToEdge: 2 } } }
extension TextureDimension { var dx12: UInt32 { switch self { case .texture2D: 0; case .texture3D: 1; case .cube: 2; case .texture2DArray: 3 } } }
extension PrimitiveType { var dx12: UInt32 { switch self { case .triangleList: 0; case .triangleStrip: 1; case .lineList: 2; case .lineStrip: 3; case .pointList: 4 } } }
extension RasterizationState {
    func dx12(primitive: PrimitiveType) -> GRHI_RasterDesc {
        GRHI_RasterDesc(fill: fillMode == .lines ? 1 : 0, cull: cullMode == .none ? 0 : cullMode == .front ? 1 : 2, winding: frontWinding == .counterClockwise ? 1 : 0, primitive: primitive.dx12)
    }
}
extension ColorAttachmentDescriptor {
    var dx12: GRHI_ColorDesc { GRHI_ColorDesc(format: format.dx12, enabled: blend.enabled ? 1 : 0, source_rgb: blend.sourceColorBlendFactor.dx12, destination_rgb: blend.destinationColorBlendFactor.dx12, operation_rgb: blend.colorBlendOperation.dx12, source_alpha: blend.sourceAlphaBlendFactor.dx12, destination_alpha: blend.destinationAlphaBlendFactor.dx12, operation_alpha: blend.alphaBlendOperation.dx12) }
}
