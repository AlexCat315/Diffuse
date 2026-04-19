public struct AssetPipeline {
    public init() {}

    public func validatePath(_ path: String) -> Bool {
        !path.isEmpty
    }
}
