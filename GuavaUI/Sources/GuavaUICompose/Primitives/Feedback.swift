import Foundation
import GuavaUIRuntime

public enum StatusTone: Sendable, Hashable, CaseIterable {
    case neutral, info, success, warning, danger
    public var color: SemanticColorRef {
        switch self {
        case .neutral: .onSurfaceVariant
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .error
        }
    }
}

public struct Badge: View {
    public let title: String
    public let tone: StatusTone
    public init(_ title: String, tone: StatusTone = .neutral) { self.title = title; self.tone = tone }
    public var body: some View {
        Text(title).font(.caption).foregroundColor(tone.color)
            .padding(horizontal: 7, vertical: 3).background(tone.color.opacity(0.12)).cornerRadius(5)
    }
}

public struct Alert: View {
    public let title: String
    public let message: String
    public let tone: StatusTone
    public init(_ title: String, message: String = "", tone: StatusTone = .info) {
        self.title = title; self.message = message; self.tone = tone
    }
    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 5) {
            Text(title).font(.bodyStrong).foregroundColor(tone.color)
            if !message.isEmpty { Text(message).font(.body).foregroundColor(.onSurfaceVariant) }
        }.padding(12).background(tone.color.opacity(0.08)).cornerRadius(8)
            .border(tone.color.opacity(0.25), width: 1)
    }
}

public struct EmptyState<Action: View>: View {
    public let title: String
    public let message: String
    private let action: Action
    public init(_ title: String, message: String = "", @ViewBuilder action: () -> Action) {
        self.title = title; self.message = message; self.action = action()
    }
    public var body: some View {
        Column(alignment: .center, spacing: 10) {
            Text(title).font(.headline).foregroundColor(.onSurface)
            if !message.isEmpty { Text(message).font(.body).foregroundColor(.onSurfaceMuted) }
            action
        }.padding(24).frame(minWidth: 0)
    }
}

/// Determinate progress. Invalid numbers resolve to zero and finite values clamp to 0...1.
public struct ProgressView: _PrimitiveView {
    public let value: Double
    public init(value: Double) { self.value = value.isFinite ? min(1, max(0, value)) : 0 }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.height = 6; return layout }
    public func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.progress) { $0.label = "Progress"; $0.value = String(value) }
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            let rect = UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height))
            list.addRoundedRect(rect, radius: rect.height / 2, color: node.theme.colors.surfaceVariant.multipliedAlpha(node.opacity))
            if value > 0 {
                list.addRoundedRect(UIRect(x: rect.x, y: rect.y, width: rect.width * Float(value), height: rect.height),
                                    radius: rect.height / 2, color: node.theme.colors.accent.multipliedAlpha(node.opacity))
            }
        }
    }
}

/// Animation is registered with the owning node and cancelled when it leaves the tree.
public struct Spinner: _PrimitiveView {
    public let size: Float
    public let isAnimating: Bool
    public init(size: Float = 16, isAnimating: Bool = true) {
        self.size = size.isFinite ? max(8, min(128, size)) : 16; self.isAnimating = isAnimating
    }
    public func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.addResource(LoadingAnimationClock()); return node
    }
    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.width = size; layout.height = size; return layout
    }
    public func _updateNode(_ node: Node) {
        let clock = node.firstResource(LoadingAnimationClock.self)!
        clock.configure(duration: 1, isActive: isAnimating && !node.prefersReducedMotion)
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            let phase = Float(clock.phase) * Float.pi * 2
            let cx = Float(origin.x + node.frame.width / 2), cy = Float(origin.y + node.frame.height / 2)
            let radius = max(2, min(Float(node.frame.width), Float(node.frame.height)) / 2 - 2)
            let color = (node.foregroundColor ?? node.theme.colors.onSurface).multipliedAlpha(node.opacity)
            for i in 0..<24 {
                let start = phase + Float(i) / 24 * Float.pi * 1.5
                let end = phase + Float(i + 1) / 24 * Float.pi * 1.5
                list.addLine(fromX: cx + cos(start) * radius, fromY: cy + sin(start) * radius,
                             toX: cx + cos(end) * radius, toY: cy + sin(end) * radius,
                             thickness: 2, color: color.multipliedAlpha(Float(i + 1) / 24))
            }
        }
    }
}
