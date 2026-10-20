import Foundation
import GuavaUIRuntime

/// Keyboard groups reveal through real scroll containers, whose motion
/// controller owns bounds and bindings. Clipping boxes are not scroll views.
enum ScrollReveal {
    static func reveal(_ target: Node, nearestOnly: Bool = false) {
        target.revealInScrollAncestors(nearestOnly: nearestOnly)
    }

    static func delta(start: CGFloat, end: CGFloat, viewportStart: CGFloat, viewportEnd: CGFloat) -> CGFloat {
        guard viewportEnd > viewportStart else { return 0 }
        if start < viewportStart || end - start > viewportEnd - viewportStart { return start - viewportStart }
        if end > viewportEnd { return end - viewportEnd }
        return 0
    }
}
