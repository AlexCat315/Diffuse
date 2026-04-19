public protocol Renderer {
    func initialize()
    func renderFrame(frameIndex: Int)
}

public struct MetalPlaceholderRenderer: Renderer {
    public init() {}

    public func initialize() {
        print("[RenderBackend] initialize Metal placeholder")
    }

    public func renderFrame(frameIndex: Int) {
        print("[RenderBackend] render frame \(frameIndex)")
    }
}
