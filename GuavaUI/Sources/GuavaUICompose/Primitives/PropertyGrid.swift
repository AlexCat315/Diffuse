import GuavaUIRuntime

public struct PropertyGridRow: Identifiable {
    public let id: String
    public let label: String
    public let rowHeight: Float?
    public let value: AnyView

    public init<ValueContent: View>(id: String,
                                    label: String,
                                    rowHeight: Float? = nil,
                                    @ViewBuilder value: () -> ValueContent) {
        self.id = id
        self.label = label
        self.rowHeight = rowHeight
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
    public let showsSectionRowCount: Bool
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
                showsSectionRowCount: Bool = true,
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
        self.showsSectionRowCount = showsSectionRowCount
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

    var body: some View {
        scrollContainer {
            gridContent()
        }
            .flex()
    }

    private func scrollContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch grid.scrollAxes {
        case .vertical:
            ScrollView(.vertical) { content() }
        case .horizontal:
            ScrollView(.horizontal) { content() }
        case .both:
            ScrollView(.both) { content() }
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

    private func rowViews(_ rows: [PropertyGridRow]) -> [AnyView] {
        rows.map { row in
            AnyView(rowView(row))
        }
    }

    private func sectionView(_ section: PropertyGridSection,
                              isCollapsed: Bool) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
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
                        Text(isCollapsed ? "▶" : "▼")
                            .font(.label)
                            .foregroundColor(.onSurfaceVariant)
                            .frame(width: 12)
                    }
                    Text(section.title)
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex()
                    if grid.showsSectionRowCount {
                        Text("\(section.rows.count)")
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                            .padding(horizontal: 6, vertical: 1)
                            .background(.surfaceVariant)
                            .cornerRadius(3)
                    }
                }
                .padding(horizontal: 6, vertical: 4)
                .frame(height: 28)
                .flex()
            }
            .buttonStyle(.plain)
            .frame(height: 28)

            if !isCollapsed {
                Box(direction: .column, alignItems: .stretch, spacing: grid.rowSpacing) {
                    if section.rows.isEmpty {
                        Text(grid.emptyText)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 8, vertical: 8)
                    } else {
                        rowViews(section.rows)
                    }
                }
                .padding(1)
                .background(.divider)
                .cornerRadius(2)
                .clipped()
            }
        }
    }

    private func rowView(_ row: PropertyGridRow) -> some View {
        let rowHeight = row.rowHeight ?? grid.rowHeight
        let alignment: VerticalAlignment = rowHeight > grid.rowHeight ? .top : .center
        return Row(alignment: alignment, spacing: 1) {
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                Text(row.label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
            }
            .padding(horizontal: 8)
            .frame(width: grid.labelWidth, height: rowHeight)
            .background(.surfaceVariant)

            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                row.value
                    .frame(height: rowHeight)
                    .flex(1, shrink: 1, basis: 0)
                    .clipped()
            }
            .frame(height: rowHeight)
            .padding(horizontal: 6, vertical: 2)
            .background(.surfaceSunken)
            .flex(1, shrink: 1, basis: 0)
            .clipped()
        }
        .background(.divider)
        .frame(height: rowHeight)
        .clipped()
        .flex()
    }
}
