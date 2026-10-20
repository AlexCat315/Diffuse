import Foundation
import GuavaUIRuntime

/// Presence shown as a corner indicator on an `Avatar`. Each case pairs a hue
/// with a distinct shape (filled, inset ring, bar, hollow ring) so presence
/// stays readable without color.
public enum AvatarStatus: Sendable, Hashable, CaseIterable {
    case online, away, busy, offline

    /// Default spoken/visible name; `AvatarAppearance.statusLabel` overrides it.
    public var label: String {
        switch self {
        case .online: "Online"
        case .away: "Away"
        case .busy: "Busy"
        case .offline: "Offline"
        }
    }

    var color: SemanticColorRef {
        switch self {
        case .online: .success
        case .away: .warning
        case .busy: .error
        case .offline: .onSurfaceMuted
        }
    }
}

/// Status geometry relative to the avatar's own diameter and shape. Circles
/// put the indicator center on the outline at 45°; square corners tuck it
/// slightly inside so it never floats free of the shape.
struct AvatarStatusGeometry: Equatable {
    let size: Float
    let inset: Float
    init(diameter: Float, shape: AvatarShape) {
        size = max(6, min(24, (diameter * 0.28).rounded()))
        let radius = shape.radius(for: diameter)
        // Distance from the bounding corner to the outline along the diagonal.
        let cornerGap = radius * (1 - 0.70710678)
        inset = cornerGap - size / 2
    }
}

/// Logical bottom-trailing indicator. Uses the `.end` edge, so RTL mirrors it
/// to the bottom-left with no caller involvement.
struct AvatarStatusIndicator: _PrimitiveView {
    let status: AvatarStatus
    let geometry: AvatarStatusGeometry
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); _updateLayout(layout); return layout }
    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(geometry.inset, edge: .end); layout.setPosition(geometry.inset, edge: .bottom)
        layout.width = geometry.size; layout.height = geometry.size
    }
    func _updateNode(_ node: Node) {
        node.attachments["avatar.status"] = status
        node.zIndex = 1
        let theme = node.theme
        let ring = theme.colors.surface, ink = status.color.resolve(theme), size = geometry.size, status = status
        node.updateDraw(identity: AvatarStatusPaint(ring: ring, ink: ink, size: size, status: status)) { list, origin in
            let x = Float(origin.x), y = Float(origin.y)
            let outer = UIRect(x: x, y: y, width: size, height: size)
            list.addRoundedRect(outer, radius: size / 2, color: ring)
            let ringWidth = max(1.5, size * 0.16)
            let inner = UIRect(x: x + ringWidth, y: y + ringWidth, width: size - ringWidth * 2, height: size - ringWidth * 2)
            switch status {
            case .online:
                list.addRoundedRect(inner, radius: inner.width / 2, color: ink)
            case .away:
                list.addRoundedRect(inner, radius: inner.width / 2, color: ink)
                let dot = inner.width * 0.42
                list.addRoundedRect(UIRect(x: inner.x + inner.width * 0.12, y: inner.y + inner.height * 0.12,
                                           width: dot, height: dot), radius: dot / 2, color: ring)
            case .busy:
                list.addRoundedRect(inner, radius: inner.width / 2, color: ink)
                let bar = max(1, inner.height * 0.22)
                list.addRoundedRect(UIRect(x: inner.x + inner.width * 0.22, y: inner.y + inner.height / 2 - bar / 2,
                                           width: inner.width * 0.56, height: bar), radius: bar / 2, color: ring)
            case .offline:
                list.addRoundedRectStroke(inner, radius: inner.width / 2, width: max(1.25, inner.width * 0.24), color: ink)
            }
        }
    }
    var _children: [any View] { [] }
}

private struct AvatarStatusPaint: Equatable {
    let ring: Color
    let ink: Color
    let size: Float
    let status: AvatarStatus
}
