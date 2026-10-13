import GuavaUI

/// Desktop and mobile hosts install this shared root once per application session.
public func makeApplicationContent() -> some View { RootView() }

private struct RootView: View {
    @State private var count = 0
    @State private var name: TextBuffer = "GuavaUI"

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 20) {
            Text(AppResources.welcome).font(.headline)
            Text("Count: \(count)").font(.body)
            Row(alignment: .center, spacing: 12) {
                Button("Add one") { count += 1 }
                Button("Reset") { count = 0 }.buttonStyle(.secondary)
            }
            TextField("Your name", text: $name) { $0.behavior.clearable = true }
            Text("Hello, \(name.stringValue)").foregroundColor(.onSurfaceMuted)
        }
        .padding(24)
        .background(.surface)
    }
}
