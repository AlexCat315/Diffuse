import GuavaUIRuntime

/// Horizontal alignment of a popover against its anchor.
public enum PopoverPlacement: Sendable, Equatable {
    case start
    case end
}

enum PopoverSizing: Equatable { case content, anchor }

struct PopoverTriggerDescription {
    let label: String
    var value = ""
    var help: String?
}

/// Anchored overlay opened by a labelled trigger button.
///
/// The popup is portal-rendered, so it escapes any clipping or stacking
/// context the trigger sits in, and it is dismissed by Escape, by losing the
/// pointer, or by the trigger being pressed again.
///
/// `Popover` owns the trigger button. Surfaces that need a different trigger
/// (a hover card, a context menu) use `_PopoverOverlayHost` directly.
public struct Popover<Label: View, Content: View>: View {
    public let isPresented: Binding<Bool>
    public let isEnabled: Bool
    public let width: Float?
    public let placement: PopoverPlacement
    public let triggerStyle: AnyButtonStyle?
    public let label: Label
    public let content: Content
    public let onKey: ((KeyEvent, EventPhase) -> EventResult)?
    var sizing: PopoverSizing = .content
    var triggerDescription: PopoverTriggerDescription?

    public init(isPresented: Binding<Bool>,
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .start,
                triggerStyle: AnyButtonStyle? = nil,
                onKey: ((KeyEvent, EventPhase) -> EventResult)? = nil,
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.width = width
        self.placement = placement
        self.triggerStyle = triggerStyle
        self.onKey = onKey
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        if !isEnabled && isPresented.wrappedValue { isPresented.wrappedValue = false }
        return Box(direction: .column, alignItems: sizing == .anchor ? .stretch : .flexStart, spacing: 0) {
            if let description = triggerDescription {
                trigger.compositionLocal(ActionControlAccessibility.label, description.label)
                    .compositionLocal(ActionControlAccessibility.value, description.value)
            } else {
                trigger
            }

            _PopoverOverlayHost(isPresented: isEnabled && isPresented.wrappedValue,
                                width: width,
                                placement: placement,
                                sizing: sizing,
                                onDismiss: { isPresented.wrappedValue = false },
                                keyHandler: onKey) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    content
                }
                .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .zIndex(isPresented.wrappedValue ? 10_000 : 0)
    }

    @ViewBuilder private var trigger: some View {
        let button = Button(role: .normal, isEnabled: isEnabled, tooltip: triggerDescription?.help,
                            action: { isPresented.wrappedValue.toggle() }) { label }
        if let triggerStyle {
            button.buttonStyle(triggerStyle)
                .compositionLocal(ActionControlAccessibility.isExpanded, isEnabled && isPresented.wrappedValue)
        } else {
            button.buttonStyle(PopoverTriggerStyle())
                .compositionLocal(ActionControlAccessibility.isExpanded, isEnabled && isPresented.wrappedValue)
        }
    }
}

/// Trigger chrome for popovers.
///
/// A trigger owns its own look — a select pill, a colour well, an icon button,
/// a "…" menu — so this style contributes no fill, padding or hover tint. It
/// adds exactly one thing: the keyboard focus ring, drawn outside the trigger's
/// box. Pointer focus is invisible, which is why an open popover never shows a
/// ring around the control that opened it.
private struct PopoverTriggerStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        return AnyView(configuration.label)
            .cornerRadius(theme.inputs.radius)
            .border(configuration.isFocused ? theme.colors.focusRing : .clear,
                    width: configuration.isFocused ? 2 : 0)
            .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}

/// Portal-backed popup anchored below the preceding sibling's frame.
///
/// Shared by `Popover` and `HoverCard` so both get identical positioning,
/// dismissal and keyboard behaviour instead of two overlapping copies.
struct _PopoverOverlayHost<Content: View>: _PrimitiveView {
    let isPresented: Bool
    let width: Float?
    let placement: PopoverPlacement
    let sizing: PopoverSizing
    let content: Content
    let keyHandler: ((KeyEvent, EventPhase) -> EventResult)?
    let onDismiss: () -> Void

    private struct PositionIdentity: Equatable {
        let width: Float?
        let placement: PopoverPlacement
        let sizing: PopoverSizing
    }

    init(isPresented: Bool, width: Float?,
         placement: PopoverPlacement,
         sizing: PopoverSizing = .content,
         onDismiss: @escaping () -> Void,
         keyHandler: ((KeyEvent, EventPhase) -> EventResult)? = nil,
         @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.width = width
        self.placement = placement
        self.sizing = sizing
        self.keyHandler = keyHandler
        self.onDismiss = onDismiss
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        // The portal entry is owned by this node's lifetime: when the popover
        // closes or its subtree is torn down, `Node.removeChild` unmounts the
        // resource and the entry is unregistered — no modifier cleanup needed.
        node.addResource(PortalResource())
        return node
    }

