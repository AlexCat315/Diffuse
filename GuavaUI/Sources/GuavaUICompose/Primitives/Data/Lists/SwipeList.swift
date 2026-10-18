import Foundation
import GuavaUIRuntime
@_spi(CustomLayout) import GuavaUIScene

/// One trailing action on a `SwipeList` row. The swipe surface shows at most
/// two actions; the row's always-available actions menu exposes every entry, so
/// pointer, keyboard and assistive clients are never limited to swiping.
public struct SwipeAction: Identifiable {
    public let id: AnyHashable
    public let title: String
    public let tone: StatusTone
    public let isEnabled: Bool
    public let action: () -> Void

    public init<ID: Hashable>(id: ID,
                              title: String,
                              tone: StatusTone = .neutral,
                              isEnabled: Bool = true,
                              action: @escaping () -> Void) {
        self.id = AnyHashable(id)
        self.title = title
        self.tone = tone
        self.isEnabled = isEnabled
        self.action = action
    }

    public init(title: String,
                tone: StatusTone = .neutral,
                isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.init(id: title, title: title, tone: tone,
                  isEnabled: isEnabled, action: action)
    }
}

/// Vertical list with trailing swipe actions. Selection and keyboard navigation
/// follow `List`; a swipe toward the logical leading edge reveals two actions.
/// Every row also carries an actions menu, so the same commands are reachable
/// with a pointer, keyboard or screen reader.
///
/// The list mounts all rows (like `ReorderableList`); use it for settings,
/// inbox rows and playlists rather than unbounded collections.
public struct SwipeList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    public let data: Data
    public let id: KeyPath<Data.Element, ID>
    public let selection: Binding<ID?>
    public let rowHeight: Float
    public let rowSpacing: Float
    public let isEnabled: Bool
    public let rowLabel: (Data.Element) -> String
    public let actions: (Data.Element) -> [SwipeAction]
    public let onActivate: ((Data.Element) -> Void)?
    public let rowContent: (Data.Element, Bool) -> RowContent

    @State private var cursor: ID?
    @State private var viewportWidth: Float = 0

    public init(_ data: Data,
                id: KeyPath<Data.Element, ID>,
                selection: Binding<ID?> = .constant(nil),
                rowHeight: Float = 36,
                rowSpacing: Float = 0,
                isEnabled: Bool = true,
                rowLabel: @escaping (Data.Element) -> String = { _ in "" },
                actions: @escaping (Data.Element) -> [SwipeAction],
                onActivate: ((Data.Element) -> Void)? = nil,
                @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent) {
        self.data = data
        self.id = id
        self.selection = selection
        self.rowHeight = max(1, rowHeight)
        self.rowSpacing = max(0, rowSpacing)
        self.isEnabled = isEnabled
        self.rowLabel = rowLabel
        self.actions = actions
        self.onActivate = onActivate
        self.rowContent = rowContent
    }

    public var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                let elements = Array(data)
                let height = max(scaler.scale(rowHeight),
                                 surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
                let spacing = scaler.scale(rowSpacing)
                let contentHeight = max(0, Float(elements.count) * (height + spacing) - spacing)
                let width = max(1, viewportWidth)
                SelectionKeyHost(isEnabled: isEnabled, onKey: { handleKey($0, elements: elements) }) {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ScrollView(.vertical, scrollbarGutter: .stable,
                                   onViewportChange: { viewport in
                            // The reported viewport includes the reserved
                            // scrollbar lane; row chrome must fit beside it.
                            let next = max(1, Float(viewport.size.width) - ScrollView<EmptyView>.scrollbarGutterWidth)
                            if abs(next - viewportWidth) > 0.5 { viewportWidth = next }
                        }) {
                            Box(direction: .column, alignItems: .stretch, spacing: spacing) {
                                for index in elements.indices {
                                    AnyView(row(elements[index], index: index, elements: elements,
                                                height: height, actionWidth: scaler.scale(_SwipeRow.actionWidth)))
                                }
                            }
                            .frame(width: .points(width), height: .points(max(1, contentHeight)))
                        }
                        .flex(1, shrink: 1, basis: 0)
                    }
                    .flex(1, shrink: 1, basis: 0)
                }
            }
        }
    }

    private func row(_ element: Data.Element, index: Int, elements: [Data.Element],
                     height: Float, actionWidth: Float) -> some View {
        let elementID = element[keyPath: id]
        let rowActions = isEnabled ? actions(element) : []
        return _SwipeRow(
            label: rowLabel(element),
            isSelected: selection.wrappedValue == elementID,
            isEnabled: isEnabled,
            rowHeight: height,
            rowWidth: viewportWidth,
            actionWidth: actionWidth,
            actions: rowActions,
            onSelect: { activate(element) },
            content: AnyView(rowContent(element, selection.wrappedValue == elementID))
        )
        .id(elementID)
    }

    private func select(_ element: Data.Element) {
        cursor = element[keyPath: id]
        selection.wrappedValue = cursor
    }

    private func activate(_ element: Data.Element) {
        select(element)
        onActivate?(element)
    }

    private func handleKey(_ event: KeyEvent, elements: [Data.Element]) -> Bool {
        guard isEnabled, !elements.isEmpty else { return false }
        let current = cursor.flatMap { value in elements.firstIndex { $0[keyPath: id] == value } }
            ?? selection.wrappedValue.flatMap { value in elements.firstIndex { $0[keyPath: id] == value } }
        if event.scancode == Scancode.return || event.scancode == Scancode.keypadEnter {
            guard let current else { return false }
            activate(elements[current])
            return true
        }
        let next: Int
        switch event.scancode {
        case Scancode.arrowDown: next = min(elements.count - 1, (current ?? -1) + 1)
        case Scancode.arrowUp: next = max(0, (current ?? elements.count) - 1)
        case Scancode.home: next = 0
        case Scancode.end: next = elements.count - 1
        default: return false
        }
        select(elements[next])
        return true
    }
}

