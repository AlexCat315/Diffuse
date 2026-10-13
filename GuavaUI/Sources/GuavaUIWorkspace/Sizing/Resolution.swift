import GuavaUICompose
import GuavaUIRuntime

struct WorkspaceLayoutMetrics {
    var tabHeight: Float = 34
    /// Canvas two cards share between them: the divider hairline and nothing
    /// else. The grab area around it overhangs, so it costs no extra space.
    var divider: Float = 1

    init(theme: WorkspaceTheme = .init(), scaler: TextScaler = .identity) {
        tabHeight = max(26, scaler.scale(theme.tabBarHeight))
        divider = max(1, theme.splitDividerThickness)
    }
}

/// Linear in the layout tree. All panels in a tab group participate so changing
/// the active tab never jumps a divider or loses a hidden panel's size contract.
struct WorkspaceSizingResolver {
    let document: WorkspaceDocument
    var metrics = WorkspaceLayoutMetrics()

    func group(_ groupID: WorkspaceTabGroupID, axis: WorkspaceSplitAxis) -> WorkspaceAxisSizing {
        let panels = document.groups[groupID]?.panels.compactMap { document.panels[$0] } ?? []
        let sizes = panels.map { axis == .horizontal ? $0.sizing.width : $0.sizing.height }
        let chrome: Float = axis == .vertical ? metrics.tabHeight : 0
        let minimum = (sizes.map(\.minimum).max() ?? 0) + chrome
        let preferred = sizes.compactMap(\.preferred).max().map { $0 + chrome }
        let maximum = sizes.compactMap(\.maximum).min().map { $0 + chrome }
        return WorkspaceAxisSizing(minimum: minimum, preferred: preferred, maximum: maximum)
    }

    func slot(_ slotID: WorkspaceSlotID, axis: WorkspaceSplitAxis) -> WorkspaceAxisSizing {
        document.slot(slotID).layout.flatMap { visibleLayout($0, axis: axis) } ?? .init()
    }

    private func visibleLayout(_ node: WorkspaceLayoutNode, axis: WorkspaceSplitAxis) -> WorkspaceAxisSizing? {
        switch node {
        case .group(let id):
            guard let group = document.groups[id], !group.isCollapsed, !group.panels.isEmpty else { return nil }
            return self.group(id, axis: axis)
        case .split(let splitAxis, _, let first, let second):
            switch (visibleLayout(first, axis: axis), visibleLayout(second, axis: axis)) {
            case (let first?, let second?): return combine(first, second, stacked: splitAxis == axis, gap: metrics.divider)
            case (let value?, nil), (nil, let value?): return value
            case (nil, nil): return nil
            }
        }
    }

    func layout(_ node: WorkspaceLayoutNode, axis: WorkspaceSplitAxis) -> WorkspaceAxisSizing {
        switch node {
        case .group(let id): return group(id, axis: axis)
        case .split(let splitAxis, _, let first, let second):
            return combine(layout(first, axis: axis), layout(second, axis: axis),
                           stacked: splitAxis == axis, gap: metrics.divider)
        }
    }

    func combine(_ first: WorkspaceAxisSizing, _ second: WorkspaceAxisSizing,
                 stacked: Bool, gap: Float = 0) -> WorkspaceAxisSizing {
        if stacked {
            return WorkspaceAxisSizing(minimum: first.minimum + second.minimum + gap,
                                       preferred: optionalSum(first.preferred, second.preferred, gap: gap),
                                       maximum: optionalSum(first.maximum, second.maximum, gap: gap))
        }
        return WorkspaceAxisSizing(minimum: max(first.minimum, second.minimum),
                                   preferred: [first.preferred, second.preferred].compactMap { $0 }.max(),
                                   maximum: [first.maximum, second.maximum].compactMap { $0 }.min())
    }

