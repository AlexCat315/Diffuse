import Foundation
import GuavaUIRuntime

private enum PropertyGridIcons {
    static let chevronDown = BundleImageResource.svg(named: "chevron-down",
                                                      in: .module,
                                                      subdirectory: "UIIcons")
    static let chevronRight = BundleImageResource.svg(named: "chevron-right",
                                                       in: .module,
                                                       subdirectory: "UIIcons")
}

public enum PropertyGridRowLayout: Sendable {
    case twoColumn
    case fullWidth
}

public struct PropertyGridRow: Identifiable {
    public let id: String
    public let label: String
    public let rowHeight: Float?
    public let layout: PropertyGridRowLayout
    public let value: AnyView

    public init<ValueContent: View>(id: String,
                                    label: String,
                                    rowHeight: Float? = nil,
                                    layout: PropertyGridRowLayout = .twoColumn,
                                    @ViewBuilder value: () -> ValueContent) {
        self.id = id
        self.label = label
        self.rowHeight = rowHeight
        self.layout = layout
        self.value = AnyView(value())
    }
}

public struct PropertyGridSection: Identifiable {
    public let id: String
    public let title: String
    public let rows: [PropertyGridRow]
    /// When `true`, the header renders a collapse chevron and rows can be
    /// hidden by clicking it. `false` disables the affordance entirely.
    public let isCollapsible: Bool
    /// Initial collapse state. Only relevant when `isCollapsible` is `true`.
    public let startsCollapsed: Bool

    public init(id: String,
                title: String,
                rows: [PropertyGridRow],
                isCollapsible: Bool = false,
                startsCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.rows = rows
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
    @State var hoveredRowID: String? = nil

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
        .frame(minWidth: grid.labelWidth + grid.minValueWidth)
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
            let isCollapsed = collapsed[section.id] ?? section.startsCollapsed
            return AnyView(
                sectionView(section, isCollapsed: isCollapsed)
                    .id(section.id)
            )
        }
    }

    private func rowViews(_ rows: [PropertyGridRow], sectionID: String) -> [AnyView] {
        rows.enumerated().map { index, row in
            AnyView(rowView(row, sectionID: sectionID, index: index))
        }
    }

    private func sectionView(_ section: PropertyGridSection,
                              isCollapsed: Bool) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Button(role: .normal,
                   isEnabled: section.isCollapsible,
                   action: {
                let current = collapsed[section.id] ?? section.startsCollapsed
                let next = !current
                collapsed[section.id] = next
                grid.onSectionCollapseChanged?(section.id, next)
            }) {
                Row(alignment: .center, spacing: 6) {
                    if section.isCollapsible {
                        Icon(isCollapsed ? PropertyGridIcons.chevronRight : PropertyGridIcons.chevronDown,
                             size: 12,
                             color: .onSurfaceVariant)
                    }
                    Text(section.title)
                        .font(.label)
                        .foregroundColor(.onSurface)
                        .flex()
                    if !section.rows.isEmpty {
                        Text("\(section.rows.count)")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
                .padding(horizontal: 8, vertical: 3)
                .frame(height: 26)
                .flex()
            }
            .buttonStyle(.plain)
            .frame(height: 26)
            .background(.surfaceVariant)

            if !isCollapsed {
                Box(direction: .column, alignItems: .stretch, spacing: grid.rowSpacing) {
                    if section.rows.isEmpty {
                        Text(grid.emptyText)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 8, vertical: 8)
                    } else {
                        rowViews(section.rows, sectionID: section.id)
                    }
                }
                .padding(horizontal: 2, vertical: 3)
                .background(.surface)
            }
        }
        .background(.surface)
        .cornerRadius(6)
        .border(.divider, width: 1)
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
        let isHovered = hoveredRowID == id
        let background: SemanticColorRef = isHovered
            ? .stateLayerHover
            : (index.isMultiple(of: 2) ? .surface : .surfaceOverlay)
        return content()
            .background(background)
            .cornerRadius(4)
            .onHover { hovered in
                if hovered {
                    hoveredRowID = id
                } else if hoveredRowID == id {
                    hoveredRowID = nil
                }
            }
    }

    private func twoColumnRowView(_ row: PropertyGridRow, rowHeight: Float) -> some View {
        let alignment: VerticalAlignment = rowHeight > grid.rowHeight ? .top : .center
        return Row(alignment: alignment, spacing: 4) {
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                Text(row.label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 7)
            .frame(width: grid.labelWidth, height: rowHeight)

            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                row.value
                    .frame(height: rowHeight)
                    .flex(1, shrink: 1, basis: 0)
            }
            .frame(height: rowHeight)
            .padding(horizontal: 0, vertical: 2)
            .flex(1, shrink: 1, basis: 0)
        }
        .frame(height: rowHeight)
        .flex()
    }

    private func fullWidthRowView(_ row: PropertyGridRow, rowHeight: Float) -> some View {
        let labelHeight: Float = 18
        let verticalPadding: Float = 6
        let labelValueSpacing: Float = 6
        let valueHeight = max(grid.rowHeight, rowHeight - labelHeight - labelValueSpacing - verticalPadding * 2)
        return Box(direction: .column, alignItems: .stretch, spacing: labelValueSpacing) {
            Text(row.label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 7)
                .frame(height: labelHeight)
            Box(direction: .row, alignItems: .stretch, justifyContent: .flexStart) {
                row.value
                    .frame(height: valueHeight)
                    .flex(1, shrink: 1, basis: 0)
            }
            .frame(height: valueHeight)
            .padding(horizontal: 7, vertical: 0)
        }
        .padding(vertical: verticalPadding)
        .frame(height: rowHeight)
        .flex()
    }
}
