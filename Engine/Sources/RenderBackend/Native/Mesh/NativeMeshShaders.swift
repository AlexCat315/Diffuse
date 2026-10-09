import NativeRHI

enum NativeMeshShaderRole: CaseIterable {
    case vertex, color, depth, stylized, outlineVertex, outlineFragment
    var program: String {
        switch self {
        case .vertex, .color: "opaque_mesh"
        case .depth: "opaque_depth"
        case .stylized: "stylized_character"
        case .outlineVertex, .outlineFragment: "outline"
        }
    }
    var stage: ShaderStage { self == .vertex || self == .outlineVertex ? .vertex : .fragment }
}

/// Resident mesh shader modules share one explicit binding ABI. Module creation
/// is transactional, and ownership is independent of material pipeline variants.
final class NativeMeshShaders {
    private let device: Device
    private let modules: [NativeMeshShaderRole: ShaderModule]
    let bindings: BindingLayout
    init(device: Device) throws {
        self.device = device
        let roles = NativeMeshShaderRole.allCases
        let artifacts = try roles.map { try NativeShaderLibrary.artifact(name: $0.program,api: device.backendAPI,stage: $0.stage) }
        let expected: [String: UInt32] = ["draw":0,"instances":1,"meshSampler":2,"baseTexture":3,"sceneLights":4,
            "normalTexture":5,"mrTexture":6,"shadow":7,"shadowSampler":8,"shadowTexture":9,"iblTexture":10,
            "skinParameters":11,"jointPalette":12,"style":13]
        guard artifacts.allSatisfy({ $0.interface.bindings.count == expected.count
            && $0.interface.bindings.allSatisfy { expected[$0.name] == $0.slot } }) else {
            throw RHIError.layoutMismatch("native mesh shader binding ABI mismatch")
        }
        bindings = try device.makeBindingLayout(BindingLayoutDescriptor(reflecting: artifacts))
        var created: [NativeMeshShaderRole: ShaderModule] = [:]
        do {
            for (role,artifact) in zip(roles,artifacts) { created[role] = try device.makeShaderModule(artifact.moduleDescriptor()) }
        } catch { created.values.forEach { device.destroy($0) }; throw error }
        modules = created
    }
    deinit { modules.values.forEach { device.destroy($0) } }
    subscript(role: NativeMeshShaderRole) -> ShaderModule { modules[role]! }
}
