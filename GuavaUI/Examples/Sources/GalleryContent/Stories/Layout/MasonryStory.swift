import GuavaUI
import GuavaUIRuntime

struct MasonryStory: View {
    let options: GalleryOptions
    @State private var extraCards = 0
    private let heights: [Float] = [112, 164, 128, 188, 96, 144, 116, 176]

    var body: some View {
        StorySection(
            "Waterfall columns",
            "Cards flow into the shortest column, so mixed heights pack without row gaps. The column count follows the available width; resize the window or add cards to see the reflow."
        ) {
            Row(alignment: .center, spacing: 8) {
                Button("Add card", isEnabled: options.isEnabled) { extraCards += 1 }
                    .buttonStyle(.secondary)
                Button("Reset", isEnabled: options.isEnabled) { extraCards = 0 }
                    .buttonStyle(.ghost)
                Spacer()
                Text("\(8 + extraCards) cards · 1–2 columns")
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }
            Masonry(minimumColumnWidth: 220, maximumColumns: 2,
                    columnSpacing: 14, itemSpacing: 14) {
                for index in 0..<(8 + extraCards) {
                    AnyView(card(index))
                }
            }
            .frame(width: .percent(100))
            .debugName("masonry-demo")
            Text("Minimum column width 220pt · maximum 2 columns · 14pt gaps")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }

    private func card(_ index: Int) -> some View {
        let height = heights[index % heights.count]
        return Box(direction: .column, alignItems: .stretch, spacing: 9) {
            Row(alignment: .center, spacing: 8) {
                Icon(UIIcons.Media.image, size: 16, color: .accent)
                Text("Masonry card \(index + 1)").font(.bodyStrong).frame(minWidth: 0).flex(1, shrink: 1, basis: 0)
            }
            Text("Mixed-height content packs into the shortest column. This card is \(Int(height))pt tall.")
                .font(.caption).foregroundColor(.onSurfaceVariant)
            Spacer(minLength: 0)
            Text(index.isMultiple(of: 2) ? "Long form" : "Short form")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(14)
        .frame(width: .percent(100), height: .points(height))
        .background(index.isMultiple(of: 2) ? SemanticColorRef.surface : .surfaceVariant)
        .cornerRadius(12)
        .border(.border, width: 1)
        .debugName("masonry-card-\(index)")
    }
}

/// Compact two-card sample reused by the adaptive preview matrix.
struct MasonrySample: View {
    var body: some View {
        Masonry(minimumColumnWidth: 220, maximumColumns: 2, columnSpacing: 10, itemSpacing: 10) {
            sampleCard(1, height: 70)
            sampleCard(2, height: 100)
        }
        .frame(width: .percent(100))
        .debugName("masonry-sample")
    }

    private func sampleCard(_ index: Int, height: Float) -> some View {
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text("Card \(index)").font(.label)
            Text("Mixed height").font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(10)
        .frame(width: .percent(100), height: .points(height))
        .background(index.isMultiple(of: 2) ? SemanticColorRef.surface : .surfaceVariant)
        .cornerRadius(10)
        .border(.border, width: 1)
        .debugName("masonry-sample-card-\(index)")
    }
}
