import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

struct NativeSkinPalette {
    let parameters: BindingResource
    let matrices: BindingResource
}

/// A palette belongs to this frame, including its explicit logical length.
/// Removing or shrinking a palette cannot expose a previous frame's matrices.
struct NativeSkinBindings {
    private var palettes: [EntityID: NativeSkinPalette] = [:]
    private let fallback: NativeSkinPalette

    init(packet: RenderPacket, device: Device) throws {
        fallback = try Self.upload([], device: device)
        for (entity, palette) in packet.jointPaletteMap.palettes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            palettes[entity] = palette.matrices.isEmpty ? fallback : try Self.upload(palette.matrices, device: device)
        }
    }
    subscript(entity: EntityID?) -> NativeSkinPalette { entity.flatMap { palettes[$0] } ?? fallback }

    private static func upload(_ matrices: [simd_float4x4], device: Device) throws -> NativeSkinPalette {
        let parameters = try NativeUniformUpload.binding(SIMD4<UInt32>(UInt32(max(matrices.count,1)),0,0,0), device: device)
        let data = (matrices.isEmpty ? [matrix_identity_float4x4] : matrices).withUnsafeBytes { Data($0) }
        let upload = try device.uploadTransient(data)
        return NativeSkinPalette(parameters: parameters, matrices: .storageBuffer(buffer: upload.buffer, offset: upload.offset))
    }
}
