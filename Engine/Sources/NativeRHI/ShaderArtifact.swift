import Foundation

public struct ReflectedShaderBinding: Codable, Sendable {
    public var name: String
    public var slot: UInt32
    public var space: UInt32 = 0
    public var type: BindingType

    public init(name: String, slot: UInt32, type: BindingType) {
        self.name = name
        self.slot = slot
        self.type = type
    }
}

public struct ShaderInterface: Codable, Sendable {
    public var threadgroupSize = ThreadgroupSize()
    public var bindings: [ReflectedShaderBinding] = []
    public init() {}
}

/// The shader's declared local workgroup size, not the dispatch grid size.
public struct ThreadgroupSize: Codable, Equatable, Sendable {
    public var x = 1
    public var y = 1
    public var z = 1

    public init(x: Int = 1, y: Int = 1, z: Int = 1) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func validate() throws {
        let (xy, overflowXY) = x.multipliedReportingOverflow(by: y)
        let (_, overflowXYZ) = xy.multipliedReportingOverflow(by: z)
        try rhiRequire(x > 0 && y > 0 && z > 0 && !overflowXY && !overflowXYZ,
                       "threadgroup dimensions must be positive and representable")
    }
}

/// An offline compiler's output. The RHI consumes this contract without
/// loading Slang or requiring its runtime/reflection types in engine code.
public struct ShaderArtifact: Codable, Sendable {
    public var stage: ShaderStage
    public var format: ShaderFormat
    public var entryPoint: String
    public var code: Data
    public var interface = ShaderInterface()
    public var compiler: String

    public init(stage: ShaderStage, format: ShaderFormat, entryPoint: String,
                code: Data, compiler: String) {
        self.stage = stage
        self.format = format
        self.entryPoint = entryPoint
        self.code = code
        self.compiler = compiler
    }

    public func moduleDescriptor() throws -> ShaderModuleDescriptor {
        try interface.threadgroupSize.validate()
        try rhiRequire(!entryPoint.isEmpty && !code.isEmpty, "shader artifact is empty")
        var descriptor = ShaderModuleDescriptor(stage: stage, format: format,
                                                code: code, entryPoint: entryPoint)
        descriptor.threadgroupSize = interface.threadgroupSize
        return descriptor
    }

    /// Target-specific reflected slots. Cross-target logical bindings must be
    /// lowered by the toolchain; the backend never guesses register remappings.
    public func bindingLayoutDescriptor(space: UInt32 = 0) throws -> BindingLayoutDescriptor {
        let bindings = interface.bindings.filter { $0.space == space }
        try rhiRequire(Set(bindings.map(\.slot)).count == bindings.count,
                       "reflected resources need distinct RHI binding slots")
        return BindingLayoutDescriptor(entries: bindings.map {
            BindingLayoutEntry(slot: $0.slot, type: $0.type, stage: stage)
        })
    }
}
