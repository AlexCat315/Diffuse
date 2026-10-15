import Foundation
import GuavaUIRuntime

/// Pointer detail with delayed opening and a grace period for crossing onto
/// interactive content. Provide a click or inline equivalent for keyboard users.
public struct HoverCard<Label: View, Content: View>: View {
    public var openDelay = 0.3
    public var closeDelay = 0.15
    public var width: Float? = 300
    public var isEnabled = true
    public let label: Label
    public let content: Content

    public init(width: Float? = 300,
                configure: (inout Self) -> Void = { _ in },
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.width = width; self.label = label(); self.content = content()
        configure(&self)
    }

    public var body: some View {
        HoverCardHost(label: label, content: AnyView(content), options: HoverCardTiming(
            openDelay: openDelay, closeDelay: closeDelay, width: width, isEnabled: isEnabled))
    }
}

struct HoverCardTiming {
    var openDelay: Double
    var closeDelay: Double
    var width: Float?
    var isEnabled: Bool
    mutating func validate() {
        openDelay = openDelay.isFinite ? min(60, max(0, openDelay)) : 0.3
        closeDelay = closeDelay.isFinite ? min(60, max(0, closeDelay)) : 0.15
        width = width.map { $0.isFinite ? min(4096, max(80, $0)) : 300 }
    }
}

private struct HoverCardHost<Label: View>: _PrimitiveView {
    let label: Label
    let content: AnyView
    let options: HoverCardTiming
    func _makeNode() -> Node {
        let node = Node()
        node.addResource(PortalResource()); node.addResource(HoverCardSession())
        node.attachments["hoverCard.host"] = true
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .flexStart; return layout }
    func _updateNode(_ node: Node) {
        let session = node.firstResource(HoverCardSession.self)!
        session.configure(content: content, options: options)
        InteractionRegistryHolder.current?.setHover(node) { session.setTriggerHovered($0 == .enter) }
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard phase != .capture, event.scancode == Scancode.escape else { return .ignored }
            return session.dismiss() ? .handled : .ignored
        }
        node.layoutDidUpdate = { _ in session.updatePosition() }
    }
    var _children: [any View] { [label] }
}

/// Delays, hover intent and portal ownership share the node's lifetime.
final class HoverCardSession: NodeResource, AnyAnimationController {
    private weak var node: Node?
    private weak var scheduler: AnimatorScheduler?
    private var content: AnyView?
    private var options = HoverCardTiming(openDelay: 0.3, closeDelay: 0.15, width: 300, isEnabled: true)
    private var triggerHovered = false
    private var cardHovered = false
    private var dismissedUntilLeave = false
    private var presented = false
    private var pending: Bool?
    private var elapsed = 0.0
    private(set) var isFinished = true

    func mount(node: Node) { self.node = node; scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { hide(); self.node = nil; scheduler = nil; content = nil }
    func configure(content: AnyView, options: HoverCardTiming) {
        self.content = content; self.options = options; self.options.validate()
        if !options.isEnabled { triggerHovered = false; cardHovered = false; hide(); return }
        if presented { show() }
        refresh()
    }
    func setTriggerHovered(_ value: Bool) { triggerHovered = value; refresh() }
    func setCardHovered(_ value: Bool) { cardHovered = value; refresh() }

    private func refresh() {
        let hovered = triggerHovered || cardHovered
        if !hovered { dismissedUntilLeave = false }
        let wanted = options.isEnabled && hovered && !dismissedUntilLeave
        guard wanted != presented else { stopWaiting(); return }
        if pending != wanted { stopWaiting(); pending = wanted }
        let delay = wanted ? options.openDelay : options.closeDelay
        if elapsed >= delay { stopWaiting(); if wanted { show() } else { hide() }; return }
        if isFinished { isFinished = false; scheduler?.register(self) }
    }
    func tick(deltaTime: Double) {
        guard !isFinished, node != nil, deltaTime.isFinite, deltaTime > 0 else { return }
        elapsed += min(60, deltaTime); refresh()
    }
    private func stopWaiting() {
        isFinished = true; pending = nil; elapsed = 0; scheduler?.unregister(self)
    }
    private func show() {
        guard let node, let content, options.isEnabled else { return }
        presented = true
        let surface = ThemeReader { [weak self] theme in
            HoverCardAccessory(owner: node, content: AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                ShortcutHost(route: .overlay, onKeyDown: { [weak self] event in
                    guard event.scancode == Scancode.escape else { return false }
                    return self?.dismiss() ?? false
                })
                content
            }
                .padding(theme.spacing.md).glassSurface(theme.radius.md)
                .onHover { [weak self] in self?.setCardHovered($0) }))
        }
        let portal = node.firstResource(PortalResource.self)!
        portal.present(in: node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current,
                       position: position(node), width: options.width, content: AnyView(surface.theme(node.theme)))
        portal.setDismissal(anchor: { [weak node] in node?.absoluteFrame ?? .zero },
                            dismiss: { [weak self] in self?.dismiss() })
    }
    private func position(_ node: Node) -> CGPoint { CGPoint(x: node.absoluteFrame.minX, y: node.absoluteFrame.maxY + 6) }
    func updatePosition() {
        guard presented, let node, let id = node.firstResource(PortalResource.self)?.entryID else { return }
        let store = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        store.updatePosition(id, position: position(node))
    }
    @discardableResult
    func dismiss() -> Bool {
        let wasPresented = presented
        dismissedUntilLeave = true; hide(); return wasPresented
    }
    private func hide() {
        stopWaiting(); presented = false; cardHovered = false
        if let node { node.firstResource(PortalResource.self)?.unmount(node: node) }
    }
    func cancel() { hide() }
    func finishImmediately() { hide() }
}

private struct HoverCardAccessory: _PrimitiveView {
    let owner: Node
    let content: AnyView
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false
        node.addResource(FocusAccessoryResource(owner: owner)); return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    var _children: [any View] { [content] }
}
