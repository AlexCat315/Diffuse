import Foundation

#if os(Windows) || os(Linux)
extension CGRect {
    public var isNull: Bool {
        origin.x.isInfinite || origin.y.isInfinite
    }

    public func intersection(_ other: CGRect) -> CGRect {
        if isNull || other.isNull { return .null }
        let x1 = Swift.max(minX, other.minX)
        let y1 = Swift.max(minY, other.minY)
        let x2 = Swift.min(maxX, other.maxX)
        let y2 = Swift.min(maxY, other.maxY)
        guard x2 >= x1, y2 >= y1 else { return .null }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    public func union(_ other: CGRect) -> CGRect {
        if isNull { return other }
        if other.isNull { return self }
        let x1 = Swift.min(minX, other.minX)
        let y1 = Swift.min(minY, other.minY)
        let x2 = Swift.max(maxX, other.maxX)
        let y2 = Swift.max(maxY, other.maxY)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        guard !isNull else { return self }
        return CGRect(x: minX + dx,
                      y: minY + dy,
                      width: width - dx * 2,
                      height: height - dy * 2)
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        guard !isNull else { return self }
        return CGRect(origin: CGPoint(x: origin.x + dx, y: origin.y + dy),
                      size: size)
    }
}
#endif
