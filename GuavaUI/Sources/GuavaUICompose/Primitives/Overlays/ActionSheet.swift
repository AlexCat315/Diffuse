public import GuavaUIRuntime
@_spi(CustomLayout) internal import GuavaUIScene

/// A stable, caller-owned command. Dismissal is supplied separately by ActionSheet.
public struct ActionSheetAction: Identifiable {
    public let id: String
    public let title: String
    public var icon: BundleImageResource?
    public var role: ButtonRole = .normal
    public var isEnabled = true
    let action: () -> Void

    public init(_ id: String, _ title: String, icon: BundleImageResource? = nil,
                role: ButtonRole = .normal, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.icon = icon
        self.role = role; self.isEnabled = isEnabled; self.action = action
    }
}

/// An action drawer attached to a caller-owned trigger.
///
/// The sheet is one bottom drawer at every width: compact surfaces get a
/// full-width panel with a drag handle and no close control; wider surfaces
/// get a centered, bounded drawer with a top close control. The caller owns
/// the visible labels and supplies the localized accessibility name for that
/// close control, so the component never writes interface copy such as
/// "Cancel" or "Close" itself.
public struct ActionSheet<Label: View>: View {
    private let isPresented: Binding<Bool>
    private let isEnabled: Bool
    private let question: ActionSheetQuestion
    private let label: Label
    @State private var dragOffset: Float = 0

    public init(isPresented: Binding<Bool>, title: String, message: String = "",
                actions: [ActionSheetAction], closeLabel: String, isEnabled: Bool = true,
                @ViewBuilder label: () -> Label) {
        precondition(Set(actions.map(\.id)).count == actions.count, "ActionSheet action IDs must be unique")
        self.isPresented = isPresented; self.isEnabled = isEnabled
        question = ActionSheetQuestion(title: title, message: message, actions: actions,
                                       closeLabel: closeLabel)
        self.label = label()
    }

    public var body: some View {
        let enabled = isEnabled && !question.actions.isEmpty
        if !enabled && isPresented.wrappedValue { isPresented.wrappedValue = false }
        return Box(direction: .column, alignItems: .flexStart, spacing: 0) {
            Button(isEnabled: enabled, action: { dragOffset = 0; isPresented.wrappedValue.toggle() }) { label }
                .buttonStyle(.secondary)
                .compositionLocal(ActionControlAccessibility.isExpanded, enabled && isPresented.wrappedValue)
            ActionSheetPresentation(isPresented: isPresented, question: question, dragOffset: $dragOffset)
        }.zIndex(isPresented.wrappedValue ? 10_000 : 0)
    }
}

struct ActionSheetQuestion {
    let title: String
    let message: String
    let actions: [ActionSheetAction]
    let closeLabel: String
}

private struct ActionSheetPresentation: _PrimitiveView {
    let isPresented: Binding<Bool>
    let question: ActionSheetQuestion
    let dragOffset: Binding<Float>

    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _updateNode(_ node: Node) { node.isHitTestable = false }
    func _makeLayoutNode() -> LayoutNode? { nil }

    func _children(for node: Node) -> [any View] {
        let surface = node.compositionValue(of: SurfaceEnvironment.key)
        var parent = node.parent
        while parent?.layoutNode == nil, let next = parent?.parent { parent = next }
        let direction = parent?.layoutNode?.customLayoutDirection ?? .ltr
        let windowHeight = min(surface.viewport.height, Float(portalWindowBounds(node).height))
        let isCompact = surface.viewport.widthClass == .compact
        let safeBottom = max(0, surface.safeArea.bottom)
        let inset: Float = isCompact ? 0 : 12
        let width: Float = isCompact ? max(64, surface.viewport.width)
            : min(560, max(220, surface.viewport.width - inset * 2))
        // The drawer content is a handle (compact only), a fixed header and a
        // scrollable action list. Reserve the chrome height so a long list
        // never pushes the header or close control off a short window.
        let topClearance: Float = isCompact ? 68 : 48
        let chrome: Float = (isCompact ? 44 : 0) + 140
        let actionViewport = max(88, windowHeight - topClearance - safeBottom - chrome)
        let theme = node.theme
        let content = ActionSheetContent(
            question: question, isPresented: isPresented, maximumHeight: actionViewport,
            showsHandle: isCompact,
            onTranslation: { translation in
                dragOffset.wrappedValue = max(0, Float(translation))
            },
            onEnd: { distance, velocity in
                withAnimation(.semantic(.snappy, in: theme)) {
                    dragOffset.wrappedValue = 0
                    if distance > 80 || (distance > 0 && velocity > 900) {
                        isPresented.wrappedValue = false
                    }
                }
            }
        ).layoutDirection(direction == .rtl ? .rtl : .ltr)

        return [Modal(isPresented: isPresented, configure: {
            $0.geometry.placement = .bottom
            $0.geometry.inset = inset
            $0.geometry.width = width
            $0.geometry.height = .greatestFiniteMagnitude
            $0.geometry.cornerRadius = 18
            $0.fitsContentHeight = true
            $0.backdrop = .dimmed
            $0.surface = .surfaceFloating
            $0.translationY = dragOffset.wrappedValue
        }) {
            content
                .padding(EdgeInsets(bottom: safeBottom))
                .debugName("action-sheet-drawer")
        }]
    }
}
