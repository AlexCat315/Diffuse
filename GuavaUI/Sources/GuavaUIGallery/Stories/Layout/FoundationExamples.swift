import Foundation
import GuavaUICompose

struct LayoutFoundationExamples: View {
    @State private var narrow = false
    @State private var rtl = false
    @State private var target: Int? = nil

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Measured grid", "Fixed, flexible and adaptive tracks share the public Layout measurement and placement contract. Row heights follow their tallest content.") {
                Grid(columns: [.fixed(100), .flexible(minimum: 120), .flexible(minimum: 120)],
                     columnSpacing: 12, rowSpacing: 12) {
                    cell("Fixed", detail: "100 points")
                    cell("Flexible", detail: "Natural row height")
                    cell("Flexible", detail: "Text wraps as the window narrows, including at 200%.")
                    cell("Row 2", detail: "No fixed row slot")
                    cell("Content", detail: "Measured by the same engine that draws the text.")
                    cell("More", detail: "One view per cell")
                }.debugName("layout-measured-grid")
                Grid(columns: [.adaptive(minimum: 150)], columnSpacing: 12, rowSpacing: 12) {
                    for index in 1...6 { AnyView(cell("Adaptive \(index)", detail: "Resize the window")) }
                }.debugName("layout-adaptive-grid")
            }
            StorySection("Candidate layouts", "The same three controls move between a horizontal and vertical layout. Their identity and state survive the layout change.") {
                Button(narrow ? "Use wide proposal" : "Use narrow proposal") { narrow.toggle() }.buttonStyle(.secondary)
                LayoutThatFits([StackLayout(.horizontal, spacing: 12), StackLayout(.vertical, spacing: 12)]) {
                    Button("Files") {}.buttonStyle(.secondary)
                    Button("Preview") {}.buttonStyle(.secondary)
                    Button("Settings") {}.buttonStyle(.secondary)
                }.frame(width: narrow ? 180 : 620).debugName("layout-candidates")
            }
            StorySection("Logical edges and safe area", "Leading/trailing padding mirrors with direction. Nested SafeArea containers consume each supplied host inset once.") {
                Button(rtl ? "Switch to LTR" : "Switch to RTL") { rtl.toggle() }.buttonStyle(.secondary)
                SafeArea(.horizontal) {
                    SafeArea {
                        Row(spacing: 12) {
                            Badge("Leading", tone: .info)
                            Spacer()
                            Badge("Trailing", tone: .success)
                        }.padding(12).background(.surfaceVariant).cornerRadius(6)
                    }
                }.safeAreaInsets(EdgeInsets(top: 8, leading: 32, bottom: 8, trailing: 12))
                    .layoutDirection(rtl ? .rtl : .ltr).background(.surfaceSunken)
                    .debugName("layout-safe-area")
            }
            StorySection("Lazy grid · 100,000 cells", "Only viewport rows plus overscan are constructed. This example supplies a row height that follows the text scale.") {
                TextScalerReader { scaler in
                    LazyGrid(0..<100_000, id: \.self, columns: 4,
                             rowHeights: .fixed(CGFloat(scaler.scale(48))), columnSpacing: 8, rowSpacing: 8) { index in
                        Text("Cell \(index + 1)").font(.caption)
                            .padding(8).frame(width: .percent(100)).background(.surfaceVariant).cornerRadius(6)
                    }.frame(height: 240).debugName("layout-lazy-grid")
                }
            }
            StorySection("Variable rows · 100,000 items", "Known row heights alternate between one and three lines. A cached cumulative index locates the viewport without scanning all rows during scrolling.") {
                Button("Reveal item 50,001") { target = target == nil ? 50_000 : nil }.buttonStyle(.secondary)
                VariableVirtualStack(0..<100_000, id: \.self, rowHeight: { index, _, scaler in
                    scaler.scale(index % 3 == 0 ? 84 : 36)
                }, spacing: 6, scrollToIndex: target) { index in
                    Text(index % 3 == 0 ? "Item \(index + 1)\nA taller row\nwith three authored lines" : "Item \(index + 1)")
                        .font(.caption).padding(8).frame(width: .percent(100))
                        .background(.surfaceVariant).cornerRadius(6)
                }.frame(height: 260).debugName("layout-variable-stack")
            }
        }
    }

    private func cell(_ title: String, detail: String) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Text(title).font(.bodyStrong)
            Text(detail).font(.caption).foregroundColor(.onSurfaceMuted)
        }.padding(12).frame(width: .percent(100)).background(.surfaceVariant).cornerRadius(6)
    }
}
