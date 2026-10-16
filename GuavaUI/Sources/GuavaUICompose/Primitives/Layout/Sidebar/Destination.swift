private import Foundation
import GuavaUIRuntime

struct SidebarDestination<ID: Hashable>: View {
    let item: SidebarItem<ID>
    let selection: Binding<ID?>
    let isTabStop: Bool
    let iconWidth: Float?
    let minimumRowHeight: Float
    let onActivate: (ID) -> Void
    let presentation: SidebarPresentation
    let iconExtent: Float
    var body: some View {
        SidebarSelectionRevealHost(isSelected: selection.wrappedValue == item.id, presentation: presentation) {
            Button(
                isEnabled: item.isEnabled, isSelected: selection.wrappedValue == item.id,
                tooltip: presentation.isRail ? item.badge.map { "\(item.title) (\($0))" } ?? item.title : nil,
                action: {
                    selection.wrappedValue = item.id
                    onActivate(item.id)
                }
            ) {
                if let width = presentation.railWidth {
                    RailDestinationLabel(
                        item: item, showsLabels: presentation.showsLabels, iconExtent: min(iconExtent, width - 16))
                } else {
                    Row(alignment: .center, spacing: 10) {
                        if let iconWidth {
                            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                                if let icon = item.icon {
                                    Icon(icon, size: item.iconSize).accessibilityHidden()
                                }
                            }.frame(width: iconWidth).flex(0, shrink: 0)
                        }
                        Text(item.title).font(.label).flex(1, shrink: 1).frame(minWidth: 0)
                            .debugName("sidebar-title-\(item.id)")
                        if let badge = item.badge {
                            Badge(badge, tone: .neutral) { $0.isEnabled = item.isEnabled }
                                .flex(0, shrink: 0).accessibilityHidden()
                                .debugName("sidebar-badge-\(item.id)")
                        }
                    }
                }
            }.buttonStyle(SidebarItemStyle(minimumHeight: minimumRowHeight, presentation: presentation))
                .compositionLocal(ActionControlAccessibility.label, item.title)
                .compositionLocal(ActionControlAccessibility.value, item.badge ?? "")
                .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: isTabStop))
                .debugName("sidebar-item-\(item.id)")
        }.id(item.id)
    }
}

private struct SidebarSelectionRevealHost<Content: View>: _PrimitiveView {
    let isSelected: Bool
    let presentation: SidebarPresentation
    @ViewBuilder let content: Content
    private static var key: String { "__sidebar.selected" }
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        let state = node.attachments[Self.key] as? RevealState ?? RevealState()
        node.attachments[Self.key] = state
        let signature = Signature(isSelected: isSelected, presentation: presentation)
        if signature != state.signature {
            state.pending = isSelected
            state.signature = signature
        }
        // Own this hook independently of the Button tooltip. Observe content
        // geometry too: a new style may finish measuring after the first pass.
        node.layoutDidUpdate = { node in
            guard state.signature?.isSelected == true else { return }
            var pending = node.children
            while let candidate = pending.popLast() {
                if candidate.attachments[ButtonHost.markerKey] != nil {
                    var ancestor = candidate.parent
                    while let current = ancestor, current.attachments[ScrollReveal.handlerKey] == nil {
                        ancestor = current.parent
                    }
                    guard let scroll = ancestor, scroll.frame.height > 0, candidate.frame.height > 0 else { return }
                    let rect = candidate.absoluteFrame.offsetBy(
                        dx: scroll.contentOffset.x - scroll.absoluteOrigin.x,
                        dy: scroll.contentOffset.y - scroll.absoluteOrigin.y)
                    let geometry = Geometry(rect: rect, viewport: scroll.frame.size)
                    if state.pending || state.geometry != geometry {
                        state.pending = false
                        state.geometry = geometry
                        ScrollReveal.reveal(candidate, nearestOnly: true)
                    }
                    return
                }
                pending.append(contentsOf: candidate.children.reversed())
            }
        }
    }
    var _children: [any View] { [content] }
    private struct Signature: Equatable {
        let isSelected: Bool
        let presentation: SidebarPresentation
    }
    private final class RevealState {
        var signature: Signature?
        var pending = false
        var geometry: Geometry?
    }
    private struct Geometry: Equatable {
        let rect: CGRect
        let viewport: CGSize
    }
}

struct SidebarItemStyle: ButtonStyle, Hashable {
    var minimumHeight: Float = 38
    var presentation = SidebarPresentation.expanded
    func makeBody(configuration c: ButtonStyleConfiguration) -> AnyView {
        if presentation.isRail {
            return AnyView(RailDestinationStyle(minimumHeight: max(44, minimumHeight)).makeBody(configuration: c))
        }
        return AnyView(
            Box(direction: .row, alignItems: .center) { AnyView(c.label).flex(1, shrink: 1).frame(minWidth: 0) }
                .flex(1, shrink: 1).frame(minWidth: 0, minHeight: minimumHeight)
                .foregroundColor(c.isEnabled ? c.isSelected ? .onSurface : .onSurfaceVariant : .onSurfaceDisabled)
                .padding(horizontal: 10, vertical: 7)
                .selectionHighlight(
                    .navigation,
                    isSelected: c.isSelected,
                    isHovered: c.isHovered,
                    isPressed: c.isPressed
                )
                .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0))
    }
}
