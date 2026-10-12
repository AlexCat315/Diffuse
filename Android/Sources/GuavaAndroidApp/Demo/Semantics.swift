import Foundation
import GuavaUIRuntime

extension DemoScene {
    struct SemanticNode: Codable {
        let id: String
        let role: String
        let label: String
        let value: String
        let bounds: Bounds
        let enabled: Bool
        let selected: Bool
    }
    func semanticNodes() -> [SemanticNode] {
        guard let root = tree.root else { return [] }
        func flatten(_ element: AccessibilityElement) -> [SemanticNode] {
            [.init(id: "\(element.id)", role: element.semantics.role.rawValue,
                   label: element.semantics.label, value: element.semantics.value, bounds: Bounds(element.frame),
                   enabled: element.semantics.state.isEnabled, selected: element.semantics.state.isSelected)] + element.children.flatMap(flatten)
        }
        return AccessibilityTree.snapshot(root: root).flatMap(flatten)
    }
}
