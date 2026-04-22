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
                labelWidth: Float = 128,
                rowHeight: Float = 30,
                rowSpacing: Float = 1) {
        self.sections = sections
        self.labelWidth = labelWidth
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
    }

    public var body: some View {
        ScrollView(.vertical) {
            Column(spacing: 10) {
                sectionViews()
            }
            .padding(8)
        }
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
        Column(spacing: rowSpacing) {
            Text(section.title)
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
            rowViews(section.rows)
        }
    }

    private func rowView(_ row: PropertyGridRow) -> some View {
        Row(alignment: .center, spacing: 12) {
            Text(row.label)
                .font(.body)
                .frame(width: labelWidth, height: rowHeight)
            row.value
                .frame(height: rowHeight)
                .flex()
        }
        .padding(horizontal: 8)
        .background(.surfaceVariant)
    }
}