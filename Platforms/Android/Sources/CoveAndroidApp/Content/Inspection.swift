import Foundation
import CoveUIRuntime

struct TypographyStatistics: Codable {
    var fonts = 0
    var glyphs = 0
    var missingGlyphs = 0
    var atlasPixels = 0
}

extension HostedScene {
    struct SemanticNode: Codable {
        let id: String
        let role: String
        let label: String
        let value: String
        let bounds: Bounds
        let enabled: Bool
        let selected: Bool
    }
    func semanticNodes(_ elements: [AccessibilityElement]) -> [SemanticNode] {
        func flatten(_ element: AccessibilityElement) -> [SemanticNode] {
            [.init(id: "\(element.id)", role: element.semantics.role.rawValue,
                   label: element.semantics.label, value: element.semantics.value, bounds: Bounds(element.frame),
                   enabled: element.semantics.state.isEnabled, selected: element.semantics.state.isSelected)] + element.children.flatMap(flatten)
        }
        return elements.flatMap(flatten)
    }
}
