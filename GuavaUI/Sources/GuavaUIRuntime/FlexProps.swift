import yoga

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
    case left, top, right, bottom, start, end, horizontal, vertical, all

    var ygValue: YGEdge {
        switch self {
        case .left:       return YGEdge.left
        case .top:        return YGEdge.top
        case .right:      return YGEdge.right
        case .bottom:     return YGEdge.bottom
        case .start:      return YGEdge.start
        case .end:        return YGEdge.end
        case .horizontal: return YGEdge.horizontal
        case .vertical:   return YGEdge.vertical
        case .all:        return YGEdge.all
        }
    }
}

/// Text/layout direction (maps to `YGDirection`).
public enum Direction {
    case inherit, ltr, rtl

    var ygValue: YGDirection {
        switch self {
        case .inherit: return YGDirection.inherit
        case .ltr:     return YGDirection.LTR
        case .rtl:     return YGDirection.RTL
        }
    }
}

/// Position type (maps to `YGPositionType`).
public enum PositionType {
    case `static`, relative, absolute

    var ygValue: YGPositionType {
        switch self {
        case .static:   return YGPositionType.static
        case .relative: return YGPositionType.relative
        case .absolute: return YGPositionType.absolute
        }
    }
}

/// Flex wrap (maps to `YGWrap`).
public enum Wrap {
    case noWrap, wrap, wrapReverse

    var ygValue: YGWrap {
        switch self {
        case .noWrap:      return YGWrap.noWrap
        case .wrap:        return YGWrap.wrap
        case .wrapReverse: return YGWrap.wrapReverse
        }
    }
}

/// Overflow behavior (maps to `YGOverflow`).
public enum Overflow {
    case visible, hidden

    var ygValue: YGOverflow {
        switch self {
        case .visible: return YGOverflow.visible
        case .hidden:  return YGOverflow.hidden
        }
    }
}

/// Display type (maps to `YGDisplay`).
public enum Display {
    case flex, none, contents

    var ygValue: YGDisplay {
        switch self {
        case .flex:     return YGDisplay.flex
        case .none:     return YGDisplay.none
        case .contents: return YGDisplay.contents
        }
    }
}

/// Gutter (gap) axis selector (maps to `YGGutter`).
public enum Gutter {
    case column, row, all

    var ygValue: YGGutter {
        switch self {
        case .column: return YGGutter.column
        case .row:    return YGGutter.row
        case .all:    return YGGutter.all
        }
    }
}

/// Box sizing model (maps to `YGBoxSizing`).
public enum BoxSizing {
    case borderBox, contentBox

    var ygValue: YGBoxSizing {
        switch self {
        case .borderBox:  return YGBoxSizing.borderBox
        case .contentBox: return YGBoxSizing.contentBox
        }
    }
}
