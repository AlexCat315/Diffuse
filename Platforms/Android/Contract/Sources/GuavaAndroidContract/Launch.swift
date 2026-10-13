/// Authored launch content shared by the APK producer and native consumer.
/// Transient benchmark, timing, input and display state never enter this document.
public struct SceneLaunch: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case counter, gallery, game, application }
    public var mode = Mode.gallery
    public var component = "introduction"
    public var project: String? = nil

    public init(mode: Mode = .gallery, component: String = "introduction", project: String? = nil) {
        self.mode = mode
        self.component = component
        self.project = project
    }
}
