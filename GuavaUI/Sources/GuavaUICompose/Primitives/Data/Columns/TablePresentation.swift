internal import GuavaUIRuntime

/// One container query and one visibility menu for both table implementations.
struct TableColumns<Record, Content: View>: View {
    let columns: [TableColumn<Record>]
    let widths: [String: Float]
    let overrides: Binding<[String: Bool]>
    var frozenCount = 0
    var pinnedIDs: Set<String> = []
    let isEnabled: Bool
    let content: (TableColumnPlan) -> Content

    var body: some View {
        SurfaceReader { surface in ContainerSizeReader { size in
            let plan = TableColumnPlan.resolve(columns, widths: widths, overrides: overrides.wrappedValue,
                availableWidth: max(0, Float(size.width) - ScrollView<EmptyView>.stableGutterWidth(on: surface)),
                frozenCount: frozenCount, pinnedIDs: pinnedIDs)
            TableColumnsHost(visibleIDs: Set(plan.indices.map { columns[$0].id })) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    if columns.contains(where: { $0.visibility != .required }) {
                        ColumnVisibilityPicker(columns: TableColumnPlan.tracks(columns, widths: widths),
                            plan: ColumnVisibilityPlan(indices: plan.indices, requiredIDs: plan.requiredIDs),
                            overrides: overrides, isEnabled: isEnabled)
                            .flex(0, shrink: 0)
                    }
                    content(plan).flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
            }
        }.flex(1, shrink: 1).frame(minWidth: 0, minHeight: 0) }
        .flex(1, shrink: 1).frame(minWidth: 0, minHeight: 0)
    }
}