    func _updateNode(_ node: Node) {
        guard isPresented else {
            node.firstResource(PortalResource.self)?.dismiss(node: node)
            return
        }
        guard node.acceptsSubtreeInput else {
            node.firstResource(PortalResource.self)?.unmount(node: node)
            onDismiss()
            return
        }
        let position = Self.popoverPosition(for: node, width: width, placement: placement)

        // Register / update the overlay entry through the node-owned resource.
        // `present` re-registers if a prior entry was cleaned up, so a reused
        // node reliably re-shows the menu.
        let portalStore = node.compositionValue(of: PortalStoreEnvironment.key)
            ?? PortalStoreHolder.current
        node.firstResource(PortalResource.self)?
            .present(in: portalStore,
                     position: position,
                     width: width,
                     content: AnyView(FocusScope(restoresCommands: true) {
                        _MenuKeyHost(onKey: { event in
                            if event.scancode == Scancode.escape { onDismiss(); return true }
                            return keyHandler?(event, .target) == .handled
                        }) { content }
                     }),
                     // `popoverPosition` puts the panel directly below the
                     // trigger, aligned to its leading or trailing edge, so the
                     // pinned corner is the matching top one. A fixed anchor
                     // would make a trailing popover grow away from the thing
                     // that opened it.
                     transition: .opacity
                         .combined(with: .move(edge: .top, distance: 6))
                         .combined(with: PortalResource.surfaceReveal(
                            anchor: placement == .end ? CGPoint(x: 1, y: 0) : .zero, theme: node.theme)))
        node.firstResource(PortalResource.self)?.updateFit(fit(for: node))
        node.firstResource(PortalResource.self)?.setDismissal(
            anchor: { [weak node] in node.map { Self.anchorFrame(for: $0) ?? .zero } ?? .zero },
            dismiss: onDismiss
        )
        node.attachments[LayoutDebugAttachmentKey.debugName] =
            "popover-store-\(ObjectIdentifier(portalStore))-entries-\(portalStore.entries.count)"
        node.updateOverlayDraw(identity: PositionIdentity(width: width,
                                                          placement: placement, sizing: sizing)) { [weak node] _, _ in
            guard let node else { return }
            node.firstResource(PortalResource.self)?
                .updatePosition(Self.popoverPosition(for: node, width: width, placement: placement))
            node.firstResource(PortalResource.self)?.updateFit(fit(for: node))
        }
        node.layoutDidUpdate = { [width, placement] node in
            node.firstResource(PortalResource.self)?
                .updatePosition(Self.popoverPosition(for: node, width: width, placement: placement))
            node.firstResource(PortalResource.self)?.updateFit(fit(for: node))
        }

        node.isFocusable = false
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPositionPercent(100, edge: .top)
        layout.width = sizing == .anchor ? 0 : width
    }

    var _children: [any View] {
        // Content is portal-rendered via the window-scoped PortalStore + PortalHost
        []
    }

    private func fit(for node: Node) -> PortalFitConstraints {
        guard sizing == .anchor else { return .init() }
        return .init(minimumWidth: Float(Self.anchorFrame(for: node)?.width ?? 0), viewportMargin: 12)
    }

    private static func popoverPosition(for node: Node,
                                        width: Float?,
                                        placement: PopoverPlacement) -> CGPoint {
        let boxFrame = anchorFrame(for: node) ?? node.parent?.absoluteFrame ?? .zero
        let x: CGFloat
        switch placement {
        case .start:
            x = boxFrame.minX
        case .end:
            if let width {
                x = boxFrame.maxX - CGFloat(width)
            } else {
                x = boxFrame.minX
            }
        }
        return CGPoint(x: x, y: boxFrame.maxY)
    }

    private static func anchorFrame(for node: Node) -> CGRect? {
        var current: Node? = node
        while let currentNode = current, let parent = currentNode.parent {
            if let index = parent.children.firstIndex(where: { $0 === currentNode }) {
                for sibling in parent.children[..<index].reversed() {
                    if let frame = firstVisibleFrame(in: sibling) {
                        return frame
                    }
                }
            }
            current = parent
        }
        return nil
    }

    private static func firstVisibleFrame(in node: Node) -> CGRect? {
        let frame = node.absoluteFrame
        if frame.width > 0 || frame.height > 0 {
            return frame
        }
        for child in node.children.reversed() {
            if let frame = firstVisibleFrame(in: child) {
                return frame
            }
        }
        return nil
    }
}
