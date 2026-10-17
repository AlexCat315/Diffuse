import Foundation
import GuavaUI
import GuavaUIRuntime

struct GalleryTreeNode: Identifiable {
    let id: String
    let title: String
    var children: [GalleryTreeNode] = []
}
let galleryTree: [GalleryTreeNode] = [
    .init(id: "scene", title: "Scene", children: [
        .init(id: "camera", title: "Camera"), .init(id: "lights", title: "Lights", children: [
            .init(id: "sun", title: "Sun"), .init(id: "fill", title: "Fill light")]),
        .init(id: "objects", title: "Objects", children: [.init(id: "cube", title: "Cube"), .init(id: "sphere", title: "Sphere")])])
]

struct ListStory: View {
    @State private var selected: Int? = 2
    @State private var activated = "No activation yet"
    var body: some View {
        StorySection("Selectable list", "Click a row or focus the list and use arrows, Home and End. Return activates the selected row.") {
            List(Array(0..<30), id: \.self, selection: $selected, onActivate: { activated = "Activated row \($0)" }) { row, isSelected in
                Row(alignment: .center, spacing: 10) {
                    Text("Document \(row + 1)").font(.body)
                    Spacer()
                    if isSelected { Badge("Selected", tone: .info) }
                }
            }.frame(height: 260)
            Text("Selection: \(selected.map(String.init) ?? "None")  ·  \(activated)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct TreeStory: View {
    var options = GalleryOptions()
    @State private var selection: String? = "camera"
    @State private var expanded: Set<String> = ["scene", "lights"]
    @State private var selectedIDs: Set<String> = ["camera"]
    @State private var search: TextBuffer = ""
    var body: some View {
        StorySection("Scene hierarchy", "Search retains matching ancestors. Use arrows, Home and End; Option/Alt + Right expands all and Option/Alt + Left collapses all. Command/Control-click selects multiple nodes.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                TextField("Search nodes…", text: $search) {
                    $0.behavior.clearable = true
                    $0.behavior.disabled = !options.isEnabled
                }.frame(maxWidth: 300).flex(1, shrink: 1, basis: 240)
                Button("Expand all", isEnabled: options.isEnabled) { expanded = ["scene", "lights", "objects"] }
                    .buttonStyle(.secondary).debugName("tree-expand-all")
                Button("Collapse all", isEnabled: options.isEnabled) { expanded = [] }
                    .buttonStyle(.secondary).debugName("tree-collapse-all")
            }
            Tree(galleryTree, id: \.id, children: { $0.children }, hasChildren: { !$0.children.isEmpty }, configure: { tree in
                    tree.isEnabled = options.isEnabled
                    tree.selection.primary = $selection
                    tree.selection.multiple = $selectedIDs
                    tree.selection.expanded = $expanded
                    tree.search.query = search.stringValue
                    tree.search.text = { $0.title }
                }) { node, _, _, _ in
                    Text(node.title).font(.body)
                }.frame(height: 250).flex(0, shrink: 0).clipped().debugName("gallery-tree")
            Text("Selected: \(selectedIDs.sorted().joined(separator: ", "))").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct VirtualListStory: View {
    var body: some View {
        StorySection("10,000 rows", "Only a small window is materialized; the scroll extent represents the complete collection.") {
            VirtualList(Array(0..<10_000), id: \.self, rowHeight: 30) { row in
                Text("Row \(row + 1)").font(.body).padding(horizontal: 8)
            }.frame(height: 330)
        }
    }
}

struct VirtualStackStory: View {
    @State private var target = 0
    var body: some View {
        StorySection("Scroll to index", "The viewport materializes rows around the requested index.") {
            Row(alignment: .center, spacing: 10) {
                Button("First") { target = 0 }.buttonStyle(.secondary)
                Button("Middle") { target = 5_000 }.buttonStyle(.secondary)
                Button("Last") { target = 9_999 }.buttonStyle(.secondary)
            }
            VirtualStack(Array(0..<10_000), id: \.self, rowHeight: 30, scrollToIndex: target) { row in
                Text("Record \(row + 1)").font(.body).padding(horizontal: 8)
            }.frame(height: 300)
        }
    }
}

struct ChartStory: View {
    private let values: [Float] = [12, 19, 16, 28, 21, 35, 24, 31, 40, 34, 47, 42]
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Line & threshold", "A deterministic fixture makes changes easy to compare.") {
                MonitorChart(values: values, threshold: ChartThreshold(value: 30, color: .warning), marker: ChartMarker(index: 8, color: .success)).frame(height: 130)
            }
            StorySection("Bars & sparkline", "Compact charts share the same rendering primitive.") {
                BarChart(values).frame(height: 110)
                SparklineChart(values).frame(height: 60)
            }
        }
    }
}

/// Browses the whole bundled icon set: every glyph, its name, and the size it
/// has to survive. A catalog page is the only way to notice that one glyph went
/// muddy at 12px before it ships inside a control.
struct IconStory: View {
    let options: GalleryOptions
    @State private var actions = 0
    @State private var query: TextBuffer = ""
    @State private var size: Double = 20

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Accessible icon sizing", "Icons and icon buttons follow the Scale control above. A local policy can keep artwork fixed without changing text.") {
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 20) {
                    Icon(UIIcons.File.folder, size: .small).debugName("icon-small")
                    Icon(UIIcons.File.folder, size: .medium).debugName("icon-medium")
                    Icon(UIIcons.File.folder, size: .large).debugName("icon-large")
                    Icon(UIIcons.File.folder, size: 31).debugName("icon-explicit")
                    Text("small · medium · large · 31 pt").font(.caption).foregroundColor(.onSurfaceMuted)
                }
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) {
                    Button(icon: .resource(UIIcons.Action.settings), isEnabled: options.isEnabled, tooltip: "Project settings") { actions += 1 }.buttonStyle(.secondary)
                        .debugName("icon-button-adaptive")
                    Button(icon: .resource(UIIcons.Action.settings), isEnabled: options.isEnabled, tooltip: "Fixed icon") { actions += 1 }.buttonStyle(.secondary)
                        .iconScaling(.fixed).debugName("icon-button-fixed")
                    Button(icon: .resource(UIIcons.Action.settings), isLoading: true, tooltip: "Loading settings") {}
                        .buttonStyle(.secondary).debugName("icon-button-loading")
                    Text("Adaptive · fixed · loading · \(actions) actions").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("Semantic SVG icons", "Alpha-mask assets inherit foreground color and follow light/dark themes.") {
                Row(alignment: .center, spacing: 20) {
                    Icon(UIIcons.Action.check, size: 20, color: .success)
                    Icon(UIIcons.Status.xCircle, size: 20, color: .error)
                    Icon(UIIcons.Navigation.chevronDown, size: 20, color: .onSurface)
                    Icon(UIIcons.Navigation.arrowRight, size: 20, color: .accent)
                    Icon(UIIcons.Navigation.expand, size: 20, color: .onSurfaceMuted)
                }
                Row(alignment: .center, spacing: 20) {
                    for preview: Float in [12, 16, 24, 32] { Icon(UIIcons.Action.check, size: preview, color: .accent) }
                }
            }
            StorySection("Catalog", "\(UIIcons.all.count) glyphs. Search by name or category, then change the size to check legibility at the one you actually use.") {
                Row(alignment: .center, spacing: 12) {
                    TextField("Search icons\u{2026}", text: $query) { $0.behavior.clearable = true }
                        .frame(width: 240)
                    Text("Size").font(.caption).foregroundColor(.onSurfaceMuted)
                    Slider(value: $size, range: 10...32, step: 1)
                        .frame(width: 160)
                    Text("\(Int(size))px").font(.caption).foregroundColor(.onSurfaceMuted)
                }
                IconCatalog(query: query.stringValue, size: Float(size))
            }
        }
    }
}

