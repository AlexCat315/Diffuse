import Foundation

public struct ReflectedShaderBinding: Codable, Sendable {
    public var buffer = BufferBindingLayout()
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
    public var pushConstants: [PushConstantRange] = []
    public var specializationConstants: [ReflectedShaderConstant] = []
    public var threadgroupSpecialization = ThreadgroupSpecialization()
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

    public func moduleDescriptor(specialization: [ShaderSpecializationConstant] = []) throws -> ShaderModuleDescriptor {
        try interface.threadgroupSize.validate()
        try rhiRequire(!entryPoint.isEmpty && !code.isEmpty, "shader artifact is empty")
        var descriptor = ShaderModuleDescriptor(stage: stage, format: format,
                                                code: code, entryPoint: entryPoint)
        try rhiRequire(Set(specialization.map(\.id)).count == specialization.count,"duplicate shader specialization ID")
        for constant in specialization {
            try rhiRequire(interface.specializationConstants.contains { $0.id == constant.id && $0.type == constant.value.type },
                           "unknown shader specialization ID or incompatible type")
        }
        var values = specialization
        // Materialize artifact defaults on every target so physical dispatch
        // dimensions also agree when the offline default was customized.
        for (id,size) in [(interface.threadgroupSpecialization.x,interface.threadgroupSize.x),
                          (interface.threadgroupSpecialization.y,interface.threadgroupSize.y),
                          (interface.threadgroupSpecialization.z,interface.threadgroupSize.z)] {
            guard let id else { continue }
            guard let reflected = interface.specializationConstants.first(where: { $0.id == id }),
                  reflected.type == .uint32 || reflected.type == .int32 else {
                throw RHIError.layoutMismatch("workgroup constant needs a reflected integer ID")
            }
            if !values.contains(where: { $0.id == id }) {
                let value: ShaderConstantValue
                if reflected.type == .uint32, let size = UInt32(exactly: size) { value = .uint32(size) }
                else if reflected.type == .int32, let size = Int32(exactly: size) { value = .int32(size) }
                else { throw RHIError.layoutMismatch("workgroup default is outside the constant type's range") }
                values.append(.init(id: id,value: value))
            }
        }
        descriptor.specializationConstants = values
        descriptor.threadgroupSize = try interface.threadgroupSpecialization.resolve(defaults: interface.threadgroupSize,values: values)
        return descriptor
    }

    /// Target-specific reflected slots. Cross-target logical bindings must be
    /// lowered by the toolchain; the backend never guesses register remappings.
    public func bindingLayoutDescriptor(space: UInt32 = 0) throws -> BindingLayoutDescriptor {
        let bindings = interface.bindings.filter { $0.space == space }
        try rhiRequire(Set(bindings.map(\.slot)).count == bindings.count,
                       "reflected resources need distinct RHI binding slots")
        return BindingLayoutDescriptor(entries: bindings.map {
            var entry = BindingLayoutEntry(slot: $0.slot, type: $0.type, visibility: ShaderVisibility(stage))
            entry.buffer = $0.buffer
            return entry
        })
    }
}