    func floatingFrame(_ proposed: WorkspaceRect, groupID: WorkspaceTabGroupID, titleHeight: Float = 30) -> WorkspaceRect {
        let width = group(groupID, axis: .horizontal)
        let height = group(groupID, axis: .vertical)
        var result = proposed
        result.width = max(width.minimum, min(width.maximum ?? .greatestFiniteMagnitude,
            proposed.width.isFinite ? proposed.width : width.preferred ?? 520))
        result.height = max(height.minimum + titleHeight, min((height.maximum ?? (.greatestFiniteMagnitude - titleHeight)) + titleHeight,
            proposed.height.isFinite ? proposed.height : (height.preferred ?? 390) + titleHeight))
        return result
    }

    private func optionalSum(_ first: Float?, _ second: Float?, gap: Float) -> Float? {
        guard let first, let second else { return nil }
        return first + second + gap
    }
}

struct WorkspaceResolvedSplit {
    let fraction: Float
    let range: ClosedRange<Float>
    let available: Float

    init(fraction: Float?, fallback: Float, available: Float,
         first: WorkspaceAxisSizing, second: WorkspaceAxisSizing) {
        self.available = max(0, available)
        let constraints = SplitConstraints(fraction: 0...1,
            minimumFirst: first.minimum, minimumSecond: second.minimum,
            maximumFirst: first.maximum, maximumSecond: second.maximum)
        range = constraints.range(available: available)
        let initial: Float
        if let fraction { initial = fraction }
        else if available > 0, let preferred = first.preferred { initial = preferred / available }
        else if available > 0, let preferred = second.preferred { initial = 1 - preferred / available }
        else { initial = fallback }
        self.fraction = max(range.lowerBound, min(range.upperBound, initial.isFinite ? initial : fallback))
    }
}

/// These values live on the measured container, never in the document. Divider
/// input walks only its ancestors, avoiding a workspace tree scan per motion.
struct WorkspaceResizeGeometry {
    static let key = "workspace.resize.geometry"
    let splitID: WorkspaceSplitID
    let horizontal: Bool
    let offset: Float
    let split: WorkspaceResolvedSplit
}

struct WorkspaceResizeGeometryModifier: ViewModifier {
    let values: [WorkspaceResizeGeometry]
    func apply(node: Node) { node.attachments[WorkspaceResizeGeometry.key] = values }
}

func workspaceResizeGeometry(_ splitID: WorkspaceSplitID, from node: Node) -> (Node, WorkspaceResizeGeometry)? {
    var ancestor = node.parent
    while let current = ancestor {
        if let values = current.attachments[WorkspaceResizeGeometry.key] as? [WorkspaceResizeGeometry],
           let value = values.first(where: { $0.splitID == splitID }) { return (current, value) }
        ancestor = current.parent
    }
    return nil
}

/// Install one callback per node, updating its binding on recomposition. Pixel
/// noise does not schedule another composition, and callbacks never accumulate.
struct WorkspaceExtentObserver: ViewModifier {
    let horizontal: Bool
    let extent: Binding<Float>
    private static let key = "workspace.extent.observer"
    private final class Measurement {
        var horizontal: Bool
        var extent: Binding<Float>
        init(horizontal: Bool, extent: Binding<Float>) { self.horizontal = horizontal; self.extent = extent }
        func update(_ node: Node) {
            let value = horizontal ? Float(node.frame.width) : Float(node.frame.height)
            if abs(extent.wrappedValue - value) > 0.01 { extent.wrappedValue = value }
        }
    }
    func apply(node: Node) {
        if let owner = node.attachments[Self.key] as? Measurement {
            owner.horizontal = horizontal; owner.extent = extent
        } else {
            let owner = Measurement(horizontal: horizontal, extent: extent)
            node.attachments[Self.key] = owner
            let previous = node.layoutDidUpdate
            node.layoutDidUpdate = { node in previous?(node); owner.update(node) }
        }
    }
}

struct WorkspaceMetricsReader<Content: View>: _PrimitiveView {
    let content: (WorkspaceLayoutMetrics) -> Content
    init(@ViewBuilder content: @escaping (WorkspaceLayoutMetrics) -> Content) { self.content = content }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    func _children(for node: Node) -> [any View] {
        [content(WorkspaceLayoutMetrics(theme: resolveWorkspaceTheme(on: node), scaler: node.compositionValue(of: TextScalerEnvironment.key)))]
    }
}
