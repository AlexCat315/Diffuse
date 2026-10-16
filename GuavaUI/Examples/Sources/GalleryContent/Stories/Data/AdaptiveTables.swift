import GuavaUI

struct AdaptiveTableSample: View {
    let data: Bool
    let options: GalleryOptions
    @State private var model = DataTableModel(Array(0..<30), id: \.self)
    private var columns: [TableColumn<Int>] {
        [TableColumn("name", "Asset", configure: { $0.layout.width = 160 }) { Text("Asset \($0)").font(.label) },
         TableColumn("quantity", "Quantity", configure: { $0.layout.width = 100; $0.visibility = .automatic(priority: 10) }) { Text(String($0 * 7)).font(.label) },
         TableColumn("category", "Category", configure: { $0.layout.width = 130; $0.visibility = .automatic() }) { Text($0 % 2 == 0 ? "Texture" : "Material").font(.label) }]
    }
    var body: some View {
        if data {
            DataTable(model, columns: columns) { $0.options.isEnabled = options.isEnabled }
        } else {
            Table(Array(0..<30), id: \.self, columns: columns) { $0.options.isEnabled = options.isEnabled }
        }
    }
}
