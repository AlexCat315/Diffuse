/// Resource visibility may span several shader stages; a module still has one stage.
public struct ShaderVisibility: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let vertex = ShaderVisibility(rawValue: 1 << 0)
    public static let fragment = ShaderVisibility(rawValue: 1 << 1)
    public static let compute = ShaderVisibility(rawValue: 1 << 2)
    public static let task = ShaderVisibility(rawValue: 1 << 3)
    public static let mesh = ShaderVisibility(rawValue: 1 << 4)
    public static let graphics: ShaderVisibility = [.vertex, .fragment]
    public static let all: ShaderVisibility = [.graphics, .compute, .task, .mesh]
    public init(_ stage: ShaderStage) {
        switch stage { case .vertex: self = .vertex; case .fragment: self = .fragment; case .compute: self = .compute; case .task: self = .task; case .mesh: self = .mesh }
    }
    var stages: [ShaderStage] { [ShaderStage.vertex, .fragment, .compute, .task, .mesh].filter { contains(ShaderVisibility($0)) } }
}
