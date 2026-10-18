internal import Foundation

/// The edge and alignment of the bubble relative to its trigger. Leading and
/// trailing follow layout direction. Explicit sides are retained by default.
public enum PopoverPlacement: Sendable, Equatable, CaseIterable {
  case topLeading, top, topTrailing
  case leadingTop, leading, leadingBottom
  case trailingTop, trailing, trailingBottom
  case bottomLeading, bottom, bottomTrailing

  var edge: PopoverEdge {
    switch self {
    case .topLeading, .top, .topTrailing: .top
    case .bottomLeading, .bottom, .bottomTrailing: .bottom
    case .leadingTop, .leading, .leadingBottom: .left
    case .trailingTop, .trailing, .trailingBottom: .right
    }
  }
  var alignment: Int {
    switch self {
    case .topLeading, .bottomLeading, .leadingTop, .trailingTop: -1
    case .topTrailing, .bottomTrailing, .leadingBottom, .trailingBottom: 1
    default: 0
    }
  }
}

public enum PopoverOverflow: Sendable, Equatable {
  /// Keep the requested side and scroll content within its available space.
  case constrain
  /// Allow adaptive menus to use the opposite side when the panel fits there.
  case flip
}

public enum PopoverSurface: Sendable, Equatable {
  /// A shared opaque card with a pointer, border and shadow.
  case bubble
  /// The content already owns its surface, as menus and pickers do.
  case content
}

enum PopoverEdge {
  case top, bottom, left, right
  var opposite: Self {
    switch self { case .top: .bottom; case .bottom: .top; case .left: .right; case .right: .left }
  }
  var isVertical: Bool { self == .top || self == .bottom }
}

struct PopoverGeometry {
  static let margin: CGFloat = 8
  static let gap: CGFloat = 4
  static let inset: CGFloat = 10
  let frame: CGRect
  let edge: PopoverEdge
  let maximumSize: CGSize

  init(anchor: CGRect, size proposed: CGSize, window: CGRect, placement: PopoverPlacement, rtl: Bool,
       overflow: PopoverOverflow = .constrain, margin: CGFloat = Self.margin, gap: CGFloat = Self.gap) {
    let bounds = window.insetBy(dx: min(margin, window.width / 2), dy: min(margin, window.height / 2))
    var size = CGSize(width: min(proposed.width, max(0, bounds.width)), height: min(proposed.height, max(0, bounds.height)))
    var edge = placement.edge
    if rtl && !edge.isVertical { edge = edge.opposite }
    func space(_ edge: PopoverEdge) -> CGFloat {
      switch edge {
      case .top: anchor.minY - bounds.minY - gap
      case .bottom: bounds.maxY - anchor.maxY - gap
      case .left: anchor.minX - bounds.minX - gap
      case .right: bounds.maxX - anchor.maxX - gap
      }
    }
    let required = edge.isVertical ? size.height : size.width
    if overflow == .flip, space(edge) < required && space(edge.opposite) >= required { edge = edge.opposite }
    self.edge = edge
    maximumSize = CGSize(width: !edge.isVertical && overflow == .constrain ? max(0, space(edge)) : max(0, bounds.width),
                         height: edge.isVertical && overflow == .constrain ? max(0, space(edge)) : max(0, bounds.height))
    size.width = min(size.width, maximumSize.width); size.height = min(size.height, maximumSize.height)
    var alignment = placement.alignment
    if edge.isVertical && rtl { alignment = -alignment }
    func aligned(_ minimum: CGFloat, _ maximum: CGFloat, extent: CGFloat) -> CGFloat {
      alignment < 0 ? minimum : alignment > 0 ? maximum - extent : (minimum + maximum - extent) / 2
    }
    let x: CGFloat, y: CGFloat
    if edge.isVertical {
      x = aligned(anchor.minX, anchor.maxX, extent: size.width)
      y = edge == .top ? anchor.minY - gap - size.height : anchor.maxY + gap
    } else {
      x = edge == .left ? anchor.minX - gap - size.width : anchor.maxX + gap
      y = aligned(anchor.minY, anchor.maxY, extent: size.height)
    }
    frame = CGRect(x: max(bounds.minX, min(x, bounds.maxX - size.width)),
                   y: max(bounds.minY, min(y, bounds.maxY - size.height)), width: size.width, height: size.height)
  }
}
