public struct SceneDescriptor: Sendable, Hashable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum SceneLoadState: Sendable {
    case idle
    case loading
    case loaded(SceneDescriptor)
    case failed(String)
}

public final class SceneManager {
    public private(set) var current: SceneDescriptor?
    public private(set) var state: SceneLoadState = .idle

    public init() {}

    public func load(scene: SceneDescriptor) {
        state = .loading
        current = scene
        state = .loaded(scene)
    }

    public func unload() {
        current = nil
        state = .idle
    }
}
