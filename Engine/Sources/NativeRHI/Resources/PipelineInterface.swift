import Foundation

public struct BufferBindingLayout: Codable, Hashable, Sendable {
    public var readOnly = false
    /// When true, the binding carries no base offset; the caller supplies a
    /// dynamic offset at bind time (Vulkan *_DYNAMIC descriptor, Metal
    /// setVertexBuffer offset, DX12 root offset). Used for per-frame ring data.
    /// This is an RHI-side concept never reflected from shaders, so it defaults
    /// to false when absent from a serialized shader interface.
    public var hasDynamicOffset = false
    /// Zero denotes byte-address storage. Positive values describe structured elements.
    public var elementStride = 0
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case readOnly, hasDynamicOffset, elementStride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        hasDynamicOffset = try container.decodeIfPresent(Bool.self, forKey: .hasDynamicOffset) ?? false
        elementStride = try container.decodeIfPresent(Int.self, forKey: .elementStride) ?? 0
    }
}

/// A logical small-constant slot. Vulkan packs ranges into push-constant bytes;
/// Metal uses buffer arguments and DX12 uses root constants at b[slot], space0.
public struct PushConstantRange: Codable, Hashable, Sendable {
    public var stage: ShaderStage
    public var slot: UInt32
    public var byteCount: Int

    public init(stage: ShaderStage, slot: UInt32, byteCount: Int) {
        self.stage = stage
        self.slot = slot
        self.byteCount = byteCount
    }
}

struct PipelineInterfaceKey: Hashable {
    let setLayouts: [UInt32]
    let pushConstants: [PushConstantRange]
}

/// Backend-independent immutable layout definitions, owned until device release.
final class PipelineInterfaces {
    var uses: [UInt32: PipelineUse] = [:]
    var bindings: [UInt32: BindingLayoutDescriptor] = [:]
    var pipelines: [UInt32: PipelineLayoutDescriptor] = [:]

    func validate(_ descriptor: PipelineLayoutDescriptor) throws {
        var stages = Set<ShaderStage>()
        var slots = Set<UInt32>()
        var totalBytes = 0
        for range in descriptor.pushConstants {
            try rhiRequire(range.byteCount > 0 && range.byteCount % 4 == 0,
                           "push constants require a positive multiple of four bytes")
            try rhiRequire(stages.insert(range.stage).inserted && slots.insert(range.slot).inserted,
                           "push constant slots and stages must be unique")
            let (sum, overflow) = totalBytes.addingReportingOverflow(range.byteCount)
            try rhiRequire(!overflow && sum <= 128, "portable push constant budget is 128 bytes")
            totalBytes = sum
        }
    }
}
