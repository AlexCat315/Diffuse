import Foundation

public enum ShaderConstantType: String, Codable, Sendable { case uint32, int32, float32, bool }
public enum ShaderConstantValue: Sendable, Equatable {
    case uint32(UInt32), int32(Int32), float32(Float), bool(Bool)
    public var type: ShaderConstantType {
        switch self { case .uint32: .uint32; case .int32: .int32; case .float32: .float32; case .bool: .bool }
    }
    public var bits: UInt32 {
        switch self {
        case .uint32(let value): value
        case .int32(let value): UInt32(bitPattern: value)
        case .float32(let value): value.bitPattern
        case .bool(let value): value ? 1 : 0
        }
    }
}
public struct ShaderSpecializationConstant: Sendable, Equatable {
    public let id: UInt32
    public let value: ShaderConstantValue
    public init(id: UInt32, value: ShaderConstantValue) { self.id = id; self.value = value }
}
public struct ReflectedShaderConstant: Codable, Sendable {
    public var id: UInt32
    public var name: String
    public var type: ShaderConstantType
    public init(id: UInt32, name: String, type: ShaderConstantType) { self.id = id; self.name = name; self.type = type }
}
/// Links physical workgroup dimensions to reflected constant IDs. A caller
/// specializes once; Metal dispatch and SPIR-V LocalSizeId then agree.
public struct ThreadgroupSpecialization: Codable, Sendable {
    public var x: UInt32?
    public var y: UInt32?
    public var z: UInt32?
    public init(x: UInt32? = nil, y: UInt32? = nil, z: UInt32? = nil) { self.x = x; self.y = y; self.z = z }
    func resolve(defaults: ThreadgroupSize, values: [ShaderSpecializationConstant]) throws -> ThreadgroupSize {
        func dimension(_ id: UInt32?, _ fallback: Int) throws -> Int {
            guard let id, let value = values.first(where: { $0.id == id })?.value else { return fallback }
            switch value {
            case .uint32(let value): return Int(value)
            case .int32(let value): return Int(value)
            default: throw RHIError.invalidArgument("workgroup constant must be an integer")
            }
        }
        let result = try ThreadgroupSize(x: dimension(x,defaults.x),y: dimension(y,defaults.y),z: dimension(z,defaults.z))
        try result.validate(); return result
    }
}
