import Foundation

struct SceneLaunch: Codable {
    enum Mode: String, Codable { case counter, gallery, game, application }
    var mode: Mode = .gallery
    var component: String = "introduction"
    var project: String? = nil
}
