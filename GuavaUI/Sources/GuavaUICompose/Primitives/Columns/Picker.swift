internal import GuavaUIRuntime

struct ColumnVisibilityPicker: View {
    private enum EntryID: Hashable { case automatic, separator, column(String) }
    let columns: [ColumnVisibilityTrack]
    let plan: ColumnVisibilityPlan
    let overrides: Binding<[String: Bool]>
    let isEnabled: Bool
    @State private var isPresented = false
    var body: some View {
        if !isEnabled && isPresented { isPresented = false }
        let visible = Set(plan.indices.map { columns[$0].id })
        return Row(alignment: .center, spacing: 8) {
            Box(direction: .column, alignItems: .flexStart, spacing: 0) {
                Button("Columns", isEnabled: isEnabled) { isPresented.toggle() }
                    .buttonStyle(.secondary).frame(minWidth: 44, minHeight: 44)
                    .compositionLocal(ActionControlAccessibility.label, "Column visibility")
                    .compositionLocal(ActionControlAccessibility.isExpanded, isPresented)
                AnchoredOverlayHost(isPresented: isPresented, width: nil, placement: .bottomLeading,
                    onDismiss: { isPresented = false }) {
                    Menu(entries(visible: visible), onItemActivated: { isPresented = false }, onDismiss: { isPresented = false })
                        .compositionLocal(MenuRowMetrics.minimumHeight, 44)
                }
            }.flex(0, shrink: 0)
            Text("\(visible.count) of \(columns.count) columns").font(.caption).foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1).frame(minWidth: 0).accessibility { $0.role = .status }
        }.frame(minWidth: 0).padding(horizontal: 4)
    }
    private func entries(visible: Set<String>) -> [MenuEntry] {
        [.item(MenuItem(id: EntryID.automatic, title: "Automatic columns", isEnabled: !overrides.wrappedValue.isEmpty) {
            overrides.wrappedValue = [:]
        }), .separator(id: EntryID.separator)] + columns.map { column in
            let required = plan.requiredIDs.contains(column.id) || (visible.count == 1 && visible.contains(column.id))
            return .item(MenuItem(id: EntryID.column(column.id), title: column.title, isEnabled: !required, isSelected: visible.contains(column.id)) {
                overrides.wrappedValue[column.id] = !visible.contains(column.id)
            })
        }
    }
}
