// Layout is pluggable so the algorithm is never welded to the core. The engine's
// only contract: given a root and the available size, assign every node a frame
// — by calling `node.setFrame`, which routes through the single invalidation
// funnel. That's what makes "a re-layout silently left a stale hit-test" (the
// legacy dropdown bug) impossible: moving a node during layout invalidates the
// hit cache through exactly the same path as any other geometry change.

public protocol LayoutEngine {
    /// Assign frames to `root` and its subtree to fit `available`.
    func layout(root: UINode, available: Size)
}

/// Built-in flexbox-subset engine for stack layouts (row/column with fixed,
/// percentage and flexible children, padding, spacing, and alignment). Pure
/// Swift, no dependencies. Measure (desired sizes, bottom-up) then arrange
/// (assign frames, top-down).
public struct StackLayoutEngine: LayoutEngine {
    public init() {}

    public func layout(root: UINode, available: Size) {
        let s = root.layoutStyle
        let desired = measure(root, available: available)
        let w = s.width.resolve(available.width) ?? desired.width
        let h = s.height.resolve(available.height) ?? desired.height
        arrange(root, frame: Rect(x: 0, y: 0, width: w, height: h))
    }

    // MARK: - Measure (desired size of a node given available space)

    private func measure(_ node: UINode, available: Size) -> Size {
        let s = node.layoutStyle
        let w = s.width.resolve(available.width)
        let h = s.height.resolve(available.height)
        if let w, let h { return Size(width: w, height: h) }

        // One or both axes are auto → derive from children.
        let inner = Size(width: (w ?? available.width) - s.padding.horizontal,
                         height: (h ?? available.height) - s.padding.vertical)
        let content = measureChildren(node, available: inner)
        return Size(width: w ?? content.width + s.padding.horizontal,
                    height: h ?? content.height + s.padding.vertical)
    }

    private func measureChildren(_ node: UINode, available: Size) -> Size {
        let s = node.layoutStyle
        let flow = node.children.filter { if case .flow = $0.layoutStyle.position { return true }; return false }
        guard !flow.isEmpty else { return .zero }
        var mainTotal: Float = 0
        var crossMax: Float = 0
        for (i, child) in flow.enumerated() {
            let cs = measure(child, available: available)
            let p = project(cs, s.direction)
            mainTotal += p.main
            if i < flow.count - 1 { mainTotal += s.spacing }
            crossMax = max(crossMax, p.cross)
        }
        return unproject(main: mainTotal, cross: crossMax, axis: s.direction)
    }

    // MARK: - Arrange (assign frames, parent-local)

    private func arrange(_ node: UINode, frame: Rect) {
        node.setFrame(frame) // ← single funnel: also invalidates geometry/hit cache

        let s = node.layoutStyle

        // Absolutely-positioned children are placed at their rect and excluded
        // from the flow math (used by overlays/portals).
        for child in node.children {
            if case .absolute(let rect) = child.layoutStyle.position {
                arrange(child, frame: rect)
            }
        }
        let kids = node.children.filter { if case .flow = $0.layoutStyle.position { return true }; return false }
        guard !kids.isEmpty else { return }

        let contentMain = project(frame.size, s.direction).main - paddingMain(s)
        let contentCross = project(frame.size, s.direction).cross - paddingCross(s)
        let availForKids = unproject(main: contentMain, cross: contentCross, axis: s.direction)

        // Base main sizes (measured) + flex growth.
        var mains = [Float](repeating: 0, count: kids.count)
        var crosses = [Float](repeating: 0, count: kids.count)
        var totalGrow: Float = 0
        for (i, child) in kids.enumerated() {
            let p = project(measure(child, available: availForKids), s.direction)
            mains[i] = p.main
            crosses[i] = p.cross
            totalGrow += child.layoutStyle.flexGrow
        }
        let used = mains.reduce(0, +) + s.spacing * Float(kids.count - 1)
        let leftover = contentMain - used
        if totalGrow > 0 && leftover > 0 {
            for i in kids.indices {
                mains[i] += leftover * (kids[i].layoutStyle.flexGrow / totalGrow)
            }
        }

        // Main-axis distribution.
        let consumed = mains.reduce(0, +) + s.spacing * Float(kids.count - 1)
        let free = max(0, contentMain - consumed)
        let (startPad, gap) = distribute(s.justifyContent, free: free, count: kids.count, spacing: s.spacing)
        var cursor = paddingMainStart(s) + startPad

        for i in kids.indices {
            let child = kids[i]
            let stretch = (s.alignItems == .stretch && crossDimension(child.layoutStyle, s.direction) == .auto)
            let childCross = stretch ? contentCross : min(crosses[i], contentCross)
            let crossPad = paddingCrossStart(s) + alignOffset(s.alignItems, free: contentCross - childCross)
            let childFrame = makeRect(mainOrigin: cursor, crossOrigin: crossPad,
                                      main: mains[i], cross: childCross, axis: s.direction)
            arrange(child, frame: childFrame)
            cursor += mains[i] + gap
        }
    }

    // MARK: - Main/cross projection helpers (handle row & column uniformly)

    private func project(_ size: Size, _ axis: Axis) -> (main: Float, cross: Float) {
        axis == .column ? (size.height, size.width) : (size.width, size.height)
    }
    private func unproject(main: Float, cross: Float, axis: Axis) -> Size {
        axis == .column ? Size(width: cross, height: main) : Size(width: main, height: cross)
    }
    private func makeRect(mainOrigin: Float, crossOrigin: Float, main: Float, cross: Float, axis: Axis) -> Rect {
        axis == .column
            ? Rect(x: crossOrigin, y: mainOrigin, width: cross, height: main)
            : Rect(x: mainOrigin, y: crossOrigin, width: main, height: cross)
    }
    private func paddingMainStart(_ s: LayoutStyle) -> Float { s.direction == .column ? s.padding.top : s.padding.left }
    private func paddingCrossStart(_ s: LayoutStyle) -> Float { s.direction == .column ? s.padding.left : s.padding.top }
    private func paddingMain(_ s: LayoutStyle) -> Float { s.direction == .column ? s.padding.vertical : s.padding.horizontal }
    private func paddingCross(_ s: LayoutStyle) -> Float { s.direction == .column ? s.padding.horizontal : s.padding.vertical }
    private func crossDimension(_ s: LayoutStyle, _ parentAxis: Axis) -> Dimension {
        parentAxis == .column ? s.width : s.height
    }

    private func alignOffset(_ align: CrossAlign, free: Float) -> Float {
        switch align {
        case .start, .stretch: return 0
        case .center:          return max(0, free) / 2
        case .end:             return max(0, free)
        }
    }
    private func distribute(_ align: MainAlign, free: Float, count: Int, spacing: Float)
        -> (start: Float, gap: Float) {
        switch align {
        case .start:        return (0, spacing)
        case .center:       return (free / 2, spacing)
        case .end:          return (free, spacing)
        case .spaceBetween: return count > 1 ? (0, spacing + free / Float(count - 1)) : (0, spacing)
        }
    }
}
