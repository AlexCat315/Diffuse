import Foundation
import GuavaUICompose
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
    @State private var selection: String? = "camera"
    @State private var expanded: Set<String> = ["scene", "lights"]
    @State private var selectedIDs: Set<String> = ["camera"]
    @State private var search: TextBuffer = ""
    var body: some View {
        StorySection("Scene hierarchy", "Search keeps matching ancestors. Use arrows to expand and navigate; Command-click selects multiple nodes.") {
            TextField("Search nodes…", text: $search) { $0.behavior.clearable = true }.frame(width: 300)
            Tree(galleryTree, id: \.id, children: { $0.children }, configure: { tree in
                tree.selection.primary = $selection
                tree.selection.multiple = $selectedIDs
                tree.selection.expanded = $expanded
                tree.search.query = search.stringValue
                tree.search.text = { $0.title }
            }) { node, _, _, _ in
                Text(node.title).font(.body)
            }.frame(height: 250).flex(0, shrink: 0).debugName("gallery-tree")
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

struct IconStory: View {
    var body: some View {
        StorySection("Semantic SVG icons", "Alpha-mask assets inherit foreground color and follow light/dark themes.") {
            Row(alignment: .center, spacing: 20) {
                Icon(UICommonIcons.checkmark, size: 20, color: .success)
                Icon(UICommonIcons.close, size: 20, color: .error)
                Icon(UICommonIcons.chevronDown, size: 20, color: .onSurface)
                Icon(UICommonIcons.chevronRight, size: 20, color: .accent)
                Icon(UICommonIcons.expand, size: 20, color: .onSurfaceMuted)
            }
            Row(alignment: .center, spacing: 20) {
                for size: Float in [12, 16, 24, 32] { Icon(UICommonIcons.checkmark, size: size, color: .accent) }
            }
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
