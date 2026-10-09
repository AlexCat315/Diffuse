import Foundation
import GuavaUIRuntime

public enum PortalPlacementMode: Sendable, Equatable {
    case belowAnchor
    case besideAnchor
}

public enum PortalPlacement {
    public static func fit(position: CGPoint, size: CGSize, in window: CGRect,
                           anchor: CGRect? = nil, margin: CGFloat = 6,
                           placement: PortalPlacementMode = .belowAnchor) -> CGRect {
        let bounds = window.insetBy(dx: min(margin, window.width / 2), dy: min(margin, window.height / 2))
        let width = min(max(0, size.width), max(0, bounds.width))
        let height = min(max(0, size.height), max(0, bounds.height))
        var x = position.x
        var y = position.y
        if placement == .besideAnchor, let anchor, x + width > bounds.maxX {
            let leftSpace = anchor.minX - bounds.minX
            let rightSpace = bounds.maxX - anchor.maxX
            if leftSpace >= width || leftSpace > rightSpace { x = anchor.minX - width }
        }
        x = max(bounds.minX, min(x, bounds.maxX - width))
        if placement == .belowAnchor, y + height > bounds.maxY, let anchor, anchor.minY - height >= bounds.minY {
            y = anchor.minY - height
        }
        y = max(bounds.minY, min(y, bounds.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

func portalWindowBounds(_ node: Node) -> CGRect {
    var root = node
    while let parent = root.parent { root = parent }
    return CGRect(x: 0, y: 0, width: root.frame.width > 0 ? root.frame.width : CGFloat(root.layoutNode?.width ?? 1024),
                  height: root.frame.height > 0 ? root.frame.height : CGFloat(root.layoutNode?.height ?? 768))
}
