import Foundation

public extension Node {
    /// Installed by scroll containers: scrolls so a window-space rectangle of
    /// their content is visible. Clipping boxes are not scroll containers.
    var scrollReveal: ((CGRect) -> Void)? {
        get { attachments["__scrollview.reveal"] as? (CGRect) -> Void }
        set { attachments["__scrollview.reveal"] = newValue }
    }

    /// Asks each scroll ancestor, innermost first, to bring this node into view.
    func revealInScrollAncestors(nearestOnly: Bool = false) {
        var ancestor = parent
        while let node = ancestor {
            if let reveal = node.scrollReveal {
                reveal(absoluteFrame)
                if nearestOnly { return }
            }
            ancestor = node.parent
        }
    }
}
