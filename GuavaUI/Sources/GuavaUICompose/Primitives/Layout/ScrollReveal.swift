import Foundation
import GuavaUIRuntime

/// Keyboard groups reveal through real scroll containers, whose motion
/// controller owns bounds and bindings. Clipping boxes are not scroll views.
enum ScrollReveal {
    static let handlerKey = "__scrollview.reveal"

    static func reveal(_ target: Node, nearestOnly: Bool = false) {
        var ancestor = target.parent
        while let node = ancestor {
            if let reveal = node.attachments[handlerKey] as? (CGRect) -> Void {
                reveal(target.absoluteFrame)
                if nearestOnly { return }
            }
            ancestor = node.parent
        }
    }

    static func delta(start: CGFloat, end: CGFloat, viewportStart: CGFloat, viewportEnd: CGFloat) -> CGFloat {
        guard viewportEnd > viewportStart else { return 0 }
        if start < viewportStart || end - start > viewportEnd - viewportStart { return start - viewportStart }
        if end > viewportEnd { return end - viewportEnd }
        return 0
    }
}
