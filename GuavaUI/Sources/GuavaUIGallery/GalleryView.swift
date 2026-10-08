import GuavaUICompose
import GuavaUIRuntime

/// Navigation state belongs to the shell; each story owns and resets its own example state.
public struct GalleryView: View {
    @State private var page: GalleryPage
    @State private var search: TextBuffer = ""
    @State private var appearance: Appearance
    @State private var options = GalleryOptions()
    @State private var resetGeneration = 0

    public init(initialPage: GalleryPage = .button, appearance: Appearance = .light) {
        _page = State(wrappedValue: initialPage)
        _appearance = State(wrappedValue: appearance)
    }

    public var body: some View {
        LayerRoot {
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                sidebar.frame(width: 226).flex(0, shrink: 0)
                Divider(axis: .vertical)
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    header
                    Divider()
                    toolbar
                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        page.makeStory(options: options)
                            .id("\(page.rawValue)-\(resetGeneration)")
                            .controlSize(options.size)
                            .padding(24)
                            .flex(0, shrink: 0)
                            .frame(minWidth: 0)
                    }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0).debugName("gallery-content")
                    Divider()
                    Text("\(GalleryCatalog.entries.count) stories   ·   GuavaUI component showcase")
                        .font(.caption).foregroundColor(.onSurfaceMuted).padding(horizontal: 24, vertical: 8)
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0).background(.background)
                .debugName("gallery-shell")
        }.appearance(appearance)
    }

    private var sidebar: some View {
        let matches = GalleryCatalog.search(search.stringValue)
        let sections = GalleryCatalog.categories.compactMap { category -> SidebarSection<GalleryPage>? in
            let entries = matches.filter { $0.category == category }
            guard !entries.isEmpty else { return nil }
            return SidebarSection(category, title: category, items: entries.map { SidebarItem($0.page, $0.title) })
        }
        return Sidebar(selection: Binding(get: { page }, set: { if let selected = $0 { page = selected } }), sections: sections, header: {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 10) {
                    Text("G").font(.headline).foregroundColor(.onAccent).padding(9).background(.accent).cornerRadius(9)
                    Column(alignment: .leading, spacing: 2) {
                        Text("GuavaUI").font(.bodyStrong).foregroundColor(.onSurface)
                        Text("Component showcase").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }.padding(16)
                TextField("Search components…", text: $search) { $0.behavior.clearable = true }
                    .debugName("gallery-search").padding(horizontal: 12, vertical: 4)
                if matches.isEmpty { Text("No matching components").font(.caption).foregroundColor(.onSurfaceMuted).padding(16) }
            }
        }, footer: {
            Box(direction: .column, alignItems: .stretch) {
                Divider()
                Button(appearance == .light ? "Switch to dark theme" : "Switch to light theme") {
                    appearance = appearance == .light ? .dark : .light
                }.buttonStyle(.ghost).padding(12).debugName("gallery-theme")
            }
        })
    }

    private var header: some View {
        Column(alignment: .leading, spacing: 6) {
            Text(page.entry.title).font(.title).foregroundColor(.onSurface)
            Text(page.entry.summary).font(.body).foregroundColor(.onSurfaceMuted)
        }.padding(horizontal: 24, vertical: 20).flex(0, shrink: 0)
    }

    private var toolbar: some View {
        Row(alignment: .center, spacing: 12) {
            Text("Size").font(.caption).foregroundColor(.onSurfaceMuted)
            Select(selection: Binding(get: { options.size }, set: { options.size = $0 }), options: [
                SelectOption(value: .mini, label: "Mini"), SelectOption(value: .small, label: "Small"),
                SelectOption(value: .regular, label: "Medium"), SelectOption(value: .large, label: "Large")
            ]).frame(width: 118).debugName("gallery-size")
            Checkbox(isOn: Binding(get: { !options.isEnabled }, set: { options.isEnabled = !$0 }))
            Text("Disabled").font(.caption).foregroundColor(.onSurfaceVariant)
            Spacer()
            Button("Reset example") { resetGeneration += 1 }.buttonStyle(.ghost).debugName("gallery-reset")
        }.controlSize(.small).padding(horizontal: 24, vertical: 10).flex(0, shrink: 0)
    }
}

struct StorySection<Content: View>: View {
    let title: String
    let detail: String
    let content: Content
    init(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.content = content()
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Text(title).font(.bodyStrong).foregroundColor(.onSurface)
            Text(detail).font(.caption).foregroundColor(.onSurfaceMuted)
            Box(direction: .column, alignItems: .stretch, spacing: 12) { content }
                .padding(18).background(.surface).cornerRadius(8).border(.border, width: 1)
        }.flex(0, shrink: 0).frame(minWidth: 0).debugName("story-section-\(title)")
    }
}
