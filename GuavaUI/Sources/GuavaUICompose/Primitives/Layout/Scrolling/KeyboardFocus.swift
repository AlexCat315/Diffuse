private import GuavaUIRuntime

/// Read-only scrolling content needs a keyboard entrance. Interactive content
/// already provides one; an extra ancestor stop would steal modal/menu focus.
enum ScrollKeyboardFocus {
    static func update(_ node: Node, canScroll: Bool) {
        let hasViewport = canScroll && node.frame.width > 0.5 && node.frame.height > 0.5
        var hasControl = false
        if hasViewport {
            var pending = node.children
            while let child = pending.popLast() {
                guard child.acceptsSubtreeInput else { continue }
                if child.isFocusable && child.isTabStop { hasControl = true; break }
                pending.append(contentsOf: child.children)
            }
        }
        node.isFocusable = hasViewport && !hasControl
        if !node.isFocusable, FocusChainHolder.current?.focused === node {
            FocusChainHolder.current?.clear()
        }
    }
}
