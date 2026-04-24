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

/// Two-column inspector grid with collapsible section headers.
/// The call site owns the value controls; the primitive only handles layout.
public struct PropertyGrid: View {
    public let sections: [PropertyGridSection]
    public let labelWidth: Float
    public let rowHeight: Float
    public let rowSpacing: Float
    public let onSectionCollapseChanged: ((String, Bool) -> Void)?

    public init(_ sections: [PropertyGridSection],
                labelWidth: Float = 96,
                rowHeight: Float = 24,
                rowSpacing: Float = 1,
                onSectionCollapseChanged: ((String, Bool) -> Void)? = nil) {
        self.sections = sections
        self.labelWidth = labelWidth
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
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
        ScrollView(.both) {
            Box(direction: .column, alignItems: .stretch, spacing: 12) {
                sectionViews()
            }
            .frame(minWidth: grid.labelWidth + 220)
            .padding(8)
        }
        .flex()
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
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            // Header
            Button(role: .normal,
                   isEnabled: section.isCollapsible,
                   action: {
                let current = collapsed[section.id] ?? section.startsCollapsed
                let next = !current
                collapsed[section.id] = next
                grid.onSectionCollapseChanged?(section.id, next)
            }) {
                Row(alignment: .center, spacing: 4) {
                    if section.isCollapsible {
                        Text(isCollapsed ? "▶" : "▼")
                            .font(.label)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    Text(section.title)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex()
                }
                .padding(horizontal: section.isCollapsible ? 2 : 0, vertical: 2)
            }
            .buttonStyle(.ghost)

            // Rows (hidden when collapsed)
            if !isCollapsed {
                Box(direction: .column, alignItems: .stretch, spacing: grid.rowSpacing) {
                    rowViews(section.rows)
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
        return Row(alignment: .center, spacing: 1) {
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                Text(row.label)
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
            .padding(horizontal: 6)
            .background(.surface)
            .flex(1, shrink: 1, basis: 0)
            .clipped()
        }
        .background(.divider)
        .frame(height: rowHeight)
        .clipped()
        .flex()
    }
}
