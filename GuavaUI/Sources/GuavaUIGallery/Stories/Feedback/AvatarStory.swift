import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct AvatarStory: View {
    let options: GalleryOptions
    @State private var source = "bundled"
    @State private var limit: Float = 3
    @State private var overflow: AvatarOverflow = .count
    @State private var overlap = 0.3
    static var portrait: URL? { BundleImageResource.svg(named: "avatar-portrait", in: .module).url }
    private var imageURL: URL? {
        switch source {
        case "remote": URL(string: "https://avatars.githubusercontent.com/u/5518?v=4")
        case "missing": URL(fileURLWithPath: "/guava-gallery-missing-avatar.png")
        case "initials": nil
        default: Self.portrait
        }
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Image & fallback", "Images load off the UI loop. Initials remain visible during loading and after an error; changing the source cancels stale work.") {
                ButtonGroup( [.init("bundled", "Bundled"), .init("remote", "Remote"), .init("missing", "Missing"), .init("initials", "Initials")],
                            selection: Binding(get: { Optional(source) }, set: { source = $0 ?? "bundled" }), isEnabled: options.isEnabled)
                Row(alignment: .center, spacing: 20) {
                    Avatar("Jason Lee", imageURL: imageURL)
                    Column(alignment: .leading, spacing: 4) {
                        Text("Jason Lee").font(.bodyStrong)
                        Text("Design systems · \(source.capitalized) source").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
            }
            StorySection("Unicode initials", "Two word initials or two graphemes from a single name. Accented names, Chinese characters and emoji share the same text layout.") {
                Row(alignment: .center, spacing: 16) {
                    for name in ["Jason Lee", "huacnlee", "李 小龙", "陈珊", "Émile Zola", "👩🏽‍💻 coder", ""] {
                        AnyView(Column(alignment: .center, spacing: 8) {
                            Avatar(name)
                            Text(name.isEmpty ? "Anonymous" : name, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted).clipped()
                        }.frame(width: 96))
                    }
                }
            }
            StorySection("Avatar groups", "Earlier members paint above later members. An explicit identity keeps image state with each person when a group reorders.") {
                Row(alignment: .center, spacing: 16) {
                    Text("Visible limit").font(.caption)
                    NumberField(value: $limit, decimals: 0, isEnabled: options.isEnabled, minValue: 0, maxValue: 8, step: 1, showsStepper: true).frame(width: 110)
                    Select(selection: $overflow, options: [.init(value: .count, label: "Count"), .init(value: .ellipsis, label: "Ellipsis"), .init(value: .hidden, label: "Hidden")], isEnabled: options.isEnabled).frame(width: 140)
                    Text("Overlap").font(.caption)
                    Slider(value: $overlap, range: 0...0.7, isEnabled: options.isEnabled).frame(width: 180)
                }
                AvatarGroup(members) { $0.limit = Int(limit); $0.overflow = overflow; $0.overlap = Float(overlap) }
                Text("6 members · zero limit shows only the overflow indicator").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Sizes & shapes", "Shared density sets the default diameter; an explicit size overrides it. Images crop inside the same outline as initials.") {
                Row(alignment: .center, spacing: 24) {
                    for size in ControlSize.allCases { Avatar("Jason Lee") { $0.size = size } }
                    Avatar("Jason Lee", imageURL: Self.portrait) { $0.diameter = 100; $0.shape = .roundedRectangle(radius: 20); $0.borderWidth = 3 }
                    Avatar("陈珊") { $0.diameter = 72; $0.shape = .square }
                }
            }
        }
    }
    private var members: [Avatar] {
        [Avatar("Jason Lee", id: "jason", imageURL: Self.portrait), Avatar("Alice Johnson", id: "alice"),
         Avatar("陈珊", id: "chen"), Avatar("Diana Prince", id: "diana"), Avatar("Émile Zola", id: "emile"), Avatar("Bob Smith", id: "bob")]
    }
}
