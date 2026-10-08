import Foundation
import NativeRHI

/// Loads offline artifacts and combines target-specific reflected bindings.
enum NativeShaderLibrary {
    private struct ComputeFamily: Decodable { let base: ShaderArtifact; let variants: [String: Data] }
    static func computeArtifact(name: String, api: GraphicsAPI, workgroupSize: Int?) throws -> ShaderArtifact {
        let artifact = try artifact(name: name,api: api,stage: .compute)
        guard let workgroupSize else { return artifact }
        guard (1...256).contains(workgroupSize) else { throw RHIError.invalidArgument("particle workgroup must be in 1...256") }
        if artifact.interface.threadgroupSpecialization.x != nil { return artifact }
        if artifact.interface.threadgroupSize.x == workgroupSize { return artifact }
        guard api == .dx12, let url = RenderBackendResourceBundle.bundle.url(forResource: "\(name).compute.workgroups",withExtension: "json",
            subdirectory: "Shaders/Native/dxil") else { throw RHIError.unsupportedFeature("missing offline workgroup family for \(name)") }
        let family = try JSONDecoder().decode(ComputeFamily.self,from: Data(contentsOf: url))
        guard let code = family.variants[String(workgroupSize)] else { throw RHIError.layoutMismatch("missing \(name) workgroup variant \(workgroupSize)") }
        var result = family.base; result.code = code; result.interface.threadgroupSize.x = workgroupSize
        return result
    }
    static func artifact(name: String, api: GraphicsAPI, stage: ShaderStage) throws -> ShaderArtifact {
        let target: String
        switch api { case .metal: target = "metal"; case .vulkan: target = "spirv"; case .dx12: target = "dxil" }
        guard let url = RenderBackendResourceBundle.bundle.url(forResource: "\(name).\(stage.rawValue)", withExtension: "json",
            subdirectory: "Shaders/Native/\(target)") else {
            throw RHIError.unsupportedFeature("missing \(target) \(name) artifact; rebuild native renderer shaders")
        }
        let artifact = try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: url))
        guard artifact.stage == stage else { throw RHIError.layoutMismatch("artifact stage mismatch: \(name)") }
        return artifact
    }
    static func layout(artifacts: [ShaderArtifact]) throws -> BindingLayoutDescriptor {
        var entries: [UInt32: BindingLayoutEntry] = [:]
        for artifact in artifacts {
            for binding in artifact.interface.bindings {
                guard binding.space == 0 else { throw RHIError.layoutMismatch("native renderer expects space0") }
                if var existing = entries[binding.slot] {
                    guard existing.type == binding.type, existing.buffer == binding.buffer else {
                        throw RHIError.layoutMismatch("inconsistent reflected resource at \(binding.slot)")
                    }
                    existing.visibility.formUnion(ShaderVisibility(artifact.stage)); entries[binding.slot] = existing
                } else {
                    var entry = BindingLayoutEntry(slot: binding.slot, type: binding.type, visibility: ShaderVisibility(artifact.stage))
                    entry.buffer = binding.buffer; entries[binding.slot] = entry
                }
            }
        }
        return BindingLayoutDescriptor(entries: entries.values.sorted { $0.slot < $1.slot })
    }
}
