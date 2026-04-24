import Foundation
import GuavaUIRuntime

public struct AssetDropPayload: Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let kind: String

    public init(id: String,
                name: String,
                subtitle: String? = nil,
                kind: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
    }
}

public final class AssetDropRegistry: @unchecked Sendable {
    private final class Zone {
        weak var node: Node?
        var acceptedKinds: Set<String>
        var isEnabled: Bool
        var onDrop: (AssetDropPayload) -> Void

        init(node: Node,
             acceptedKinds: Set<String>,
             isEnabled: Bool,
             onDrop: @escaping (AssetDropPayload) -> Void) {
            self.node = node
            self.acceptedKinds = acceptedKinds
            self.isEnabled = isEnabled
            self.onDrop = onDrop
        }
    }

    private var zones: [ObjectIdentifier: Zone] = [:]

    public init() {}

    public func register(node: Node,
                         acceptedKinds: Set<String> = [],
                         isEnabled: Bool = true,
                         onDrop: @escaping (AssetDropPayload) -> Void) {
        zones[ObjectIdentifier(node)] = Zone(node: node,
                                             acceptedKinds: acceptedKinds,
                                             isEnabled: isEnabled,
                                             onDrop: onDrop)
    }

    public func unregister(node: Node) {
        zones.removeValue(forKey: ObjectIdentifier(node))
    }

    @discardableResult
    public func drop(_ payload: AssetDropPayload, atX x: Float, y: Float) -> Bool {
        pruneReleasedNodes()
        guard let zone = hitZone(for: payload, x: x, y: y) else { return false }
        zone.onDrop(payload)
        return true
    }

    public func canDrop(_ payload: AssetDropPayload, on node: Node) -> Bool {
        guard let zone = zones[ObjectIdentifier(node)], zone.isEnabled else { return false }
        return accepts(payload.kind, zone: zone)
    }

    private func hitZone(for payload: AssetDropPayload, x: Float, y: Float) -> Zone? {
        var result: Zone?
        for zone in zones.values {
            guard zone.isEnabled,
                  accepts(payload.kind, zone: zone),
                  let node = zone.node,
                  absoluteRect(for: node).contains(x: x, y: y)
            else {
                continue
            }
            result = zone
        }
        return result
    }

    private func accepts(_ kind: String, zone: Zone) -> Bool {
        zone.acceptedKinds.isEmpty || zone.acceptedKinds.contains(kind)
    }

    private func pruneReleasedNodes() {
        zones = zones.filter { _, zone in zone.node != nil }
    }

    private func absoluteRect(for node: Node) -> UIRect {
        var x = Float(node.frame.origin.x)
        var y = Float(node.frame.origin.y)
        var parent = node.parent
        while let p = parent {
            x += Float(p.frame.origin.x) - Float(p.contentOffset.x)
            y += Float(p.frame.origin.y) - Float(p.contentOffset.y)
            parent = p.parent
        }
        return UIRect(x: x,
                      y: y,
                      width: Float(node.frame.width),
                      height: Float(node.frame.height))
    }
}

public enum AssetDropRegistryHolder {
    nonisolated(unsafe) public static var current: AssetDropRegistry?
}

public struct AssetDropTarget<Content: View>: View {
    public let activePayload: Binding<AssetDropPayload?>
    public let acceptedKinds: Set<String>
    public let isEnabled: Bool
    public let onDrop: (AssetDropPayload) -> Void
    public let content: Content

    public init(activePayload: Binding<AssetDropPayload?>,
                acceptedKinds: Set<String> = [],
                isEnabled: Bool = true,
                onDrop: @escaping (AssetDropPayload) -> Void,
                @ViewBuilder content: () -> Content) {
        self.activePayload = activePayload
        self.acceptedKinds = acceptedKinds
        self.isEnabled = isEnabled
        self.onDrop = onDrop
        self.content = content()
    }

    public var body: some View {
        AssetDropTargetHost(target: self)
    }
}

private struct AssetDropTargetHost<Content: View>: _PrimitiveView {
    let target: AssetDropTarget<Content>

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        guard let registry = AssetDropRegistryHolder.current else { return }
        registry.register(node: node,
                          acceptedKinds: target.acceptedKinds,
                          isEnabled: target.isEnabled,
                          onDrop: target.onDrop)

        let snapshot = target
        node.overlayDraw = { [weak node] list, origin in
            guard let node else { return }
            drawDropChrome(for: snapshot,
                           node: node,
                           list: list,
                           originX: Float(origin.x),
                           originY: Float(origin.y))
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }

    var _children: [any View] { [target.content] }
}

private func drawDropChrome<Content: View>(for target: AssetDropTarget<Content>,
                                           node: Node,
                                           list: DrawList,
                                           originX: Float,
                                           originY: Float) {
    guard let payload = target.activePayload.wrappedValue, target.isEnabled else { return }
    let accepts = target.acceptedKinds.isEmpty || target.acceptedKinds.contains(payload.kind)
    let colors = node.theme.colors
    let frame = node.frame
    let rect = UIRect(x: originX,
                      y: originY,
                      width: Float(frame.width),
                      height: Float(frame.height))
    let fill = accepts ? colors.accent.multipliedAlpha(0.10) : colors.error.multipliedAlpha(0.08)
    let stroke = accepts ? colors.accent.multipliedAlpha(0.85) : colors.error.multipliedAlpha(0.70)

    list.addRoundedRect(rect, radius: 4, color: fill)
    addBorder(rect: rect, color: stroke, list: list)
}

private func addBorder(rect: UIRect, color: Color, list: DrawList) {
    let t: Float = 1
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.maxY - t, width: rect.width, height: t), color: color)
    list.addRect(UIRect(x: rect.minX, y: rect.minY, width: t, height: rect.height), color: color)
    list.addRect(UIRect(x: rect.maxX - t, y: rect.minY, width: t, height: rect.height), color: color)
}

private extension UIRect {
    func contains(x: Float, y: Float) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}
