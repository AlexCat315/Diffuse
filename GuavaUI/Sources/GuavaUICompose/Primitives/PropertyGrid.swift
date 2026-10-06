import Foundation
import GuavaUIRuntime

private enum PropertyGridIcons {
    static let chevronDown = BundleImageResource.svg(named: "chevron-down",
                                                      in: GuavaUIComposeResourceBundle.bundle,
                                                      subdirectory: "UIIcons")
    static let chevronRight = BundleImageResource.svg(named: "chevron-right",
                                                       in: GuavaUIComposeResourceBundle.bundle,
                                                       subdirectory: "UIIcons")
}

public enum PropertyGridRowLayout: Sendable {
    case twoColumn
    case fullWidth
}

public enum PropertyGridRowSizing: Sendable {
    /// Keep the row at `rowHeight` (or the grid's default row height).
    case fixed
    /// Measure the value's content. `rowHeight` becomes a minimum, allowing
    /// disclosure editors to grow/shrink without an external height formula.
    case intrinsic
}

public struct PropertyGridRow: Identifiable {
    public let id: String
    public let label: String
    public let rowHeight: Float?
    public let layout: PropertyGridRowLayout
    public let sizing: PropertyGridRowSizing
    public let value: AnyView

    public init<ValueContent: View>(id: String,
                                    label: String,
                                    rowHeight: Float? = nil,
                                    layout: PropertyGridRowLayout = .twoColumn,
                                    sizing: PropertyGridRowSizing = .fixed,
                                    @ViewBuilder value: () -> ValueContent) {
        self.id = id
        self.label = label
        self.rowHeight = rowHeight
        self.layout = layout
        self.sizing = sizing
        self.value = AnyView(value())
    }
}

public struct PropertyGridSection: Identifiable {
    public let id: String
    public let title: String
    public let rows: [PropertyGridRow]
    public let children: [PropertyGridSection]
    public let headerLeading: AnyView?
    public let headerTrailing: AnyView?
    public let footer: AnyView?
    public let badge: String?
    public let showsRowCount: Bool
    /// When `true`, the header renders a collapse chevron and rows can be
    /// hidden by clicking it. `false` disables the affordance entirely.
    public let isCollapsible: Bool
    /// Initial collapse state. Only relevant when `isCollapsible` is `true`.
    public let startsCollapsed: Bool

    public init(id: String,
                title: String,
                rows: [PropertyGridRow],
                isCollapsible: Bool = false,
                startsCollapsed: Bool = false,
                children: [PropertyGridSection] = [],
                headerLeading: AnyView? = nil,
                headerTrailing: AnyView? = nil,
                footer: AnyView? = nil,
                badge: String? = nil,
                showsRowCount: Bool = true) {
        self.id = id
        self.title = title
        self.rows = rows
        self.children = children
        self.headerLeading = headerLeading
        self.headerTrailing = headerTrailing
        self.footer = footer
        self.badge = badge
        self.showsRowCount = showsRowCount
        self.isCollapsible = isCollapsible
        self.startsCollapsed = startsCollapsed
    }
}

public enum PropertyGridScrollAxes {
    case vertical
    case horizontal
    case both
}

/// Two-column inspector grid with collapsible section headers.
/// The call site owns the value controls; the primitive only handles layout.
public struct PropertyGrid: View {
    public let sections: [PropertyGridSection]
    public let labelWidth: Float
    public let minValueWidth: Float
    public let rowHeight: Float
    public let rowSpacing: Float
    public let sectionSpacing: Float
    public let contentPadding: Float
    public let scrollAxes: PropertyGridScrollAxes
    public let emptyText: String
    /// When provided, expansion is controlled by the caller rather than the
    /// grid's local state (useful for search and Expand/Collapse All commands).
    public let collapsedSectionIDs: Set<String>?
    public let onSectionCollapseChanged: ((String, Bool) -> Void)?

    public init(_ sections: [PropertyGridSection],
                labelWidth: Float = 96,
                minValueWidth: Float = 220,
                rowHeight: Float = 24,
                rowSpacing: Float = 1,
                sectionSpacing: Float = 10,
                contentPadding: Float = 8,
                scrollAxes: PropertyGridScrollAxes = .both,
                emptyText: String = "No properties",
                collapsedSectionIDs: Set<String>? = nil,
                onSectionCollapseChanged: ((String, Bool) -> Void)? = nil) {
        self.sections = sections
        self.labelWidth = labelWidth
        self.minValueWidth = minValueWidth
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.sectionSpacing = sectionSpacing
        self.contentPadding = contentPadding
        self.scrollAxes = scrollAxes
        self.emptyText = emptyText
        self.collapsedSectionIDs = collapsedSectionIDs
        self.onSectionCollapseChanged = onSectionCollapseChanged
    }

