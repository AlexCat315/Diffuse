import Foundation

package enum WindowRevealContext {
    private static let activationKey = "GuavaUI.control.activation-origin"

    package static func recordActivation(_ node: Node) {
        let frame = node.absoluteFrame
        root(of: node).attachments[activationKey] = CGPoint(x: frame.midX, y: frame.midY)
    }

    package static func activationOrigin(for node: Node) -> CGPoint? {
        root(of: node).attachments[activationKey] as? CGPoint
    }

    package static func clearActivation(in node: Node?) {
        node?.attachments.removeValue(forKey: activationKey)
    }

    package static func bounds(for node: Node) -> CGRect { root(of: node).frame }

    private static func root(of node: Node) -> Node {
        var root = node
        while let parent = root.parent { root = parent }
        return root
    }
}