private enum _SwipeRowKeys {
    static let start = "__swipe.start"
    static let base = "__swipe.base"
    static let active = "__swipe.active"
    static let rejected = "__swipe.rejected"
    static let hovered = "__swipe.hovered"
}

/// Row content plus the swipe reveal. State lives in the view so updating it
/// rebuilds the offset and action row; the gesture modifier only carries the
/// live interaction handlers and node semantics.
private struct _SwipeRow: View {
    static let actionWidth: Float = 74
    static let maxActions = 2

    let label: String
    let isSelected: Bool
    let isEnabled: Bool
    let rowHeight: Float
    let rowWidth: Float
    let actionWidth: Float
    let actions: [SwipeAction]
    let onSelect: () -> Void
    let content: AnyView

    @State private var reveal: CGFloat = 0

    private var swipeActions: [SwipeAction] { Array(actions.prefix(Self.maxActions)) }
    private var actionExtent: Float { max(44, min(actionWidth, rowWidth / Float(max(1, swipeActions.count)))) }
    private var maxReveal: CGFloat { CGFloat(swipeActions.count) * CGFloat(actionExtent) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Row(alignment: .center, spacing: 4) {
                Box(direction: .column, alignItems: .stretch) {
                    content
                }
                .flex(1, shrink: 1, basis: 0)
                .frame(minWidth: 0)
                .clipped()
                if !swipeActions.isEmpty {
                    Box(direction: .row) { EmptyView() }.frame(width: 44, height: rowHeight)
                }
            }
            .frame(width: max(1, rowWidth), height: rowHeight)
            .modifier(_SwipeGestureModifier(
                label: label, isSelected: isSelected, isEnabled: isEnabled,
                maxReveal: maxReveal,
                onSelect: onSelect, reveal: $reveal, snap: snap
            ))
            if !swipeActions.isEmpty {
                if reveal < -0.5 {
                    Row(alignment: .center, spacing: 0) {
                        for action in swipeActions {
                            AnyView(actionButton(action))
                        }
                    }.frame(height: rowHeight)
                } else {
                    Button(icon: .resource(UIIcons.Action.moreHorizontal), size: 16,
                           isEnabled: isEnabled, tooltip: "Actions for \(label)") {
                        reveal = -maxReveal
                    }
                    .buttonStyle(.ghost)
                    .accessibilityLabel("Actions for \(label)")
                    .frame(width: 44, height: rowHeight)
                }
            }
        }
        .frame(height: rowHeight)
        .clipped()
        .modifier(_SwipeEscapeModifier(isOpen: reveal < -0.5, dismiss: { setReveal(0, node: $0) }))
        .contextMenu(entries: { contextEntries })
    }

    private func snap(_ node: Node) {
        let target: CGFloat = reveal < -maxReveal * 0.45 ? -maxReveal : 0
        setReveal(target, node: node)
    }

    private func setReveal(_ target: CGFloat, node: Node) {
        if node.prefersReducedMotion {
            reveal = target
        } else {
            withAnimation(.semantic(.fast, in: node.theme)) { reveal = target }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SwipeAction) -> some View {
        let title = Text(action.title).truncatingTail().font(.caption)
        if action.tone == .danger {
            Button(isEnabled: isEnabled && action.isEnabled, action: {
                reveal = 0
                action.action()
            }) { title }
            .buttonStyle(.destructive)
            .accessibilityLabel(action.title)
            .frame(width: actionExtent, height: rowHeight)
        } else {
            Button(isEnabled: isEnabled && action.isEnabled, action: {
                reveal = 0
                action.action()
            }) { title }
            .buttonStyle(.secondary)
            .accessibilityLabel(action.title)
            .frame(width: actionExtent, height: rowHeight)
        }
    }

    private var contextEntries: [MenuEntry] {
        actions.map { action in
            .item(MenuItem(id: action.id, title: action.title,
                           isEnabled: isEnabled && action.isEnabled,
                           role: action.tone == .danger ? .destructive : .normal) {
                reveal = 0
                action.action()
            })
        }
    }
}