    public var body: some View {
        _StatefulPropertyGrid(grid: self)
    }
}

// MARK: - Stateful wrapper (tracks per-section collapse state)

private struct _StatefulPropertyGrid: View {
    let grid: PropertyGrid

    // Keyed by section id; true = collapsed
    @State var collapsed: [String: Bool] = [:]

    var body: some View {
        scrollContainer {
            gridContent()
        }
            .flex()
    }

    private func scrollContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Form surface: reserve the scrollbar lane so trailing controls
        // (steppers, selects) are never covered by the bar or its grab area.
        switch grid.scrollAxes {
        case .vertical:
            ScrollView(.vertical, scrollbarGutter: .stable) { content() }
        case .horizontal:
            ScrollView(.horizontal) { content() }
        case .both:
            ScrollView(.both, scrollbarGutter: .stable) { content() }
        }
    }

    private func gridContent() -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: grid.sectionSpacing) {
            if grid.sections.isEmpty {
                emptyState()
            } else {
                sectionViews()
            }
        }
        .frame(minWidth: grid.scrollAxes == .vertical ? 0 : grid.labelWidth + grid.minValueWidth)
        .padding(grid.contentPadding)
    }

    private func emptyState() -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Text(grid.emptyText)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 12)
        .background(.surfaceSunken)
        .cornerRadius(4)
    }

    private func sectionViews() -> [AnyView] {
        grid.sections.map { section in
            let isCollapsed = isSectionCollapsed(section)
            return AnyView(
                sectionView(section, isCollapsed: isCollapsed)
                    .id(section.id)
            )
        }
    }

    private func rowViews(_ rows: [PropertyGridRow], sectionID: String) -> [AnyView] {
        rows.enumerated().map { index, row in
            AnyView(rowView(row, sectionID: sectionID, index: index)
                .id("\(sectionID)/\(row.id)"))
        }
    }

    private func sectionView(_ section: PropertyGridSection,
                              isCollapsed: Bool) -> AnyView {
        AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 4) {
                if let leading = section.headerLeading { leading }
                Button(role: .normal, isEnabled: section.isCollapsible, action: {
                    let next = !isSectionCollapsed(section)
                    collapsed[section.id] = next
                    grid.onSectionCollapseChanged?(section.id, next)
                }) {
                    Row(alignment: .center, spacing: 6) {
                        if section.isCollapsible {
                            Icon(isCollapsed ? PropertyGridIcons.chevronRight : PropertyGridIcons.chevronDown,
                                 size: 12, color: .onSurfaceVariant)
                        }
                        Text(section.title).lineLimit(1).font(.label).foregroundColor(.onSurface)
                            .flex(1, shrink: 1, basis: 0)
                        if let badge = section.badge {
                            Text(badge).font(.caption).foregroundColor(.onSurfaceMuted)
                        } else if section.showsRowCount && !section.rows.isEmpty {
                            Text("\(section.rows.count)").font(.caption).foregroundColor(.onSurfaceMuted)
                        }
                    }
                    .frame(minWidth: 0)
                    .flex(1, shrink: 1, basis: 0)
                }
                .buttonStyle(.plain)
                .frame(height: 26, minWidth: 0)
                .flex(1, shrink: 1, basis: 0)
                .debugName("property-section-header-\(section.id)")
                if let trailing = section.headerTrailing { trailing }
            }
            .padding(horizontal: 8, vertical: 3)
            .frame(height: section.headerLeading == nil && section.headerTrailing == nil ? 26 : 32, minWidth: 0)
            .background(.surfaceVariant.opacity(0.65))

            AnimatedVisibility(isVisible: !isCollapsed) {
                Box(direction: .column, alignItems: .stretch, spacing: grid.rowSpacing) {
                    if section.rows.isEmpty && section.children.isEmpty && section.footer == nil {
                        Text(grid.emptyText)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 8, vertical: 8)
                    } else {
                        rowViews(section.rows, sectionID: section.id)
                    }
                    childViews(section.children)
                    if let footer = section.footer { footer.padding(horizontal: 6, vertical: 4) }
                }
                .padding(horizontal: 2, vertical: 3)
                .background(.surfaceSunken)
            }
        }
        .background(.surfaceSunken)
        .cornerRadius(4))
    }

    private func childViews(_ sections: [PropertyGridSection]) -> [AnyView] {
        sections.map { section in
            AnyView(sectionView(section, isCollapsed: isSectionCollapsed(section))
                .id(section.id).padding(horizontal: 4, vertical: 2))
        }
    }

    private func isSectionCollapsed(_ section: PropertyGridSection) -> Bool {
        grid.collapsedSectionIDs?.contains(section.id)
            ?? collapsed[section.id]
            ?? section.startsCollapsed
    }

    private func rowView(_ row: PropertyGridRow, sectionID: String, index: Int) -> some View {
        let rowHeight = row.rowHeight ?? grid.rowHeight
        let rowKey = "\(sectionID)/\(row.id)"
        switch row.layout {
        case .twoColumn:
            return AnyView(decoratedRow(rowKey, index: index) {
                twoColumnRowView(row, rowHeight: rowHeight)
            })
        case .fullWidth:
            return AnyView(decoratedRow(rowKey, index: index) {
                fullWidthRowView(row, rowHeight: rowHeight)
            })
        }
    }

    private func decoratedRow<Content: View>(_ id: String,
                                             index: Int,
                                             @ViewBuilder content: () -> Content) -> some View {
        _PropertyGridRowHost(baseBackground: .surfaceSunken,
                             hoverBackground: .stateLayerHover,
                             cornerRadius: 4,
                             content: AnyView(content()))
    }

    private func twoColumnRowView(_ row: PropertyGridRow, rowHeight: Float) -> some View {
        let alignment: VerticalAlignment = rowHeight > grid.rowHeight ? .top : .center
        let fixedHeight = row.sizing == .fixed ? rowHeight : nil
        let minimumHeight = row.sizing == .intrinsic ? rowHeight : nil
        return Row(alignment: alignment, spacing: 4) {
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                Text(row.label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 7)
            .frame(width: grid.labelWidth, height: fixedHeight, minHeight: minimumHeight)
            .clipped()

            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                sizedValue(for: row, height: fixedHeight)
                    .flex(1, shrink: 1, basis: 0)
            }
            .frame(height: fixedHeight, minHeight: minimumHeight)
            .padding(horizontal: 0, vertical: 2)
            .flex(1, shrink: 1, basis: 0)
        }
        .frame(height: fixedHeight, minWidth: 0, minHeight: minimumHeight)
    }

    private func fullWidthRowView(_ row: PropertyGridRow, rowHeight: Float) -> some View {
        let labelHeight: Float = row.label.isEmpty ? 0 : 18
        let verticalPadding: Float = 6
        let labelValueSpacing: Float = row.label.isEmpty ? 0 : 6
        let valueHeight: Float? = row.sizing == .fixed
            ? max(grid.rowHeight, rowHeight - labelHeight - labelValueSpacing - verticalPadding * 2)
            : nil
        return Box(direction: .column, alignItems: .stretch, spacing: labelValueSpacing) {
            if !row.label.isEmpty {
                Text(row.label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 7)
                    .frame(height: labelHeight)
            }
            Box(direction: .row, alignItems: .stretch, justifyContent: .flexStart) {
                sizedValue(for: row, height: valueHeight)
                    .flex(1, shrink: 1, basis: 0)
            }
            .frame(height: valueHeight)
            .padding(horizontal: 7, vertical: 0)
        }
        .padding(vertical: verticalPadding)
        .frame(height: row.sizing == .fixed ? rowHeight : nil,
               minHeight: row.sizing == .intrinsic ? rowHeight : nil)
    }

    private func sizedValue(for row: PropertyGridRow, height: Float?) -> AnyView {
        // frame(height: nil) clears an existing content frame in GuavaUI.
        // Intrinsic rows must leave their value's own sizing untouched.
        if let height { return AnyView(row.value.frame(height: height)) }
        return row.value
    }
}

private struct _PropertyGridRowHost: _PrimitiveView {
    let baseBackground: SemanticColorRef
    let hoverBackground: SemanticColorRef
    let cornerRadius: Float
    let content: AnyView

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.cornerRadius = cornerRadius
        applyBackground(to: node, isHovered: node.attachments[Self.hoveredKey] as? Bool ?? false)

        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                node.attachments[Self.hoveredKey] = true
                applyBackground(to: node, isHovered: true)
            case .leave:
                node.attachments[Self.hoveredKey] = false
                applyBackground(to: node, isHovered: false)
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
    }

    func _children(for node: Node) -> [any View] {
        [content]
    }

    private func applyBackground(to node: Node, isHovered: Bool) {
        let colorRef = isHovered ? hoverBackground : baseBackground
        node.animatableSet(\.backgroundColor, to: colorRef.resolve(node.theme))
    }

    private static let hoveredKey = "__property_grid_row_hovered"
}
