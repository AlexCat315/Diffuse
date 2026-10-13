import Foundation
import GuavaUICompose
import GuavaUIRuntime

extension AndroidContentSession {
    public struct Inspection {
        public let controls: [String: CGRect]
        public let semantics: [AccessibilityElement]
    }

    /// Explicit diagnostic work; input delivery never traverses this snapshot.
    public func inspect() -> Inspection {
        var controls: [String: CGRect] = [:]
        func visit(_ node: Node) {
            if let name = node.attachments[LayoutDebugAttachmentKey.debugName] as? String { controls[name] = node.absoluteFrame }
            for child in node.children { visit(child) }
        }
        if let root = tree.root { visit(root) }
        return Inspection(controls: controls, semantics: tree.root.map { AccessibilityTree.snapshot(root: $0) } ?? [])
    }
}
