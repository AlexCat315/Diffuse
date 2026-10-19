import GuavaUI
import GuavaUIRuntime

struct RatingStory: View {
    let options: GalleryOptions
    @State private var whole = 3.0
    @State private var half = 2.5
    @State private var ten = 7.0
    @State private var custom = 3.0
    @State private var rtl = 3.0

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Whole stars", "Hover previews a score. Release inside to choose it; click the selected score again to clear. Release outside or press Escape to cancel.") {
                RatingSample(Rating("Overall rating", value: $whole) { $0.selection.isEnabled = options.isEnabled }) {
                    Text("Score: \(whole) / 5").font(.bodyStrong)
                    Button("Set 4", isEnabled: options.isEnabled) { whole = 4 }.buttonStyle(.secondary)
                    Button("Clear", isEnabled: options.isEnabled) { whole = 0 }.buttonStyle(.ghost)
                }
            }
            StorySection("Half stars & keyboard", "Each rating has one Tab stop. Left/Right follow the layout direction; Down/Up decrease/increase. Home/End reach the bounds; Delete clears when allowed. Swipe the strip gutter or scroll horizontally to reach wide ratings.") {
                RatingSample(Rating("Half-star rating", value: $half) { $0.selection.precision = .half; $0.selection.isEnabled = options.isEnabled }) {
                    Text("Score: \(half) / 5").font(.bodyStrong)
                }
                RatingSample(Rating("Ten-star rating", value: $ten) { $0.selection.maximum = 10; $0.selection.isEnabled = options.isEnabled; $0.appearance.size = .small }) {
                    Text("Score: \(ten) / 10").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("Read-only & disabled", "Read-only scores retain their exact fraction. Disabled ratings show the score with muted colors; neither accepts input or joins the Tab order.") {
                RatingSample(Rating("Average customer score", value: .constant(4.25)) { $0.selection.isReadOnly = true; $0.appearance.filled = .success }) {
                    Text("Average: 4.25 / 5").font(.body)
                }
                RatingSample(Rating("Disabled rating", value: .constant(2.5)) { $0.selection.isEnabled = false; $0.selection.precision = .half }) {
                    Text("Disabled: 2.5 / 5").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("Density & appearance", "SVG stars rasterize at their actual size and screen density. The seven-star example has a custom color and size, and keeps a minimum score of one half.") {
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 24) {
                    for size in ControlSize.allCases {
                        AnyView(Column(alignment: .leading, spacing: 4) {
                            Text(String(describing: size).capitalized).font(.caption).foregroundColor(.onSurfaceMuted)
                            Rating("\(size) sample", value: .constant(3.5)) { $0.selection.isReadOnly = true; $0.appearance.size = size }
                        })
                    }
                }
                RatingSample(Rating("Custom seven-star rating", value: $custom) {
                        $0.selection.maximum = 7; $0.selection.precision = .half; $0.selection.allowsClear = false
                        $0.selection.isEnabled = options.isEnabled
                        $0.appearance.starSize = 36; $0.appearance.spacing = 8; $0.appearance.filled = .accent
                    }) {
                    Text("Score: \(custom) / 7").font(.bodyStrong)
                }
            }
            StorySection("RTL", "Stars run from the trailing edge: the rightmost star is the first point, filled half stars grow from the right, and Left/Right arrows mirror.") {
                RatingSample(Rating("RTL rating", value: $rtl) {
                    $0.selection.precision = .half; $0.selection.isEnabled = options.isEnabled
                }) {
                    Text("Score: \(rtl) / 5").font(.bodyStrong)
                }
                .layoutDirection(.rtl).debugName("rating-rtl")
            }
        }
    }
}
