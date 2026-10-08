import Foundation
import GuavaUIRuntime

public enum AvatarOverflow: Sendable, Hashable { case count, ellipsis, hidden }
public struct AvatarGroupOptions {
    public var limit = 3
    public var overflow: AvatarOverflow = .count
    public var overlap: Float = 0.3
    public var size: ControlSize?
    public var diameter: Float?
    public var label = "Members"
    public init() {}
    mutating func validate() {
        limit = max(0, limit)
        overlap = overlap.isFinite ? max(0, min(0.7, overlap)) : 0.3
        if let diameter { self.diameter = diameter.isFinite ? max(12, min(512, diameter)) : nil }
    }
}

/// Shared sizing, stable optional IDs, first-person-on-top overlap and a
/// count/ellipsis overflow slot. A zero limit can display only the overflow.
public struct AvatarGroup: _PrimitiveView {
    public let avatars: [Avatar]
    public var options = AvatarGroupOptions()
    public init(_ avatars: [Avatar], configure: (inout AvatarGroupOptions) -> Void = { _ in }) {
        self.avatars = avatars; configure(&options); options.validate()
    }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateNode(_ node: Node) {
        let geometry = geometry(in: node)
        node.layoutNode?.width = geometry.width; node.layoutNode?.height = geometry.itemCount == 0 ? 0 : geometry.diameter
        node.accessibility = AccessibilitySemantics(.group) { $0.label = options.label; $0.value = "\(avatars.count) members" }
        node.attachments["avatar.group.count"] = avatars.count
    }
    public func _children(for node: Node) -> [any View] {
        let geometry = geometry(in: node)
        var children: [any View] = avatars.prefix(geometry.visibleCount).enumerated().map { index, item in
            var item = item // Copy the complete avatar, preserving appearance and source.
            item.appearance.diameter = geometry.diameter
            return AvatarGroupSlot(x: Float(index) * geometry.step, diameter: geometry.diameter,
                                   zIndex: Float(geometry.visibleCount - index), content: AnyView(item))
                .id(item.id ?? "slot-\(index)")
        }
        if geometry.hasOverflow {
            let remaining = avatars.count - geometry.visibleCount
            let text = options.overflow == .ellipsis ? "⋯" : "+\(remaining)"
            let names = avatars.dropFirst(geometry.visibleCount).prefix(20).map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
            let marker = AvatarOverflowMarker(text: text, diameter: geometry.diameter, count: remaining,
                                              names: names, colors: AvatarColors(background: node.theme.colors.surfaceVariant,
                                                 foreground: node.theme.colors.onSurfaceVariant, border: node.theme.colors.border))
            children.append(AvatarGroupSlot(x: geometry.overflowX, diameter: geometry.diameter, zIndex: 0,
                                            content: AnyView(marker)).id("avatar.overflow"))
        }
        return children
    }
    private func geometry(in node: Node) -> AvatarGroupGeometry {
        var options = options; options.validate()
        var appearance = AvatarAppearance(); appearance.size = options.size; appearance.diameter = options.diameter
        return AvatarGroupGeometry(total: avatars.count, limit: options.limit, diameter: appearance.resolvedDiameter(in: node),
                                   overlap: options.overlap, overflow: options.overflow)
    }
}

struct AvatarGroupGeometry {
    let visibleCount: Int
    let hasOverflow: Bool
    let diameter: Float
    let step: Float
    init(total: Int, limit: Int, diameter: Float, overlap: Float, overflow: AvatarOverflow) {
        visibleCount = min(total, max(0, limit)); hasOverflow = total > visibleCount && overflow != .hidden
        self.diameter = diameter; step = diameter * (1 - overlap)
    }
    var itemCount: Int { visibleCount + (hasOverflow ? 1 : 0) }
    var visibleWidth: Float { visibleCount == 0 ? 0 : diameter + Float(visibleCount - 1) * step }
    var overflowX: Float { visibleCount == 0 ? 0 : visibleWidth + 4 }
    var width: Float { hasOverflow ? overflowX + diameter : visibleWidth }
}
private struct AvatarGroupSlot: _PrimitiveView {
    let x: Float
    let diameter: Float
    let zIndex: Float
    let content: AnyView
    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) { node.zIndex = zIndex }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); _updateLayout(layout); return layout }
    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute; layout.setPosition(x, edge: .left); layout.setPosition(0, edge: .top)
        layout.width = diameter; layout.height = diameter
    }
    var _children: [any View] { [content] }
}
private struct AvatarOverflowMarker: View {
    let text: String
    let diameter: Float
    let count: Int
    let names: String
    let colors: AvatarColors
    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text(text, lineLimit: 1).font(.system(size: min(diameter * 0.36, diameter / Float(max(2, text.count)) * 1.15)))
                .foregroundColor(colors.foreground)
        }.frame(width: diameter, height: diameter).background(colors.background).cornerRadius(diameter / 2)
            .border(colors.border, width: 1)
            .accessibility { $0.role = .image; $0.label = "\(count) more members"; $0.help = names; $0.combinesChildren = true }
            .tooltip(names.isEmpty ? "\(count) more members" : names)
    }
}
