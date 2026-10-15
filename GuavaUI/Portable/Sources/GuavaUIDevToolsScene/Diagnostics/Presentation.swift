private import Foundation
import GuavaUIScene
import GuavaUIDevToolsProtocol

/// Current presentation, separate from authored node flags. Visible bounds
/// include ancestor clipping and scroll offsets; input includes ancestors and
/// the owning scene's active modal scope, including its accessory portals.
public struct UIDiagnosticPresentation: Codable, Sendable {
    public let isVisible: Bool
    public let inputEnabled: Bool
    public let visibleFrame: NodeFrame?

    static func capture(root: Node) -> [String: Self] {
        var result: [String: Self] = [:]
        func modalInput(in node: Node) -> FocusChain? {
            // A linear walk avoids lazy recursive compactMap/first repeatedly
            // evaluating the same deep composition subtrees.
            var pending = [node]
            while let candidate = pending.popLast() {
                if let chain = candidate.firstResource(ModalFocusResource.self)?.boundFocusChain, chain.hasModalScope {
                    return chain
                }
                pending.append(contentsOf: candidate.children.reversed())
            }
            return nil
        }
        let inputScope = modalInput(in: root)
        func visit(_ node: Node, clip: CGRect?, draws: Bool, input: Bool) -> CGRect? {
            let draws = draws && node.opacity > 0 && node.subtreeOpacity > 0
            let input = input && node.allowsHitTesting && node.isInteractionEnabled
                && node.accessibility?.state.isEnabled != false
            let bounds = node.absoluteFrame
            var own: CGRect?
            if draws, bounds.width > 0, bounds.height > 0 {
                let visible = clip.map { $0.intersection(bounds) } ?? bounds
                if !visible.isEmpty { own = visible }
            }
            let childClip = node.clipsToBounds ? (clip.map { $0.intersection(bounds) } ?? bounds) : clip
            var descendants: CGRect?
            for child in node.children {
                if let frame = visit(child, clip: childClip, draws: draws, input: input) {
                    descendants = descendants.map { $0.union(frame) } ?? frame
                }
            }
            // Layout-transparent component anchors inherit their visible
            // descendants without fabricating an independent hit-test box.
            let visible = node.layoutNode == nil && bounds.isEmpty ? descendants : own
            result[String(node.id.rawValue)] = Self(isVisible: visible != nil,
                inputEnabled: input && visible != nil && (inputScope?.permitsInput(node) ?? true),
                visibleFrame: visible.map { NodeFrame(x: Double($0.minX), y: Double($0.minY),
                    w: Double($0.width), h: Double($0.height)) })
            if let own { return descendants.map { own.union($0) } ?? own }
            return descendants
        }
        let frame = root.absoluteFrame
        _ = visit(root, clip: frame.isEmpty ? nil : frame, draws: true, input: true)
        return result
    }
}
