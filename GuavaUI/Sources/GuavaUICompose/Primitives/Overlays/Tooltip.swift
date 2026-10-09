import Foundation
import GuavaUIRuntime

public struct TooltipOptions {
    public var delay: Double = 0.45
    public var maxWidth: Float = 320
    public var gap: Float = 6
    public var isEnabled = true
    public init() {}
    mutating func validate() {
        delay = delay.isFinite ? max(0, delay) : 0.45
        maxWidth = maxWidth.isFinite ? max(80, maxWidth) : 320
        gap = gap.isFinite ? max(0, gap) : 6
    }
}

/// Window coordinates match TextFieldHoverAnchor and overlay placement.
public enum TooltipAnchor: Equatable {
    case point(CGPoint)
    case range(CGRect)
    var rect: CGRect {
        switch self { case .point(let point): CGRect(origin: point, size: .zero); case .range(let rect): rect }
    }
}

/// An arbitrary target and noninteractive description, presented outside clipping.
public struct Tooltip<Target: View, Content: View>: View {
    private let target: Target
    private let content: Content
    private var coordinateAnchor: TooltipAnchor?
    private var isPresented = true
    public var options = TooltipOptions()
    public init(configure: (inout TooltipOptions) -> Void = { _ in }, @ViewBuilder target: () -> Target,
                @ViewBuilder content: () -> Content) {
        self.target = target(); self.content = content(); configure(&options); options.validate()
    }
    /// Explicitly anchored tooltips are already debounced by their producer
    /// (for example LSP hover), so presentation follows isPresented directly.
    public init(anchor: TooltipAnchor, isPresented: Bool = true,
                configure: (inout TooltipOptions) -> Void = { _ in },
                @ViewBuilder content: () -> Content) where Target == EmptyView {
        self.target = EmptyView(); self.content = content()
        coordinateAnchor = anchor; self.isPresented = isPresented
        configure(&options); options.validate()
    }
    public var body: AnyView {
        if let coordinateAnchor {
            return AnyView(CoordinateTooltipHost(anchor: coordinateAnchor, content: AnyView(content),
                                                  options: options, isPresented: isPresented))
        }
        return AnyView(TooltipHost(target: target, content: AnyView(content), options: options,
                    focused: FocusChainHolder.current?.currentFocus,
                    focusVisible: FocusChainHolder.current?.isFocusVisible ?? false))
    }
}

private struct CoordinateTooltipHost: _PrimitiveView {
    let anchor: TooltipAnchor
    let content: AnyView
    let options: TooltipOptions
    let isPresented: Bool
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.addResource(PortalResource())
        node.attachments["tooltip.coordinate"] = true
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        guard let resource = node.firstResource(PortalResource.self) else { return }
        guard isPresented, options.isEnabled else { resource.unmount(node: node); return }
        let store = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        resource.present(in: store, position: CGPoint(x: anchor.rect.minX, y: anchor.rect.maxY + CGFloat(options.gap)),
                         width: nil, content: AnyView(content.frame(maxWidth: options.maxWidth).theme(node.theme).allowsHitTesting(false)))
        resource.setDismissal(anchor: { anchor.rect }, dismiss: {})
    }
}

public extension View {
    func tooltip(_ description: String, configure: (inout TooltipOptions) -> Void = { _ in }) -> some View {
        Tooltip(configure: configure, target: { self }) {
            tooltipDescription(description)
        }
    }
}

func tooltipDescription(_ description: String) -> AnyView {
    AnyView(Text(description).font(.caption).foregroundColor(.onSurface)
        .padding(9).background(.surfaceFloating).cornerRadius(6).border(.border, width: 1))
}

private struct TooltipHost<Target: View>: _PrimitiveView {
    let target: Target
    let content: AnyView
    let options: TooltipOptions
    let focused: Node?
    let focusVisible: Bool
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.addResource(PortalResource()); node.addResource(TooltipSession())
        node.attachments["tooltip.host"] = true
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .stretch; return layout }
    func _updateNode(_ node: Node) {
        let session = node.firstResource(TooltipSession.self)!
        session.configure(content: content, options: options,
                          focused: focusVisible && focused.map { FocusChainHolder.current?.contains($0, in: node) == true } == true)
        InteractionRegistryHolder.current?.setHover(node) { phase in session.setHovered(phase == .enter) }
        InteractionRegistryHolder.current?.setPointer(node) { _, phase, _ in
            if phase == .down { session.dismiss() }; return .ignored
        }
        InteractionRegistryHolder.current?.setKey(node) { event, _ in
            if event.scancode == Scancode.escape, session.dismiss() { return .handled }; return .ignored
        }
        node.layoutDidUpdate = { _ in session.updatePosition() }
    }
    var _children: [any View] { [target] }
}

final class TooltipSession: NodeResource, AnyAnimationController {
    private weak var node: Node?
    private var content: AnyView?
    private var options = TooltipOptions()
    private var hovered = false
    private var focused = false
    private var elapsed: Double = 0
    private var presented = false
    private var dismissedUntilLeave = false
    var isFinished = true
    func mount(node: Node) { self.node = node }
    func unmount(node: Node) { hide(); self.node = nil }
    func configure(content: AnyView, options: TooltipOptions, focused: Bool) {
        self.content = content; self.options = options; self.focused = focused
        refresh()
    }
    func setHovered(_ hovered: Bool) { self.hovered = hovered; refresh() }
    func setFocused(_ focused: Bool) { self.focused = focused; refresh() }
    private func refresh() {
        guard options.isEnabled && (hovered || focused) else { dismissedUntilLeave = false; hide(); return }
        guard !dismissedUntilLeave else { return }
        if presented { show(); return }
        guard isFinished else { return }
        elapsed = 0
        if options.delay == 0 { show() }
        else { isFinished = false; AnimatorScheduler.current.register(self) }
    }
    func tick(deltaTime: Double) {
        guard !isFinished else { return }
        elapsed += max(0, deltaTime)
        if elapsed >= options.delay { isFinished = true; show() }
    }
    private func show() {
        guard let node, let content else { return }
        presented = true
        node.firstResource(PortalResource.self)?.present(in: node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current,
            position: position(node), width: nil,
            content: AnyView(content.frame(maxWidth: options.maxWidth).theme(node.theme).allowsHitTesting(false)))
        node.firstResource(PortalResource.self)?.setDismissal(anchor: { [weak node] in node?.absoluteFrame ?? .zero }, dismiss: { [weak self] in self?.dismiss() })
    }
    private func position(_ node: Node) -> CGPoint {
        CGPoint(x: node.absoluteFrame.minX, y: node.absoluteFrame.maxY + CGFloat(options.gap))
    }
    func updatePosition() {
        guard presented, let node, let resource = node.firstResource(PortalResource.self), let id = resource.entryID else { return }
        let store = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        store.updatePosition(id, position: position(node))
    }
    @discardableResult
    func dismiss() -> Bool { let wasPresented = presented; dismissedUntilLeave = true; hide(); return wasPresented }
    func hide() {
        isFinished = true; presented = false
        if let node { node.firstResource(PortalResource.self)?.unmount(node: node) }
    }
    func cancel() { hide() }
    func finishImmediately() { hide() }
}
