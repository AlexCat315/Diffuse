import Foundation
import GuavaUIRuntime

/// Where toast cards are anchored inside the window.
///
/// `.automatic` anchors at the top trailing edge at every width, matching an
/// iOS notification banner rather than a bottom snackbar. The portal fit
/// clamps the final frame inside the window.
public enum ToastPosition: Sendable, Hashable {
    case automatic
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    func resolved(for widthClass: UIEnvironment.WidthClass) -> ToastPosition {
        guard self == .automatic else { return self }
        return .topTrailing
    }

    /// Top-left origin passed to the portal. A bottom anchor uses the window
    /// height and lets `PortalPlacement.fit` clamp to the content's real height.
    func origin(in bounds: CGRect, width: CGFloat, margin: CGFloat = 16) -> CGPoint {
        let isTrailing = self == .topTrailing || self == .bottomTrailing
        let isBottom = self == .bottomLeading || self == .bottomTrailing
        let x = isTrailing ? bounds.width - width - margin : margin
        let y = isBottom ? bounds.height : margin
        return CGPoint(x: max(margin, x), y: max(margin, y))
    }
}

public struct NotificationHost: View {
    public let controller: ToastController
    public var width: Float = 360
    public var position: ToastPosition = .automatic
    @State private var presentation = ToastPresentation()
    public init(_ controller: ToastController, width: Float = 360, position: ToastPosition = .automatic) {
        self.controller = controller
        self.width = max(120, width)
        self.position = position
    }
    public var body: some View {
        let entries = presentation.update(controller.notifications, limit: controller.maxVisible)
        return WidthClassReader { widthClass in
            ToastPresenter(controller: controller,
                           entries: entries,
                           width: width, position: position.resolved(for: widthClass),
                           onExit: { presentation.remove(id: $0, revision: $1) })
        }
    }
}

private struct ToastPresenter: _PrimitiveView {
    let controller: ToastController
    let entries: [ToastPresentation.Entry]
    let width: Float
    let position: ToastPosition
    let onExit: (String, Int) -> Void
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false
        node.addResource(PortalResource()); node.addResource(ToastClock())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.firstResource(ToastClock.self)?.configure(controller)
        present(node)
        node.layoutDidUpdate = { node in
            guard node.attachments["toast.windowBounds"] as? CGRect != portalWindowBounds(node) else { return }
            present(node)
        }
    }
    private func present(_ node: Node) {
        node.attachments["toast.windowBounds"] = portalWindowBounds(node)
        let resource = node.firstResource(PortalResource.self)
        guard !entries.isEmpty else { resource?.unmount(node: node); return }
        let bounds = portalWindowBounds(node)
        let actualWidth = min(width, max(120, Float(bounds.width) - 32))
        let surface = node.compositionValue(of: SurfaceEnvironment.key)
        let safePadding = position == .bottomLeading || position == .bottomTrailing
            ? EdgeInsets(bottom: surface.safeArea.bottom)
            : EdgeInsets(top: surface.safeArea.top)
        resource?.present(in: node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current,
                          position: position.origin(in: bounds, width: CGFloat(actualWidth)),
                          width: actualWidth, content: AnyView(Box(direction: .column, alignItems: .stretch, spacing: 10) {
            for entry in entries {
                AnyView(AnimatedVisibility(isVisible: entry.isVisible,
                    transition: .opacity.combined(with: .move(
                        edge: position == .bottomLeading || position == .bottomTrailing ? .bottom : .top,
                        distance: 12)).combined(with: .collapse),
                    animateOnMount: true,
                    onVisibilitySettled: { visible in
                        if !visible { onExit(entry.notification.id, entry.revision) }
                    }) {
                        ToastCard(notification: entry.notification, controller: controller)
                    }.accessibilityHidden(!entry.isVisible).id(entry.notification.id)
                    .debugName("toast-\(entry.notification.id)"))
            }
        }.padding(safePadding)))
    }
}

private struct ToastCard: View {
    let notification: ToastNotification
    let controller: ToastController
    var body: some View {
        ThemeReader { theme in
        Box(direction: .row, alignItems: .flexStart, spacing: 10) {
            Box(direction: .column, alignItems: .stretch, spacing: 5) {
                Text(notification.title).truncatingTail().tooltip(notification.title)
                    .font(.bodyStrong).foregroundColor(notification.tone.color)
                if !notification.message.isEmpty { Text(notification.message).font(.body).foregroundColor(.onSurfaceVariant) }
                if !notification.actions.isEmpty {
                    Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                        actionButton(notification.actions[0])
                        if notification.actions.count > 1 {
                            actionButton(notification.actions[1])
                        }
                    }
                }
            }.flex(1, shrink: 1, basis: 0)
            if notification.isDismissible {
                Button(icon: .resource(UIIcons.Action.x), size: 12, tooltip: "Dismiss notification") { controller.dismiss(notification.id) }
                    .buttonStyle(.ghost).controlSize(.small)
                    .debugName("toast-dismiss-\(notification.id)")
            }
        // Opaque on purpose: a toast must stay readable over whatever it covers.
        }.padding(14).background(.surfaceFloating).cornerRadius(.groupRadius).border(.border, width: 1)
            .shadow(color: theme.elevation.low.color ?? .clear, offsetY: 2, blur: 10)
            .onHover { controller.setPaused($0, id: notification.id) }
        }
    }

    private func actionButton(_ action: ToastAction) -> some View {
        Button(action.title, role: action.role) {
            action.action()
            if action.dismissesNotification {
                controller.dismiss(notification.id)
            }
        }
        .buttonStyle(.ghost)
        .controlSize(.small)
        .accessibilityLabel(action.title)
        .debugName("toast-action-\(notification.id)-\(action.id)")
    }
}

private final class ToastClock: NodeResource, AnyAnimationController {
    private weak var controller: ToastController?
    var isFinished = true
    func mount(node: Node) {}
    func configure(_ controller: ToastController) {
        self.controller = controller
        if controller.needsClock && isFinished { isFinished = false; AnimatorScheduler.current.register(self) }
        else if !controller.needsClock { cancel() }
    }
    func tick(deltaTime: Double) {
        guard !isFinished, let controller else { return }
        controller.advance(by: deltaTime)
        if !controller.needsClock { cancel() }
    }
    func unmount(node: Node) { cancel(); controller = nil }
    func finishImmediately() { cancel() }
    func cancel() { isFinished = true }
}
