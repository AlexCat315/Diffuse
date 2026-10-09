import GuavaUIRuntime

public struct AccordionItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var isEnabled = true
    public let content: AnyView
    public init<C: View>(_ id: ID, _ title: String, isEnabled: Bool = true, @ViewBuilder content: () -> C) {
        self.id = id; self.title = title; self.isEnabled = isEnabled; self.content = AnyView(content())
    }
}
public struct Accordion<ID: Hashable>: View {
    public let items: [AccordionItem<ID>]
    public let expanded: Binding<Set<ID>>
    public var allowsMultiple = false
    public var isEnabled = true
    @State private var focused: ID?
    public init(_ items: [AccordionItem<ID>], expanded: Binding<Set<ID>>, configure: (inout Self) -> Void = { _ in }) {
        self.items = items; self.expanded = expanded; configure(&self)
        precondition(Set(items.map(\.id)).count == items.count, "Accordion IDs must be unique")
    }
    public var body: some View {
        let enabled = items.filter { isEnabled && $0.isEnabled }.map(\.id)
        let tabStop = focused.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        return RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { focused.map { AnyHashable($0) } },
                               onSelect: { focused = $0.base as? ID }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                for item in items {
                    AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        Button(isEnabled: isEnabled && item.isEnabled, action: { toggle(item.id); focused = item.id }) {
                            Row(alignment: .center, spacing: 8) {
                                Text(item.title).font(.label).flex(1, shrink: 1)
                                Icon(expanded.wrappedValue.contains(item.id) ? UICommonIcons.chevronDown : UICommonIcons.chevronRight, size: 12)
                            }.padding(12)
                        }.buttonStyle(AccordionHeaderStyle())
                            .accessibility { $0.state.isExpanded = expanded.wrappedValue.contains(item.id) }
                            .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: tabStop == item.id))
                        AnimatedVisibility(isVisible: expanded.wrappedValue.contains(item.id)) { item.content.padding(12) }
                        Divider()
                    }.id(item.id))
                }
            }.border(.border, width: 1).cornerRadius(8)
        }
    }
    public func toggle(_ id: ID) {
        guard isEnabled, items.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        if expanded.wrappedValue.contains(id) { expanded.wrappedValue.remove(id) }
        else if allowsMultiple { expanded.wrappedValue.insert(id) }
        else { expanded.wrappedValue = [id] }
    }
}
private struct AccordionHeaderStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center) { AnyView(c.label) }.flex(1, shrink: 1)
            .foregroundColor(c.isEnabled ? .onSurface : .onSurfaceDisabled)
            .background(c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}

public struct BreadcrumbItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var isEnabled = true
    public init(_ id: ID, _ title: String, isEnabled: Bool = true) { self.id = id; self.title = title; self.isEnabled = isEnabled }
}
public struct Breadcrumb<ID: Hashable>: View {
    public let items: [BreadcrumbItem<ID>]
    public let onSelect: (ID) -> Void
    public var maxVisibleItems = 4
    @State private var isPresented = false
    public init(_ items: [BreadcrumbItem<ID>], maxVisibleItems: Int = 4, onSelect: @escaping (ID) -> Void) {
        self.items = items; self.maxVisibleItems = max(2, maxVisibleItems); self.onSelect = onSelect
        precondition(Set(items.map(\.id)).count == items.count, "Breadcrumb IDs must be unique")
    }
    public var body: some View {
        let collapsed = items.count > maxVisibleItems
        let trailingStart = collapsed ? items.count - maxVisibleItems + 1 : items.count
        return Row(alignment: .center, spacing: 4) {
            for (index, item) in items.enumerated() where !collapsed || index == 0 || index >= trailingStart {
                AnyView(Row(alignment: .center, spacing: 4) {
                    if index > 0 { Icon(UICommonIcons.chevronRight, size: 10, color: .onSurfaceMuted).accessibilityHidden() }
                    if collapsed && index == trailingStart {
                        Popover(isPresented: $isPresented, width: 240, label: { Text("…").font(.label).padding(horizontal: 8) }) {
                            Menu(items[1..<trailingStart].map { entry in .item(MenuItem(id: entry.id, title: entry.title, isEnabled: entry.isEnabled, action: { onSelect(entry.id); isPresented = false })) }, width: 240)
                        }.accessibilityLabel("Hidden path items")
                        Icon(UICommonIcons.chevronRight, size: 10, color: .onSurfaceMuted).accessibilityHidden()
                    }
                    if index == items.count - 1 { Text(item.title).font(.label).foregroundColor(.onSurface) }
                    else { Button(item.title, isEnabled: item.isEnabled) { onSelect(item.id) }.buttonStyle(.ghost).controlSize(.small) }
                })
            }
        }.accessibility { $0.role = .group; $0.label = "Breadcrumb" }
    }
}