private struct _SwipeGestureModifier: ViewModifier {
    let label: String
    let isSelected: Bool
    let isEnabled: Bool
    let maxReveal: CGFloat
    let onSelect: () -> Void
    let reveal: Binding<CGFloat>
    let snap: (Node) -> Void

    func apply(node: Node) {
        let rtl = node.layoutNode?.customLayoutDirection == .rtl
        node.animatableSet(\.contentOffset, to: CGPoint(x: rtl ? reveal.wrappedValue : -reveal.wrappedValue, y: 0))
        node.isHitTestable = true
        node.attachments[LayoutDebugAttachmentKey.debugName] = "swipe-row-\(label)"
        node.applyTouchControlExtent()
        node.cornerRadius = 6
        node.accessibility = AccessibilitySemantics(.listItem) {
            $0.label = label
            $0.state.isSelected = isSelected
            $0.state.isEnabled = isEnabled
            $0.combinesChildren = true
        }
        node.accessibilityActions.activate = isEnabled ? onSelect : nil
        let applyBackground: () -> Void = {
            let active = node.attachments[_SwipeRowKeys.active] as? Bool == true
            guard !active else { return }
            let hovered = node.attachments[_SwipeRowKeys.hovered] as? Bool == true
            node.backgroundColor = isSelected ? node.theme.colors.stateLayerSelected
                : (hovered && isEnabled && node.supportsControlHover ? node.theme.colors.stateLayerHover : .clear)
        }
        applyBackground()
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { phase in
            node.attachments[_SwipeRowKeys.hovered] = phase == .enter && node.supportsControlHover
            applyBackground()
        }
        registry.setPointer(node) { event, phase, _ in
            guard isEnabled, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[_SwipeRowKeys.start] = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                node.attachments[_SwipeRowKeys.base] = reveal.wrappedValue
                node.attachments[_SwipeRowKeys.active] = false
                node.attachments[_SwipeRowKeys.rejected] = false
                // Observe without consuming: a vertical drag must still reach
                // the ScrollView, while a horizontal one is captured below.
                return .ignored
            case .up:
                let started = node.attachments[_SwipeRowKeys.start] != nil
                let active = node.attachments[_SwipeRowKeys.active] as? Bool == true
                let rejected = node.attachments[_SwipeRowKeys.rejected] as? Bool == true
                node.attachments.removeValue(forKey: _SwipeRowKeys.start)
                node.attachments.removeValue(forKey: _SwipeRowKeys.base)
                node.attachments[_SwipeRowKeys.active] = false
                node.attachments[_SwipeRowKeys.rejected] = false
                if active {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                    snap(node)
                    return .handled
                }
                if started, !rejected, reveal.wrappedValue < -0.5 {
                    snap(node)
                    return .handled
                }
                if started, !rejected,
                   node.absoluteFrame.contains(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) {
                    onSelect()
                    return .handled
                }
                return .ignored
            }
        }
        let supportsSwipe = node.compositionValue(of: SurfaceEnvironment.key).input.contains(.touch)
        node.cursor = isEnabled ? .pointer : .notAllowed
        registry.setMotion(node) { event, _ in
            guard supportsSwipe else { return .ignored }
            guard let start = node.attachments[_SwipeRowKeys.start] as? CGPoint,
                  let base = node.attachments[_SwipeRowKeys.base] as? CGFloat else { return .ignored }
            if node.attachments[_SwipeRowKeys.rejected] as? Bool == true { return .ignored }
            let dx = CGFloat(event.x) - start.x
            let dy = CGFloat(event.y) - start.y
            if node.attachments[_SwipeRowKeys.active] as? Bool != true {
                guard abs(dx) >= 8, abs(dx) > abs(dy) else {
                    if abs(dy) >= 4, abs(dy) > abs(dx) {
                        node.attachments[_SwipeRowKeys.rejected] = true
                    }
                    return .ignored
                }
                node.attachments[_SwipeRowKeys.active] = true
                PointerCaptureHolder.current?.acquire(node)
                node.backgroundColor = node.theme.colors.stateLayerPressed
            }
            let direction: CGFloat = node.layoutNode?.customLayoutDirection == .rtl ? -1 : 1
            let next = min(0, max(-maxReveal, base + dx * direction))
            if next != reveal.wrappedValue { reveal.wrappedValue = next }
            return .handled
        }
    }
}

/// The key boundary contains both content and action buttons, so Escape also
/// works while focus is on an action (which is a sibling of the content).
private struct _SwipeEscapeModifier: ViewModifier {
    let isOpen: Bool
    let dismiss: (Node) -> Void

    func apply(node: Node) {
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard phase != .capture, event.scancode == Scancode.escape, isOpen else { return .ignored }
            dismiss(node)
            return .handled
        }
    }
}
