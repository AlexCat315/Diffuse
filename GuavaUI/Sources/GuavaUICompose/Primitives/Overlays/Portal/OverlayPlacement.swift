#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

public enum OverlayPlacement {
    public static func fit(_ position: CGPoint, size: CGSize, in bounds: CGRect,
                           anchor: CGRect? = nil, margin: CGFloat = 4) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return position }
        let minX = bounds.minX + margin
        let minY = bounds.minY + margin
        let maxX = max(minX, bounds.maxX - margin - size.width)
        let maxY = max(minY, bounds.maxY - margin - size.height)
        var y = position.y
        if y + size.height > bounds.maxY - margin, let anchor,
           anchor.minY - size.height >= minY {
            y = anchor.minY - size.height
        }
        return CGPoint(x: min(maxX, max(minX, position.x)), y: min(maxY, max(minY, y)))
    }
}
