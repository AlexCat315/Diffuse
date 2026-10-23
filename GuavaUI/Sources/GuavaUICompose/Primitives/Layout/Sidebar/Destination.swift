private import Foundation
import GuavaUIRuntime

struct SidebarDestination<ID: Hashable>: View {
    let entry: SidebarHierarchy<ID>.Entry
    let selection: Binding<ID?>
    let expanded: Binding<Set<ID>>
    let isTabStop: Bool
    let iconWidth: Float?
    let minimumRowHeight: Float
    let onActivate: (ID) -> Void
    let presentation: SidebarPresentation
    let iconExtent: Float
    let disclosureLane: Bool
    let contextLabel: String
    private var item: SidebarItem<ID> {
        var value = entry.item; value.isEnabled = entry.isEnabled; return value
    }
    private var isExpanded: Bool { expanded.wrappedValue.contains(item.id) }
    /// Only the active leaf paints as selected. Branches that contain it stay
    /// expanded and disclose the path, but three blue rows would read as three
    /// simultaneous selections.
    private var isSelected: Bool { selection.wrappedValue == item.id }
    @State private var showsActions = false
    private var actionsWidth: Float { item.contextMenu.isEmpty ? 0 : 44 }
    /// Title inset that keeps text clear of the absolutely placed accessory and actions.
    private var trailingReservation: Float {
        presentation.isRail ? 0 : actionsWidth + (item.slots.accessory == nil ? 0 : item.slots.accessoryWidth)
    }

    @ViewBuilder
    var body: some View {
        let row = SidebarSelectionRevealHost(isSelected: selection.wrappedValue == item.id, presentation: presentation) {
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                // The hit/selection surface is the whole row, not the label's
                // intrinsic width. Otherwise short items get a shorter hover
                // pill than long ones and the rail never looks like a list.
                destinationButton.flex(1, shrink: 1, basis: 0)
                if !presentation.isRail, let accessory = item.slots.accessory {
                    Box(direction: .row, alignItems: .center, justifyContent: .center) { accessory }
                        .frame(width: item.slots.accessoryWidth)
                        .absolutePosition(top: 0, right: actionsWidth, bottom: 0)
                        .zIndex(1)
                        .debugName("sidebar-accessory-\(item.id)")
                }
                if !presentation.isRail && !item.contextMenu.isEmpty {
                    actionsMenu
                        .frame(width: 44)
                        .absolutePosition(top: 0, right: 0, bottom: 0)
                        .zIndex(1)
                        .debugName("sidebar-actions-\(item.id)")
                }
            }.frame(width: .percent(100))
        }.id(item.id)
        if item.contextMenu.isEmpty { row } else { row.contextMenu(item.contextMenu) }
    }

    private var destinationButton: some View {
        Button(
            isEnabled: item.isEnabled, isSelected: isSelected,
            tooltip: presentation.isRail ? item.badge.map { "\(contextLabel) (\($0))" } ?? contextLabel : nil,
            action: {
                if entry.isBranch {
                    if isExpanded { expanded.wrappedValue.remove(item.id) }
                    else { expanded.wrappedValue.insert(item.id) }
                } else {
                    selection.wrappedValue = item.id
                    onActivate(item.id)
                }
            }
        ) {
            if let width = presentation.railWidth {
                RailDestinationLabel(
                    item: item, showsLabels: presentation.showsLabels, iconExtent: min(iconExtent, width - 16),
                    isExpanded: entry.isBranch ? isExpanded : nil)
            } else {
                Row(alignment: .center, spacing: 10) {
                    if disclosureLane {
                        Box(direction: .row, alignItems: .center, justifyContent: .center) {
                            if entry.isBranch {
                                Icon(isExpanded ? UIIcons.Action.minus : UIIcons.Action.plus, size: .small)
                                    .accessibilityHidden()
                            }
                        }.frame(width: 16).flex(0, shrink: 0)
                    }
                    if let iconWidth {
                        Box(direction: .row, alignItems: .center, justifyContent: .center) {
                            if let leading = item.slots.leading {
                                leading.accessibilityHidden()
                            } else if let icon = item.icon {
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
                    if let trailing = item.slots.trailing {
                        trailing.flex(0, shrink: 0).accessibilityHidden()
                            .debugName("sidebar-trailing-\(item.id)")
                    }
                }.padding(EdgeInsets(leading: Float(min(entry.ancestors.count, 5)) * 16,
                                     trailing: trailingReservation))
            }
        }.buttonStyle(SidebarItemStyle(minimumHeight: minimumRowHeight, presentation: presentation))
            .compositionLocal(ActionControlAccessibility.label, presentation.isRail ? contextLabel : item.title)
            .compositionLocal(ActionControlAccessibility.value, item.badge ?? "")
            .compositionLocal(ActionControlAccessibility.isExpanded, entry.isBranch ? isExpanded : nil)
            .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: isTabStop))
            .debugName("sidebar-item-\(item.id)")
    }

    private var actionsMenu: some View {
        var popover = Popover(
            isPresented: $showsActions,
            isEnabled: item.isEnabled,
            width: 220,
            placement: .bottomTrailing,
            surface: .content, overflow: .flip, triggerStyle: AnyButtonStyle(GhostButtonStyle()),
            label: {
                Icon(UIIcons.Action.moreHorizontal, size: .small)
                    .frame(width: 16, height: 16)
            },
            content: {
                FocusScope(restoresCommands: true) {
                    Menu(item.contextMenu, width: 220,
                         onItemActivated: { showsActions = false },
                         onDismiss: { showsActions = false })
                        // A context menu must occlude the row underneath; the
                        // shared glass surface alone lets the disabled Billing
                        // label read through it on an opaque sidebar.
                        .background(.surfaceFloating)
                        .cornerRadius(.controlRadius)
                }
            })
        popover.triggerDescription = PopoverTriggerDescription(
            label: "Actions for \(item.title)",
            help: "Open item actions")
        return popover
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
                    while let current = ancestor, current.scrollReveal == nil {
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
            return AnyView(RailDestinationStyle(minimumHeight: max(44, minimumHeight),
                                                showsLabels: presentation.showsLabels)
                .makeBody(configuration: c))
        }
        return AnyView(
            Box(direction: .row, alignItems: .center) { AnyView(c.label).flex(1, shrink: 1).frame(minWidth: 0) }
                .flex(1, shrink: 1).frame(minWidth: 0, minHeight: minimumHeight)
                .foregroundColor(c.isEnabled ? c.isSelected ? .onSurface : .onSurfaceVariant : .onSurfaceDisabled)
                .padding(horizontal: 10, vertical: 7)
                .selectionHighlight(
                    .sidebar,
                    isSelected: c.isSelected,
                    isHovered: c.isHovered,
                    isPressed: c.isPressed
                )
                .animation(motion: .fast, value: c.interactionKey)
                .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0))
    }
}