private struct IconCatalog: View {
    let query: String
    let size: Float

    var body: some View {
        let matches = UIIcons.search(query)
        Column(alignment: .leading, spacing: 16) {
            for category in UIIcons.categories {
                AnyView(IconCategory(title: category,
                                     entries: matches.filter { $0.category == category },
                                     size: size))
            }
            if matches.isEmpty {
                AnyView(EmptyState("No matching glyphs", message: "Try a shorter search term.") { $0.prominence = .compact })
            }
        }
    }
}

private struct IconCategory: View {
    let title: String
    let entries: [UIIconEntry]
    let size: Float

    var body: some View {
        guard !entries.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Column(alignment: .leading, spacing: 8) {
            Text(title).font(.bodyStrong).foregroundColor(.onSurface)
            Box(direction: .row, alignItems: .center, justifyContent: .flexStart, wrap: .wrap, spacing: 6) {
                for entry in entries {
                    AnyView(IconCell(entry: entry, size: size))
                }
            }
        })
    }
}

private struct IconCell: View {
    let entry: UIIconEntry
    let size: Float

    var body: some View {
        Column(alignment: .center, spacing: 3) {
            Icon(entry.resource, size: size, color: .onSurface)
                .padding(6)
                .background(SemanticColorRef.surfaceVariant)
                .cornerRadius(6)
            Text(entry.name).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

/// Ordered events on a shared rail, used for build logs, history and activity.
struct TimelineStory: View {
    var body: some View {
        StorySection("Event sequence", "The connector carries the ordering; the glyph carries the outcome.") {
            Timeline(events: [
                TimelineEvent("Build started", detail: "Target: macOS · arm64", trailing: "09:12", tone: .info),
                TimelineEvent("Shaders compiled", detail: "14 pipelines, 0 warnings", trailing: "09:12", tone: .success),
                TimelineEvent("Asset pack rebuilt", trailing: "09:13", tone: .neutral, isCompact: true),
                TimelineEvent("Link failed", detail: "Undefined symbol: vkCreateBuffer", trailing: "09:14", tone: .danger),
                TimelineEvent("Retry queued", trailing: "09:14", tone: .warning)
            ])
            Timeline(events: [
                TimelineEvent("Deploy to staging", trailing: "Done", tone: .success, icon: UIIcons.File.package),
                TimelineEvent("Smoke tests", trailing: "Running", tone: .info, icon: UIIcons.Status.loader)
            ])
        }
    }
}

struct AssetStory: View {
    let options: GalleryOptions
    @State private var value: AssetRef? = nil
    private var assets: [AssetRef] {
        [.init(id: "landscape", name: "Landscape", subtitle: "Bundled SVG", kind: "texture", previewPath: ImageStory.resource.url?.path),
         .init(id: "material", name: "Matte material", kind: "material")]
    }
    var body: some View {
        StorySection("Asset reference", "Choose or clear a texture. The field accepts only the configured asset kind.") {
            AssetRefField(value: $value, acceptedKinds: ["texture"], pickerOptions: assets, placeholder: "Choose a texture", isEnabled: options.isEnabled).frame(width: 420)
            Text("Asset: \(value?.name ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct MultiSelectListStory: View {
    @State private var selection: Set<Int> = [2]
    @State private var activated = "No activation yet"

    var body: some View {
        StorySection("Multi-select list", "Click selects one row; Shift-click selects a range; Cmd/Ctrl-click toggles. Focus the list and use Shift+Arrow to extend, Cmd/Ctrl+A to select all.") {
            MultiSelectList(Array(0..<12), id: \.self, selection: $selection,
                            onActivate: { activated = "Activated row \($0 + 1)" }) { row, isSelected in
                Row(alignment: .center, spacing: 10) {
                    Text("Document \(row + 1)").font(.body)
                    Spacer()
                    if isSelected { Badge("Selected", tone: .info) }
                }
            }.frame(height: 280)
            Text("Selected: \(selection.sorted().map { String($0 + 1) }.joined(separator: ", "))  ·  \(activated)")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct SectionedListStory: View {
    private struct Item: Identifiable {
        let id: Int
        let title: String
    }

    private func items(_ titles: [String], from base: Int) -> [Item] {
        titles.enumerated().map { Item(id: base + $0.offset, title: $0.element) }
    }

    private var sections: [ListSection<String, Item>] {
        [
            ListSection("favorites", title: "Favorites", items: items([
                "Main Camera", "Key Light", "Fill Light", "Backdrop", "Audio Source"
            ], from: 1)),
            ListSection("scene", title: "Scene", footer: "12 objects", items: items([
                "Player", "Ground", "Trigger", "Door", "Crate", "Lantern",
                "Bridge", "Water", "Foliage", "Sky", "Music Zone", "Checkpoint"
            ], from: 100)),
            ListSection("hidden", title: "Hidden", items: items([
                "Debug Gizmo", "Nav Mesh", "Light Probe", "Collision Preview",
                "Occluder", "Reflection Probe", "Decal", "Audio Reverb",
                "Trigger Volume", "Waypoint", "Fog Volume", "Camera Bookmark"
            ], from: 200))
        ]
    }

    @State private var selected: Int? = 1
    @State private var activated = "No activation yet"

    var body: some View {
        StorySection("Sectioned list", "Scroll the list: the active section header stays pinned and is pushed out by the next one. Headers and footers stay outside the focus order; arrows move only through item rows, including across section boundaries.") {
            SectionedList(sections, selection: $selected, stickyHeaders: true,
                          onActivate: { activated = "Activated \($0.title)" }) { item, isSelected in
                Row(alignment: .center, spacing: 10) {
                    Text(item.title).font(.body)
                    Spacer()
                    if isSelected { Badge("Selected", tone: .info) }
                }
            }.frame(height: 340)
            Text("Selected: \(selected.map(String.init) ?? "None")  ·  \(activated)")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct ReorderableListStory: View {
    private struct Item: Identifiable {
        let id: Int
        let title: String
    }

    @State private var items = [
        Item(id: 0, title: "Main Camera"),
        Item(id: 1, title: "Key Light"),
        Item(id: 2, title: "Player"),
        Item(id: 3, title: "Ground"),
        Item(id: 4, title: "Trigger"),
        Item(id: 5, title: "Audio Source")
    ]

    var body: some View {
        StorySection("Reorderable list", "Drag the 44pt grip to move a row: a 2pt accent line marks the insertion point, Escape cancels, and Up/Down (or the assistive increment/decrement actions) move the focused row without a pointer.") {
            ReorderableList(items, id: \.id, rowHeight: 36,
                            rowLabel: { $0.title },
                            onMove: { from, to in
                guard items.indices.contains(from), (0..<items.count).contains(to) else { return }
                let moved = items.remove(at: from)
                items.insert(moved, at: to)
            }) { item, isDragging in
                Row(alignment: .center, spacing: 10) {
                    Text(item.title).font(.body)
                    Spacer()
                    if isDragging { Badge("Moving", tone: .info) }
                }
            }.frame(height: 300)
            Text("Order: \(items.map(\.title).joined(separator: " → "))")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct SwipeListStory: View {
    private let items = ["Inbox", "Design review", "Release notes", "Billing", "Research"]
    @State private var selection: Int? = 1
    @State private var log = "No actions yet"

    var body: some View {
        StorySection("Swipe actions", "Touch rows reveal up to two trailing actions. Every row also has an actions button and a right-click menu, so pointer, keyboard and assistive clients can run the same commands without swiping.") {
            SwipeList(items.indices, id: \.self, selection: $selection,
                      rowHeight: 52, rowSpacing: 2,
                      rowLabel: { items[$0] },
                      actions: { index in
                [
                    SwipeAction(id: "archive-\(index)", title: "Archive") {
                        log = "Archived \(items[index])"
                    },
                    SwipeAction(id: "delete-\(index)", title: "Delete", tone: .danger) {
                        log = "Deleted \(items[index])"
                    }
                ]
            }, onActivate: { index in
                log = "Opened \(items[index])"
            }) { index, selected in
                Row(alignment: .center, spacing: 10) {
                    Icon(UIIcons.Shape.circle, size: 16,
                         color: selected ? .accent : .onSurfaceMuted)
                    Column(alignment: .leading, spacing: 2) {
                        Text(items[index]).font(.body).foregroundColor(.onSurface)
                        Text("Swipe left or use the row actions button")
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
                .frame(height: 52)
            }
            .frame(height: 260)
            Text(log).font(.caption).foregroundColor(.onSurfaceMuted).debugName("swipe-log")
        }
    }
}

struct RefreshListStory: View {
    private let items = ["Inbox", "Design review", "Release notes", "Billing", "Research", "Archive"]
    @State private var isRefreshing = false
    @State private var refreshes = 0

    var body: some View {
        StorySection("Pull to refresh", "Touch pull past 64pt starts the caller-owned refresh; the indicator holds until the binding clears and freezes under reduced motion. Cmd+R or Ctrl+R is the keyboard path, and the explicit button is the pointer path.") {
            Row(alignment: .center, spacing: 8) {
                Button("Refresh now") { startRefresh() }.debugName("refresh-now")
                Text("Refreshes: \(refreshes)").font(.caption)
                    .foregroundColor(.onSurfaceMuted).debugName("refresh-count")
            }
            List(items.indices, id: \.self, selection: .constant(1), rowHeight: 44,
                 refresh: RefreshOptions(isRefreshing: $isRefreshing, threshold: 64) {
                startRefresh()
            }) { index, _ in
                Text(items[index])
            }
            .frame(height: 240)
        }
    }

    private func startRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshes += 1
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isRefreshing = false
        }
    }
}
