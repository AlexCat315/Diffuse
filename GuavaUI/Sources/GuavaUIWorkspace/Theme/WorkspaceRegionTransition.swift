import GuavaUICompose
import GuavaUIRuntime

/// Shares the same motion with adjacent flexible content without animating
/// splitter drags. The first layout and nonanimated hosts remain immediate.
struct _WorkspaceLayoutAnimation: ViewModifier, _AroundApplyingModifier {
    let phase: [Bool]

    func _aroundApply(node: Node, perform: () -> Void) {
        let key = "workspace.layout.phase"
        let previous = node.attachments[key] as? [Bool]
        node.attachments[key] = phase
        if previous != nil, previous != phase, resolveWorkspaceTheme(on: node).animatesLayout {
            withAnimation(.semantic(.medium, in: node.theme), perform)
        } else { perform() }
    }
}

enum WorkspaceRegionSizing {
    case fraction(Float)
    case points(Float)
    case divider

    func extent(in theme: WorkspaceTheme) -> Float {
        switch self {
        case .fraction(let value), .points(let value): max(0, value)
        case .divider: max(1, theme.splitDividerThickness)
        }
    }
}

/// Retains the departing region while its share of the layout shrinks. The
/// authored workspace document changes immediately; this state is paint only.
struct WorkspaceRegionTransition: View {
    let isVisible: Bool
    let horizontal: Bool
    let sizing: WorkspaceRegionSizing
    let phase: [Bool]
    let content: AnyView
    @State private var revision = 0

    var body: some View {
        WorkspaceRegionHost(isVisible: isVisible, horizontal: horizontal, sizing: sizing,
                            phase: phase, content: content, revision: revision,
                            onFinished: { revision &+= 1 })
    }
}

private final class WorkspaceRegionPresentation: NodeResource {
    var content: AnyView?
    var phase: [Bool]?
    var target: Float = 0
    var extent: Float = 0
    var alpha: Float = 1
    var controller: AnimationController<Float>?

    func mount(node: Node) {}
    func unmount(node: Node) { controller?.cancel(); content = nil }
}

private struct WorkspaceRegionHost: _PrimitiveView {
    let isVisible: Bool
    let horizontal: Bool
    let sizing: WorkspaceRegionSizing
    let phase: [Bool]
    let content: AnyView
    let revision: Int
    let onFinished: () -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.clipsToBounds = true
        node.addResource(WorkspaceRegionPresentation())
        return node
    }

    /// A splitter overhangs the cards on both sides, so it must not be clipped
    /// by its own region — and it has to win hit-testing against the card
    /// content it covers, or the grab area would belong to the panel instead.
    private var isSplitter: Bool {
        if case .divider = sizing { return true }
        return false
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.minWidth = 0; layout.minHeight = 0
        layout.flexShrink = 1
        return layout
    }

    func _updateNode(_ node: Node) {
        guard let state = node.firstResource(WorkspaceRegionPresentation.self) else { return }
        let workspaceTheme = resolveWorkspaceTheme(on: node)
        node.clipsToBounds = !isSplitter
        node.zIndex = isSplitter ? 1 : 0
        let target = isVisible ? sizing.extent(in: workspaceTheme) : 0
        let animate = workspaceTheme.animatesLayout && state.phase != nil && state.phase != phase
        state.phase = phase
        if isVisible { state.content = content }
        node.allowsHitTesting = isVisible
        node.isInteractionEnabled = isVisible
        if !isVisible {
            if let focused = FocusChainHolder.current?.focused, !focused.acceptsSubtreeInput {
                FocusChainHolder.current?.clear()
            }
            if let captured = PointerCaptureHolder.current?.target, !captured.acceptsSubtreeInput {
                PointerCaptureHolder.current?.release()
            }
        }
        guard state.target != target || (target == 0 && state.controller == nil) else { return }
        state.controller?.cancel()
        state.target = target
        guard animate else {
            state.extent = target; state.alpha = isVisible ? 1 : 0
            if !isVisible { state.content = nil }
            apply(state, to: node)
            return
        }
        let from = state.extent
        let alpha = state.alpha
        let goalAlpha: Float = isVisible ? 1 : 0
        let controller = AnimationController(from: Float(0), to: Float(1),
                                              animation: .semantic(.medium, in: node.theme)) {
            [weak state, weak node] amount in
            guard let state, let node else { return }
            state.extent = from + (target - from) * amount
            state.alpha = alpha + (goalAlpha - alpha) * amount
            apply(state, to: node)
            if amount == 1 {
                state.controller = nil
                if !isVisible { state.content = nil }
                onFinished()
            }
        }
        state.controller = controller
        AnimatorScheduler.current.register(controller)
        apply(state, to: node)
    }

    private func apply(_ state: WorkspaceRegionPresentation, to node: Node) {
        guard let layout = node.layoutNode else { return }
        let value = max(0, state.extent)
        switch sizing {
        case .fraction:
            layout.setFlexBasis(0); layout.flexGrow = value
        case .points:
            layout.flexGrow = 0; layout.flexShrink = 0
            if horizontal { layout.width = value } else { layout.height = value }
        case .divider:
            // The hairline is what separates two cards, so the region it lives
            // in reserves only that hairline. The grab area is added on top as a
            // negative margin: it overhangs the cards instead of pushing them
            // apart, which is what a gutter of real margin always ended up
            // doing.
            let slop = max(0, resolveWorkspaceTheme(on: node).splitDividerHitSlop)
            layout.flexGrow = 0; layout.flexShrink = 0
            let span = value + 2 * slop
            if horizontal {
                layout.width = span
                layout.setMargin(-slop, edge: .left)
                layout.setMargin(-slop, edge: .right)
            } else {
                layout.height = span
                layout.setMargin(-slop, edge: .top)
                layout.setMargin(-slop, edge: .bottom)
            }
        }
        node.opacity = max(0, min(1, state.alpha))
    }

    func _children(for node: Node) -> [any View] {
        _ = revision
        return node.firstResource(WorkspaceRegionPresentation.self)?.content.map { [$0] } ?? []
    }
}
