import CYoga

/// Flex layout direction (maps to `YGFlexDirection`).
public enum FlexDirection {
    case row, rowReverse, column, columnReverse

    var ygValue: YGFlexDirection {
        switch self {
        case .row:           return YGFlexDirection.row
        case .rowReverse:    return YGFlexDirection.rowReverse
        case .column:        return YGFlexDirection.column
        case .columnReverse: return YGFlexDirection.columnReverse
        }
    }
}

/// Cross-axis alignment (maps to `YGAlign`).
public enum Align {
    case auto, flexStart, center, flexEnd, stretch, baseline, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGAlign {
        switch self {
        case .auto:         return YGAlign.auto
        case .flexStart:    return YGAlign.flexStart
        case .center:       return YGAlign.center
        case .flexEnd:      return YGAlign.flexEnd
        case .stretch:      return YGAlign.stretch
        case .baseline:     return YGAlign.baseline
        case .spaceBetween: return YGAlign.spaceBetween
        case .spaceAround:  return YGAlign.spaceAround
        case .spaceEvenly:  return YGAlign.spaceEvenly
        }
    }
}

/// Main-axis alignment (maps to `YGJustify`).
public enum Justify {
    case flexStart, center, flexEnd, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGJustify {
        switch self {
        case .flexStart:    return YGJustify.flexStart
        case .center:       return YGJustify.center
        case .flexEnd:      return YGJustify.flexEnd
        case .spaceBetween: return YGJustify.spaceBetween
        case .spaceAround:  return YGJustify.spaceAround
        case .spaceEvenly:  return YGJustify.spaceEvenly
        }
    }
}

/// Box edge selector (maps to `YGEdge`).
public enum Edge {
    case left, top, right, bottom, horizontal, vertical, all

    var ygValue: YGEdge {
        switch self {
        case .left:       return YGEdge.left
        case .top:        return YGEdge.top
        case .right:      return YGEdge.right
        case .bottom:     return YGEdge.bottom
        case .horizontal: return YGEdge.horizontal
        case .vertical:   return YGEdge.vertical
        case .all:        return YGEdge.all
        }
    }
}
