import GuavaUI

struct GridColumnExamples: View {
    let options: GalleryOptions
    var body: some View {
        StorySection("Named field columns", "Name stays visible. Quantity has priority over Notes. Use Columns to reveal hidden fields or restore automatic sizing; drafts and local cell state survive. Required minimum widths remain horizontally scrollable.") {
            GridColumnSample(options: options).debugName("gallery-column-grid")
        }
    }
}

struct GridColumnSample: View {
    let options: GalleryOptions
    private func spanCell(_ title: String) -> some View {
        Text(title).font(.caption).padding(10).frame(width: .percent(100)).background(.surfaceVariant).cornerRadius(6)
    }
    @State private var choices: [String: Bool] = [:]
    @State private var status = "No asset opened"
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Grid(columns: [
                .named(id: "asset", title: "Asset", sizing: .fixed(180)),
                .named(id: "quantity", title: "Quantity", sizing: .fixed(120), visibility: .automatic(priority: 10)),
                .named(id: "notes", title: "Notes", sizing: .flexible(minimum: 200), visibility: .automatic())
            ], columnSpacing: 12, rowSpacing: 12, columnVisibility: $choices, isEnabled: options.isEnabled) {
                Button("Open Asset 1", isEnabled: options.isEnabled) { status = "Opened Asset 1" }
                    .buttonStyle(.secondary).accessibilityLabel("Open Asset 1")
                Text("7 items").font(.body)
                GridNoteCell(isEnabled: options.isEnabled)
                Button("Open Asset 2", isEnabled: options.isEnabled) { status = "Opened Asset 2" }
                    .buttonStyle(.secondary).accessibilityLabel("Open Asset 2")
                Text("12 items").font(.body)
                Text("Published").font(.body).foregroundColor(.onSurfaceMuted)
            }
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted).debugName("grid-action-result")
            Grid(columns: [.flexible(), .flexible(), .flexible()], columnSpacing: 8, rowSpacing: 8) {
                spanCell("Header · 3 columns").gridCellSpan(columns: 3)
                spanCell("Sidebar · 2 rows").gridCellSpan(rows: 2)
                spanCell("Wide · 2 columns").gridCellSpan(columns: 2)
                spanCell("A")
                spanCell("B")
            }.debugName("grid-span-sample")
        }
    }
}

private struct GridNoteCell: View {
    let isEnabled: Bool
    @State private var text: TextBuffer = "Editable note"
    var body: some View {
        TextField("Grid notes", text: $text) { $0.behavior.disabled = !isEnabled }.accessibilityLabel("Grid notes")
    }
}
