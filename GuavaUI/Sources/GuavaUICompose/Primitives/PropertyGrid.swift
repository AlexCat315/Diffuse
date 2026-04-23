import GuavaUIRuntime

public struct PropertyGridRow: Identifiable {
    public let id: String
    public let label: String
    public let value: AnyView

    public init<ValueContent: View>(id: String,
                                    label: String,
                                    @ViewBuilder value: () -> ValueContent) {
        self.id = id
        self.label = label
        self.value = AnyView(value())
    }
}

public struct PropertyGridSection: Identifiable {
    public let id: String
    public let title: String
    public let rows: [PropertyGridRow]

    public init(id: String,
                title: String,
                rows: [PropertyGridRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// Two-column inspector grid with lightweight section headers.
/// The call site owns the value controls; the primitive only handles layout.
public struct PropertyGrid: View {
    public let sections: [PropertyGridSection]
    public let labelWidth: Float
    public let rowHeight: Float
    public let rowSpacing: Float

    public init(_ sections: [PropertyGridSection],
            labelWidth: Float = 112,
            rowHeight: Float = 28,
                rowSpacing: Float = 1) {
        self.sections = sections
        self.labelWidth = labelWidth
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
    }

    public var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: 12) {
                sectionViews()
            }
            .padding(10)
            .flex()
        }
        .flex()
    }

    private func sectionViews() -> [AnyView] {
        sections.map { section in
            AnyView(sectionView(section))
        }
    }

    private func rowViews(_ rows: [PropertyGridRow]) -> [AnyView] {
        rows.map { row in
            AnyView(rowView(row))
        }
    }

    private func sectionView(_ section: PropertyGridSection) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(section.title)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Box(direction: .column, alignItems: .stretch, spacing: rowSpacing) {
                rowViews(section.rows)
            }
            .padding(1)
            .background(.divider)
            .cornerRadius(2)
            .clipped()
        }
        .flex()
    }

    private func rowView(_ row: PropertyGridRow) -> some View {
        Row(alignment: .center, spacing: 1) {
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                Text(row.label)
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
            }
            .padding(horizontal: 8)
            .frame(width: labelWidth, height: rowHeight)
            .background(.surfaceVariant)

            Box(direction: .row, alignItems: .center, justifyContent: .flexStart) {
                row.value
                    .frame(height: rowHeight)
                    .flex()
            }
            .frame(height: rowHeight)
            .padding(horizontal: 8)
            .background(.surface)
            .flex()
        }
        .background(.divider)
        .flex()
    }
}