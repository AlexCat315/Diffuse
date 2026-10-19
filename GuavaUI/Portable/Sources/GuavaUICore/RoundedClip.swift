import Foundation

/// A clip for a container's content: the GPU scissor rectangle plus an
/// optional rounded mask applied to geometry on the CPU.
///
/// Scissors are rectangles, so a rounded container would otherwise let a
/// child's square fill poke out of its corners. The mask is usually the
/// container's inner edge (its rectangle inset by the border), so children
/// stay inside the border instead of painting over it.
public struct UIClip: Equatable, Sendable {
    public var rect: UIRect
    public var mask: UIRoundedRect?

    public init(_ rect: UIRect, mask: UIRoundedRect? = nil) {
        self.rect = rect
        self.mask = mask
    }
}

public struct UIRoundedRect: Equatable, Sendable {
    public var rect: UIRect
    public var radius: Float

    public init(_ rect: UIRect, radius: Float) {
        self.rect = rect
        self.radius = max(0, min(radius, min(rect.width, rect.height) / 2))
    }

    /// Whether `bounds` lies where the rounded edge cannot cut it: inside the
    /// rectangle and clear of all four corner squares.
    func contains(_ bounds: UIRect) -> Bool {
        let inside = bounds.minX >= rect.minX && bounds.maxX <= rect.maxX
            && bounds.minY >= rect.minY && bounds.maxY <= rect.maxY
        guard inside else { return false }
        return (bounds.minX >= rect.minX + radius && bounds.maxX <= rect.maxX - radius)
            || (bounds.minY >= rect.minY + radius && bounds.maxY <= rect.maxY - radius)
    }

    /// Whether `bounds` reaches into a corner square, where a cached layer's
    /// clipped geometry would be wrong after moving.
    public func touchesCorner(_ bounds: UIRect) -> Bool {
        guard radius > 0 else { return false }
        let corners = [UIRect(x: rect.minX, y: rect.minY, width: radius, height: radius),
                       UIRect(x: rect.maxX - radius, y: rect.minY, width: radius, height: radius),
                       UIRect(x: rect.minX, y: rect.maxY - radius, width: radius, height: radius),
                       UIRect(x: rect.maxX - radius, y: rect.maxY - radius, width: radius, height: radius)]
        return corners.contains { corner in
            bounds.minX < corner.maxX && bounds.maxX > corner.minX && bounds.minY < corner.maxY && bounds.maxY > corner.minY
        }
    }

    /// Clockwise outline (y down) with `segments` facets per corner.
    func outline(segments: Int) -> [(x: Float, y: Float)] {
        var points: [(x: Float, y: Float)] = []
        let r = radius
        let centers: [(Float, Float)] = [(rect.maxX - r, rect.minY + r), (rect.maxX - r, rect.maxY - r),
                                          (rect.minX + r, rect.maxY - r), (rect.minX + r, rect.minY + r)]
        for (corner, center) in centers.enumerated() {
            let start = -Float.pi / 2 + Float(corner) * .pi / 2
            for step in 0...segments {
                let angle = start + Float(step) / Float(segments) * .pi / 2
                points.append((center.0 + cos(angle) * r, center.1 + sin(angle) * r))
            }
        }
        return points
    }
}

/// Sutherland–Hodgman clipping of one triangle against convex outlines.
/// Position, texture coordinates and color are interpolated linearly, which
/// is exact for the affine triangles a draw list contains.
enum RoundedClipper {
    static func clip(_ triangle: [UIVertex], against outlines: [[(x: Float, y: Float)]]) -> [UIVertex] {
        var polygon = triangle
        for outline in outlines {
            guard polygon.count >= 3 else { return [] }
            for index in outline.indices {
                let a = outline[index], b = outline[(index + 1) % outline.count]
                // Clockwise in y-down screen space: inside is to the right.
                func side(_ v: UIVertex) -> Float { (b.x - a.x) * (v.posY - a.y) - (b.y - a.y) * (v.posX - a.x) }
                var next: [UIVertex] = []
                next.reserveCapacity(polygon.count + 2)
                for (position, current) in polygon.enumerated() {
                    let previous = polygon[(position + polygon.count - 1) % polygon.count]
                    let currentSide = side(current), previousSide = side(previous)
                    if currentSide >= 0 {
                        if previousSide < 0 { next.append(lerp(previous, current, previousSide / (previousSide - currentSide))) }
                        next.append(current)
                    } else if previousSide >= 0 {
                        next.append(lerp(previous, current, previousSide / (previousSide - currentSide)))
                    }
                }
                polygon = next
                if polygon.count < 3 { return [] }
            }
        }
        return polygon
    }

    private static func lerp(_ a: UIVertex, _ b: UIVertex, _ t: Float) -> UIVertex {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Float((a.color >> shift) & 0xFF), y = Float((b.color >> shift) & 0xFF)
            return UInt32(max(0, min(255, (x + (y - x) * t).rounded()))) << shift
        }
        return UIVertex(posX: a.posX + (b.posX - a.posX) * t, posY: a.posY + (b.posY - a.posY) * t,
                        u: a.u + (b.u - a.u) * t, v: a.v + (b.v - a.v) * t,
                        color: channel(0) | channel(8) | channel(16) | channel(24))
    }
}
