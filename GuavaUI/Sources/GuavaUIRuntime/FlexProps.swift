import CYoga

/// Flex layout direction (maps to `YGFlexDirection`).
public enum FlexDirection {
    case row, rowReverse, column, columnReverse

    var ygValue: YGFlexDirection {
        switch self {
        case .row:           return .row
        case .rowReverse:    return .rowReverse
        case .column:        return .column
        case .columnReverse: return .columnReverse
        }
    }
}

/// Cross-axis alignment (maps to `YGAlign`).
public enum Align {
    case auto, flexStart, center, flexEnd, stretch, baseline, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGAlign {
        switch self {
        case .auto:         return .auto
        case .flexStart:    return .flexStart
        case .center:       return .center
        case .flexEnd:      return .flexEnd
        case .stretch:      return .stretch
        case .baseline:     return .baseline
        case .spaceBetween: return .spaceBetween
        case .spaceAround:  return .spaceAround
        case .spaceEvenly:  return .spaceEvenly
        }
    }
}

/// Main-axis alignment (maps to `YGJustify`).
public enum Justify {
    case flexStart, center, flexEnd, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGJustify {
        switch self {
        case .flexStart:    return .flexStart
        case .center:       return .center
        case .flexEnd:      return .flexEnd
        case .spaceBetween: return .spaceBetween
        case .spaceAround:  return .spaceAround
        case .spaceEvenly:  return .spaceEvenly
        }
    }
}

/// Box edge selector (maps to `YGEdge`).
public enum Edge {
    case left, top, right, bottom, start, end, horizontal, vertical, all

    var ygValue: YGEdge {
        switch self {
        case .left:       return .left
        case .top:        return .top
        case .right:      return .right
        case .bottom:     return .bottom
        case .start:      return .start
        case .end:        return .end
        case .horizontal: return .horizontal
        case .vertical:   return .vertical
        case .all:        return .all
        }
    }
}

/// Text/layout direction (maps to `YGDirection`).
public enum Direction {
    case inherit, ltr, rtl

    var ygValue: YGDirection {
        switch self {
        case .inherit: return .inherit
        case .ltr:     return .LTR
        case .rtl:     return .RTL
        }
    }
}

/// Position type (maps to `YGPositionType`).
public enum PositionType {
    case `static`, relative, absolute

    var ygValue: YGPositionType {
        switch self {
        case .static:   return .`static`
        case .relative: return .relative
        case .absolute: return .absolute
        }
    }
}

/// Flex wrap (maps to `YGWrap`).
public enum Wrap {
    case noWrap, wrap, wrapReverse

    var ygValue: YGWrap {
        switch self {
        case .noWrap:      return .noWrap
        case .wrap:        return .wrap
        case .wrapReverse: return .wrapReverse
        }
    }
}

/// Overflow behavior (maps to `YGOverflow`).
public enum Overflow {
    case visible, hidden

    var ygValue: YGOverflow {
        switch self {
        case .visible: return .visible
        case .hidden:  return .hidden
        }
    }
}

/// Display type (maps to `YGDisplay`).
public enum Display {
    case flex, none, contents

    var ygValue: YGDisplay {
        switch self {
        case .flex:     return .flex
        case .none:     return .none
        case .contents: return .contents
        }
    }
}

/// Gutter (gap) axis selector (maps to `YGGutter`).
public enum Gutter {
    case column, row, all

    var ygValue: YGGutter {
        switch self {
        case .column: return .column
        case .row:    return .row
        case .all:    return .all
        }
    }
}

/// Box sizing model (maps to `YGBoxSizing`).
public enum BoxSizing {
    case borderBox, contentBox

    var ygValue: YGBoxSizing {
        switch self {
        case .borderBox:  return .borderBox
        case .contentBox: return .contentBox
        }
    }
}
