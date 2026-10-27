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
        guard let url = RenderBackendResourceBundle.bundle.url(forResource: "\(name).compute.workgroups",withExtension: "json",
            subdirectory: "Shaders/Native/\(target(for: api))") else { throw RHIError.unsupportedFeature("missing offline workgroup family for \(name)") }
        let family = try JSONDecoder().decode(ComputeFamily.self,from: Data(contentsOf: url))
        guard let code = family.variants[String(workgroupSize)] else { throw RHIError.layoutMismatch("missing \(name) workgroup variant \(workgroupSize)") }
        var result = family.base; result.code = code; result.interface.threadgroupSize.x = workgroupSize
        return result
    }
    static func artifact(name: String, api: GraphicsAPI, stage: ShaderStage) throws -> ShaderArtifact {
        try ShaderArtifact.load(from: RenderBackendResourceBundle.bundle, name: name, stage: stage,
            api: api, target: target(for: api))
    }
    private static func target(for api: GraphicsAPI) -> String {
        switch api {
        case .metal: return "metal"
        case .dx12: return "dxil"
        case .vulkan:
            #if os(Android)
            return "spirv-mobile"
            #else
            return "spirv"
            #endif
        }
    }
}
