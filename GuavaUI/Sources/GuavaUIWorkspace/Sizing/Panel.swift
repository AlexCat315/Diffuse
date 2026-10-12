import Foundation

/// Logical content points, excluding workspace chrome. Preferred is an initial
/// size hint; a saved user split takes precedence. Invalid authored values are
/// normalized at construction and decoding, before reaching the layout engine.
public struct WorkspaceAxisSizing: Sendable, Codable, Equatable {
    public let minimum: Float
    public let preferred: Float?
    public let maximum: Float?

    public init(minimum: Float = 0, preferred: Float? = nil, maximum: Float? = nil) {
        let minimum = minimum.isFinite ? max(0, minimum) : 0
        let maximum = maximum.flatMap { $0.isFinite ? max(minimum, $0) : nil }
        self.minimum = minimum
        self.maximum = maximum
        self.preferred = preferred.flatMap {
            $0.isFinite ? max(minimum, min(maximum ?? .greatestFiniteMagnitude, $0)) : nil
        }
    }

    private enum CodingKeys: String, CodingKey { case minimum, preferred, maximum }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimum: try values.decodeIfPresent(Float.self, forKey: .minimum) ?? 0,
                  preferred: try values.decodeIfPresent(Float.self, forKey: .preferred),
                  maximum: try values.decodeIfPresent(Float.self, forKey: .maximum))
    }
}

/// Width and height constraints belong to the panel and follow it when it is
/// moved, grouped or floated. They contain no measured viewport/session state.
public struct WorkspacePanelSizing: Sendable, Codable, Equatable {
    public var width = WorkspaceAxisSizing()
    public var height = WorkspaceAxisSizing()

    public init(width: WorkspaceAxisSizing = .init(), height: WorkspaceAxisSizing = .init()) {
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(WorkspaceAxisSizing.self, forKey: .width) ?? .init()
        height = try values.decodeIfPresent(WorkspaceAxisSizing.self, forKey: .height) ?? .init()
    }
}
