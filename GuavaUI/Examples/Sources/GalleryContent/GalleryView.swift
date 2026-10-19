import GuavaUI
import GuavaUIRuntime

/// Navigation state belongs to the shell; each story owns and resets its own example state.
public struct GalleryView: View {
  @State private var page: GalleryPage
  @State private var search: TextBuffer = ""
  @State private var appearance: Appearance
  @State private var options = GalleryOptions()
  @State private var resetGeneration = 0
  @State private var textScale: Double?
  @State private var navigationOpen = false
  @State private var navigationWidth: Float = 240

  public init(initialPage: GalleryPage = .introduction, appearance: Appearance = .light,
              textScale: Double = 1) {
    _page = State(wrappedValue: initialPage)
    _appearance = State(wrappedValue: appearance)
    _textScale = State(wrappedValue: min(2, max(1, textScale.isFinite ? textScale : 1)))
  }

  public var currentPage: GalleryPage { page }
  public var isDark: Bool { appearance == .dark }
  public func selectPage(_ page: GalleryPage) { self.page = page }

  public var body: some View {
    LayerRoot {
      AdaptiveSidebar(
        "GuavaUI navigation", isPresented: $navigationOpen,
        selection: Binding(get: { page }, set: { if let selected = $0 { page = selected } }),
        width: $navigationWidth,
        sections: navigationSections,
        configure: {
          $0.allowsEdgeSwipe = true
          $0.layout.showsRailLabels = false
        },
        header: {
          navigationHeader
        },
        footer: {
          navigationFooter
        }
      ) {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
          header
          Divider()
          toolbar
          ScrollView(.vertical, scrollbarGutter: .stable) {
            page.makeStory(options: options)
              .id("\(page.rawValue)-\(resetGeneration)")
              .controlSize(options.size)
              .textScaler(TextScaler(Float(textScale ?? 1)))
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
    }.appearance(appearance, transition: .circular())
  }

  private var navigationSections: [SidebarSection<GalleryPage>] {
    let matches = GalleryCatalog.search(search.stringValue)
    return GalleryCatalog.categories.compactMap { category -> SidebarSection<GalleryPage>? in
      let entries = matches.filter { $0.category == category }
      guard !entries.isEmpty else { return nil }
      return SidebarSection(
        category, title: category,
        items: entries.map { entry in
          SidebarItem(entry.page, entry.title) { $0.icon = entry.page.navigationIcon }
        })
    }
  }

  private var navigationHeader: some View {
    ViewThatFits(
      threshold: 120,
      wide: {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
          Row(alignment: .center, spacing: 10) {
            Text("G").font(.headline).foregroundColor(.onAccent).padding(9).background(.accent)
              .cornerRadius(9)
            Column(alignment: .leading, spacing: 2) {
              Text("GuavaUI").font(.bodyStrong).foregroundColor(.onSurface)
              Text("Component showcase").font(.caption).foregroundColor(.onSurfaceMuted)
            }
          }.padding(16)
          TextField("Search components…", text: $search) { $0.behavior.clearable = true }
            .debugName("gallery-search").padding(horizontal: 12, vertical: 4)
          if navigationSections.isEmpty {
            Text("No matching components").font(.caption).foregroundColor(.onSurfaceMuted).padding(
              16)
          }
        }
      },
      compact: {
        Text("G", alignment: .center).font(.headline).foregroundColor(.accent)
          .padding(vertical: 10).frame(width: .percent(100))
      })
  }

  private var navigationFooter: some View {
    ViewThatFits(
      threshold: 120,
      wide: {
        Box(direction: .column, alignItems: .stretch) {
          Divider()
          Button(appearance == .light ? "Switch to dark theme" : "Switch to light theme") {
            toggleTheme()
          }.buttonStyle(.ghost).padding(12).debugName("gallery-theme")
        }
      },
      compact: {
        Button(
          icon: .resource(appearance == .light ? UIIcons.Device.moon : UIIcons.Device.sun),
          tooltip: appearance == .light ? "Switch to dark theme" : "Switch to light theme"
        ) { toggleTheme() }
        .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44).debugName("gallery-theme-rail")
      })
  }

  private func toggleTheme() { appearance = appearance == .light ? .dark : .light }

  private var header: some View {
    Column(alignment: .leading, spacing: 6) {
      Text(page.entry.title).font(.title).foregroundColor(.onSurface)
      Text(page.entry.summary).font(.body).foregroundColor(.onSurfaceMuted).frame(
        width: .percent(100))
    }.padding(horizontal: 24, vertical: 20).flex(0, shrink: 0)
  }

  private var toolbar: some View {
    Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) {
      Row(alignment: .center, spacing: 8) {
        Text("Size").font(.caption).foregroundColor(.onSurfaceMuted)
        Select(
          selection: Binding(get: { options.size }, set: { options.size = $0 }),
          options: [
            SelectOption(value: .mini, label: "Mini"), SelectOption(value: .small, label: "Small"),
            SelectOption(value: .regular, label: "Medium"),
            SelectOption(value: .large, label: "Large"),
          ]
        ).frame(width: 118).debugName("gallery-size")
      }
      Row(alignment: .center, spacing: 8) {
        Text("Scale").font(.caption).foregroundColor(.onSurfaceMuted)
        Select(
          selection: $textScale,
          options: [
            SelectOption(value: 1.0, label: "100%"), SelectOption(value: 1.25, label: "125%"),
            SelectOption(value: 1.5, label: "150%"), SelectOption(value: 2.0, label: "200%"),
          ]
        ).frame(width: 86).debugName("gallery-text-scale")
      }
      Row(alignment: .center, spacing: 8) {
        Checkbox(isOn: Binding(get: { !options.isEnabled }, set: { options.isEnabled = !$0 }))
        Text("Disabled").font(.caption).foregroundColor(.onSurfaceVariant)
      }
      Button("Reset example") { resetGeneration += 1 }.buttonStyle(.secondary).debugName(
        "gallery-reset")
    }.controlSize(.small).padding(horizontal: 24, vertical: 10).flex(0, shrink: 0)
  }
}

struct StorySection<Content: View>: View {
  let title: String
  let detail: String
  let content: Content
  init(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content()
  }
  var body: some View {
    Box(direction: .column, alignItems: .stretch, spacing: 8) {
      Text(title).font(.headline).foregroundColor(.onSurface)
      Text(detail).font(.body).foregroundColor(.onSurfaceMuted)
      Box(direction: .column, alignItems: .stretch, spacing: 12) { content }
        .padding(22).background(.surfaceRaised).cornerRadius(12).border(.border, width: 1)
    }.flex(0, shrink: 0).frame(minWidth: 0).debugName("story-section-\(title)")
  }
}
