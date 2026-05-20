import yoga

/// Flex layout direction (maps to `YGFlexDirection`).
public enum FlexDirection {
    case row, rowReverse, column, columnReverse

    var ygValue: YGFlexDirection {
        switch self {
        case .row:           return YGFlexDirectionRow
        case .rowReverse:    return YGFlexDirectionRowReverse
        case .column:        return YGFlexDirectionColumn
        case .columnReverse: return YGFlexDirectionColumnReverse
        }
    }
}

/// Cross-axis alignment (maps to `YGAlign`).
public enum Align {
    case auto, flexStart, center, flexEnd, stretch, baseline, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGAlign {
        switch self {
        case .auto:         return YGAlignAuto
        case .flexStart:    return YGAlignFlexStart
        case .center:       return YGAlignCenter
        case .flexEnd:      return YGAlignFlexEnd
        case .stretch:      return YGAlignStretch
        case .baseline:     return YGAlignBaseline
        case .spaceBetween: return YGAlignSpaceBetween
        case .spaceAround:  return YGAlignSpaceAround
        case .spaceEvenly:  return YGAlignSpaceEvenly
        }
    }
}

/// Main-axis alignment (maps to `YGJustify`).
public enum Justify {
    case flexStart, center, flexEnd, spaceBetween, spaceAround, spaceEvenly

    var ygValue: YGJustify {
        switch self {
        case .flexStart:    return YGJustifyFlexStart
        case .center:       return YGJustifyCenter
        case .flexEnd:      return YGJustifyFlexEnd
        case .spaceBetween: return YGJustifySpaceBetween
        case .spaceAround:  return YGJustifySpaceAround
        case .spaceEvenly:  return YGJustifySpaceEvenly
        }
    }
}

/// Box edge selector (maps to `YGEdge`).
public enum Edge {
    case left, top, right, bottom, start, end, horizontal, vertical, all

    var ygValue: YGEdge {
        switch self {
        case .left:       return YGEdgeLeft
        case .top:        return YGEdgeTop
        case .right:      return YGEdgeRight
        case .bottom:     return YGEdgeBottom
        case .start:      return YGEdgeStart
        case .end:        return YGEdgeEnd
        case .horizontal: return YGEdgeHorizontal
        case .vertical:   return YGEdgeVertical
        case .all:        return YGEdgeAll
        }
    }
}

/// Text/layout direction (maps to `YGDirection`).
public enum Direction {
    case inherit, ltr, rtl

    var ygValue: YGDirection {
        switch self {
        case .inherit: return YGDirectionInherit
        case .ltr:     return YGDirectionLTR
        case .rtl:     return YGDirectionRTL
        }
    }
}

/// Position type (maps to `YGPositionType`).
public enum PositionType {
    case `static`, relative, absolute

    var ygValue: YGPositionType {
        switch self {
        case .static:   return YGPositionTypeStatic
        case .relative: return YGPositionTypeRelative
        case .absolute: return YGPositionTypeAbsolute
        }
    }
}

/// Flex wrap (maps to `YGWrap`).
public enum Wrap {
    case noWrap, wrap, wrapReverse

    var ygValue: YGWrap {
        switch self {
        case .noWrap:      return YGWrapNoWrap
        case .wrap:        return YGWrapWrap
        case .wrapReverse: return YGWrapWrapReverse
        }
    }
}

/// Overflow behavior (maps to `YGOverflow`).
public enum Overflow {
    case visible, hidden

    var ygValue: YGOverflow {
        switch self {
        case .visible: return YGOverflowVisible
        case .hidden:  return YGOverflowHidden
        }
    }
}

/// Display type (maps to `YGDisplay`).
public enum Display {
    case flex, none, contents

    var ygValue: YGDisplay {
        switch self {
        case .flex:     return YGDisplayFlex
        case .none:     return YGDisplayNone
        case .contents: return YGDisplayContents
        }
    }
}

/// Gutter (gap) axis selector (maps to `YGGutter`).
public enum Gutter {
    case column, row, all

    var ygValue: YGGutter {
        switch self {
        case .column: return YGGutterColumn
        case .row:    return YGGutterRow
        case .all:    return YGGutterAll
        }
    }
}

/// Box sizing model (maps to `YGBoxSizing`).
public enum BoxSizing {
    case borderBox, contentBox

    var ygValue: YGBoxSizing {
        switch self {
        case .borderBox:  return YGBoxSizingBorderBox
        case .contentBox: return YGBoxSizingContentBox
        }
    }
}
