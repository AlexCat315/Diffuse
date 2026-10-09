import Foundation
import GuavaUIRuntime

public struct NotificationHost: View {
    public let controller: ToastController
    public var width: Float = 360
    public init(_ controller: ToastController, width: Float = 360) { self.controller = controller; self.width = max(120, width) }
    public var body: some View { ToastPresenter(controller: controller, notifications: controller.notifications, width: width) }
}

private struct ToastPresenter: _PrimitiveView {
    let controller: ToastController
    let notifications: [ToastNotification]
    let width: Float
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
        guard !notifications.isEmpty else { resource?.unmount(node: node); return }
        let bounds = portalWindowBounds(node)
        let actualWidth = min(width, max(120, Float(bounds.width) - 32))
        resource?.present(in: node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current,
                          position: CGPoint(x: max(16, bounds.width - CGFloat(actualWidth) - 16), y: 16),
                          width: actualWidth, content: AnyView(Box(direction: .column, alignItems: .stretch, spacing: 10) {
            for notification in notifications {
                AnyView(ToastCard(notification: notification, controller: controller).id(notification.id))
            }
        }))
    }
}

private struct ToastCard: View {
    let notification: ToastNotification
    let controller: ToastController
    var body: some View {
        Box(direction: .row, alignItems: .flexStart, spacing: 10) {
            Box(direction: .column, alignItems: .stretch, spacing: 5) {
                Text(notification.title).font(.bodyStrong).foregroundColor(notification.tone.color)
                if !notification.message.isEmpty { Text(notification.message).font(.body).foregroundColor(.onSurfaceVariant) }
            }.flex(1, shrink: 1, basis: 0)
            if notification.isDismissible {
                Button(icon: .resource(UICommonIcons.close), size: 12, tooltip: "Dismiss notification") { controller.dismiss(notification.id) }
                    .buttonStyle(.ghost).controlSize(.small)
            }
        }.padding(14).background(.surfaceFloating).cornerRadius(8).border(.border, width: 1)
            .onHover { controller.setPaused($0, id: notification.id) }
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
