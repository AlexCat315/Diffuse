import GuavaUICompose
import GuavaUIRuntime

struct EditorMenuItem: View {
    let title: String
    let menuWidth: Float
    let entries: [MenuEntry]
    @State private var isPresented: Bool = false

    var body: some View {
        Popover(isPresented: $isPresented,
                width: menuWidth) {
            Row(alignment: .center, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(isPresented ? .onSurface : .onSurfaceVariant)
                Text("▾")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(isPresented ? .surfaceSunken : .surface)
            .cornerRadius(4)
        } content: {
            Menu(entries,
                 width: menuWidth,
                 maxVisibleRows: 10,
                 onItemActivated: {
                isPresented = false
            })
        }
    }
}
