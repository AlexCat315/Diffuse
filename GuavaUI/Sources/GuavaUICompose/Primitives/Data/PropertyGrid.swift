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
    /// Fix the value slot to the scaled row height and platform control minimum.
    /// An adaptive stacked label adds its own height above that slot.
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
                                    sizing: PropertyGridRowSizing = .intrinsic,
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
    public let labelPlacement: FieldLabelPlacement
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
                labelPlacement: FieldLabelPlacement = .adaptive,
                rowHeight: Float = 24,
                rowSpacing: Float = 1,
                sectionSpacing: Float = 10,
                contentPadding: Float = 8,
                scrollAxes: PropertyGridScrollAxes = .both,
                emptyText: String = "No properties",
                collapsedSectionIDs: Set<String>? = nil,
                onSectionCollapseChanged: ((String, Bool) -> Void)? = nil) {
        self.sections = sections
        self.labelWidth = labelWidth.isFinite ? max(0, labelWidth) : 96
        self.minValueWidth = minValueWidth.isFinite ? max(1, minValueWidth) : 220
        self.labelPlacement = labelPlacement
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
        ContainerSizeReader { size in
            scrollContainer {
                gridContent(width: max(0, Float(size.width) - (grid.scrollAxes == .horizontal ? 0 : 12)))
            }
            .flex()
        }.flex()
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

    private func gridContent(width: Float) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: grid.sectionSpacing) {
            if grid.sections.isEmpty {
                emptyState()
            } else {
                sectionViews()
            }
        }
        .frame(width: width, minWidth: 0)
        .padding(grid.contentPadding)
    }

    private func emptyState() -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Text(grid.emptyText)
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
        }
        .padding(horizontal: 10, vertical: 12)
        .background(.surface)
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
                            Text(badge).font(.caption).foregroundColor(.onSurfaceVariant)
                        } else if section.showsRowCount && !section.rows.isEmpty {
                            Text("\(section.rows.count)").font(.caption).foregroundColor(.onSurfaceVariant)
                        }
                    }
                    .frame(minWidth: 0)
                    .flex(1, shrink: 1, basis: 0)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 0, minHeight: 26)
                .flex(1, shrink: 1, basis: 0)
                .debugName("property-section-header-\(section.id)")
                if let trailing = section.headerTrailing { trailing }
            }
            .padding(horizontal: 8, vertical: 3)
            .frame(minWidth: 0, minHeight: section.headerLeading == nil && section.headerTrailing == nil ? 26 : 32)
            .background(.surfaceRaised)

            AnimatedVisibility(isVisible: !isCollapsed) {
                Box(direction: .column, alignItems: .stretch, spacing: grid.rowSpacing) {
                    if section.rows.isEmpty && section.children.isEmpty && section.footer == nil {
                        Text(grid.emptyText)
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                            .padding(horizontal: 8, vertical: 8)
                    } else {
                        rowViews(section.rows, sectionID: section.id)
                    }
                    childViews(section.children)
                    if let footer = section.footer { footer.padding(horizontal: 6, vertical: 4) }
                }
                .padding(horizontal: 2, vertical: 3)
                .background(.surface)
            }
        }
        .background(.surface)
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
        let rowKey = "\(sectionID)/\(row.id)"
        return TextScalerReader { scaler in
            SurfaceReader { surface in
                let rowHeight = max(scaler.scale(row.rowHeight ?? grid.rowHeight), surface.minimumControlExtent)
                switch row.layout {
                case .twoColumn:
                    AnyView(
                        decoratedRow(rowKey, index: index) {
                            twoColumnRowView(row, rowHeight: rowHeight, labelWidth: scaler.scale(grid.labelWidth))
                        })
                case .fullWidth:
                    AnyView(
                        decoratedRow(rowKey, index: index) {
                            fullWidthRowView(
                                row, rowHeight: rowHeight, labelHeight: scaler.scale(18),
                                minimumValueHeight: max(scaler.scale(grid.rowHeight), surface.minimumControlExtent))
                        })
                }
            }
        }
    }

    private func decoratedRow<Content: View>(
        _ id: String,
        index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        _PropertyGridRowHost(
            baseBackground: .surfaceSunken,
            hoverBackground: .stateLayerHover,
            cornerRadius: 4,
            content: AnyView(content()))
    }

    private func twoColumnRowView(_ row: PropertyGridRow, rowHeight: Float, labelWidth: Float) -> some View {
        let fixedHeight = row.sizing == .fixed ? rowHeight : nil
        return ContainerSizeReader { size in
            let leading = grid.labelPlacement.isLeading(
                width: Float(size.width), labelWidth: labelWidth,
                minValueWidth: grid.minValueWidth, spacing: 4)
            Box(direction: leading ? .row : .column, alignItems: leading ? .center : .stretch, spacing: leading ? 4 : 6)
            {
                Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                    Text(row.label)
                        .lineLimit(leading ? 1 : nil)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .padding(horizontal: 7)
                .frame(width: leading ? .points(labelWidth) : .auto, minHeight: leading ? rowHeight : 0)
                .clipped()
                .tooltip(row.label)
                .flex(0, shrink: 0)

                Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                    sizedValue(for: row, height: fixedHeight)
                        .flex(1, shrink: 1, basis: 0)
                }
                .frame(height: fixedHeight, minHeight: rowHeight)
                .padding(horizontal: leading ? 0 : 7, vertical: 2)
                .flex(leading ? 1 : 0, shrink: 1, basis: leading ? 0 : nil)
            }
            .frame(minWidth: 0)
        }
    }

    private func fullWidthRowView(
        _ row: PropertyGridRow, rowHeight: Float, labelHeight: Float,
        minimumValueHeight: Float
    ) -> some View {
        let labelHeight: Float = row.label.isEmpty ? 0 : labelHeight
        let verticalPadding: Float = 6
        let labelValueSpacing: Float = row.label.isEmpty ? 0 : 6
        let rowHeight = max(rowHeight, labelHeight + labelValueSpacing + verticalPadding * 2 + minimumValueHeight)
        let valueHeight: Float? =
            row.sizing == .fixed
            ? rowHeight - labelHeight - labelValueSpacing - verticalPadding * 2
            : nil
        return Box(direction: .column, alignItems: .stretch, spacing: labelValueSpacing) {
            if !row.label.isEmpty {
                Text(row.label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
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
        .frame(
            height: row.sizing == .fixed ? .points(rowHeight) : .auto,
            minHeight: row.sizing == .intrinsic ? rowHeight : 0)
    }

    private func sizedValue(for row: PropertyGridRow, height: Float?) -> AnyView {
        let value = row.value.accessibility {
            $0.label = row.label; $0.identifier = row.id
        }
        // Intrinsic rows leave their value's own sizing untouched.
        if let height { return AnyView(value.frame(height: height)) }
        return AnyView(value)
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
        if !node.supportsControlHover { node.attachments[Self.hoveredKey] = false }
        applyBackground(to: node, isHovered: node.attachments[Self.hoveredKey] as? Bool ?? false)

        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                node.attachments[Self.hoveredKey] = node.supportsControlHover
                applyBackground(to: node, isHovered: node.supportsControlHover)
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