public enum PaginationItem: Hashable, Sendable { case page(Int), leadingGap, trailingGap }
public enum PaginationModel {
    public static func normalized(_ current: Int, total: Int) -> Int { total <= 0 ? 0 : min(total, max(1, current)) }
    public static func items(current: Int, total: Int, siblings: Int = 1) -> [PaginationItem] {
        guard total > 0 else { return [] }
        let siblings = min(10, max(0, siblings)), current = normalized(current, total: total)
        if total <= siblings * 2 + 5 { return (1...total).map { .page($0) } }
        let start = max(2, current - siblings), end = min(total - 1, current + min(siblings, total - current))
        var result: [PaginationItem] = [.page(1)]
        if start == 3 { result.append(.page(2)) } else if start > 3 { result.append(.leadingGap) }
        if start <= end { result.append(contentsOf: (start...end).map { .page($0) }) }
        if end == total - 2 { result.append(.page(total - 1)) } else if end < total - 2 { result.append(.trailingGap) }
        result.append(.page(total)); return result
    }
}
public struct Pagination: View {
    public let page: Binding<Int>
    public let totalPages: Int
    public var siblings = 1
    public var isEnabled = true
    public init(page: Binding<Int>, totalPages: Int, configure: (inout Self) -> Void = { _ in }) {
        self.page = page; self.totalPages = max(0, totalPages); configure(&self); siblings = min(10, max(0, siblings))
    }
    public var body: some View {
        let current = PaginationModel.normalized(page.wrappedValue, total: totalPages)
        return Row(alignment: .center, spacing: 4) {
            Button("Previous", isEnabled: isEnabled && current > 1) { page.wrappedValue = current - 1 }.buttonStyle(.ghost)
            for item in PaginationModel.items(current: current, total: totalPages, siblings: siblings) {
                AnyView(pageItem(item, current: current))
            }
            if totalPages == 0 { Text("No pages").font(.caption).foregroundColor(.onSurfaceMuted) }
            Button("Next", isEnabled: isEnabled && current < totalPages) { page.wrappedValue = current + 1 }.buttonStyle(.ghost)
        }.accessibility { $0.role = .group; $0.label = "Pagination" }
    }
    @ViewBuilder private func pageItem(_ item: PaginationItem, current: Int) -> some View {
        switch item {
        case .page(let value): Button(String(value), isEnabled: isEnabled, isSelected: value == current) { page.wrappedValue = value }
                .buttonStyle(.toggle).accessibilityLabel("Page \(value) of \(totalPages)")
        case .leadingGap, .trailingGap: Text("…").font(.label).padding(horizontal: 5).accessibilityHidden()
        }
    }
}

public struct ButtonGroupItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var isEnabled = true
    public init(_ id: ID, _ title: String, isEnabled: Bool = true) { self.id = id; self.title = title; self.isEnabled = isEnabled }
}
public struct ButtonGroup<ID: Hashable>: View {
    public let items: [ButtonGroupItem<ID>]
    public let selection: Binding<ID?>
    public var isEnabled = true
    public init(_ items: [ButtonGroupItem<ID>], selection: Binding<ID?>, isEnabled: Bool = true) {
        self.items = items; self.selection = selection; self.isEnabled = isEnabled
        precondition(Set(items.map(\.id)).count == items.count, "Button group IDs must be unique")
    }
    public var body: some View {
        let enabled = items.filter { isEnabled && $0.isEnabled }.map(\.id)
        let tabStop = selection.wrappedValue.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        return RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { selection.wrappedValue.map { AnyHashable($0) } },
                               onSelect: { selection.wrappedValue = $0.base as? ID }) {
            Row(alignment: .center, spacing: 2) {
                for item in items {
                    AnyView(Button(item.title, isEnabled: isEnabled && item.isEnabled, isSelected: selection.wrappedValue == item.id) { selection.wrappedValue = item.id }
                        .buttonStyle(.toggle).modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: tabStop == item.id)))
                }
            }.padding(3).background(.surfaceVariant).cornerRadius(8)
        }
    }
}
