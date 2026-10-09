import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct ImageStory: View {
    let options: GalleryOptions
    @State private var source = "bundled"
    @State private var retryID = 0
    static var resource: BundleImageResource { .svg(named: "gallery-landscape", in: .module) }
    private var url: URL? {
        switch source {
        case "remote": URL(string: "https://avatars.githubusercontent.com/u/5518?v=4")
        case "missing": URL(fileURLWithPath: "/guava-gallery-missing.png")
        case "empty": nil
        default: Self.resource.url
        }
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Content modes", "Fit preserves the whole source; fill crops centrally inside the container; stretch changes its aspect ratio.") {
                Row(alignment: .center, spacing: 20) {
                    image(.fit, title: "Fit")
                    image(.fill, title: "Fill")
                    image(.stretch, title: "Stretch")
                }
            }
            StorySection("Asynchronous loading", "Switch between a bundled SVG, a remote photo, a missing file and no source. Retry starts a new request after failure.") {
                ButtonGroup([.init("bundled", "Bundled"), .init("remote", "Remote"), .init("missing", "Missing"), .init("empty", "Empty")],
                    selection: Binding(get: { Optional(source) }, set: { source = $0 ?? "bundled" }), isEnabled: options.isEnabled)
                Row(alignment: .center, spacing: 20) {
                    AsyncImage(url: url, width: 200, height: 140, contentMode: .fill, retryID: retryID) { phase in
                        surface(phase, width: 200, height: 140)
                    }.background(.surfaceVariant).cornerRadius(12).border(.border, width: 1)
                    Column(alignment: .leading, spacing: 12) {
                        Text("Source: \(source.capitalized)").font(.bodyStrong)
                        Text("Request: \(retryID + 1)").font(.caption).foregroundColor(.onSurfaceMuted)
                        Button("Retry", isEnabled: options.isEnabled && url != nil) { retryID += 1 }
                    }
                }
            }
        }
    }
    private func image(_ mode: Image.ContentMode, title: String) -> some View {
        Column(alignment: .leading, spacing: 8) {
            AsyncImage(url: Self.resource.url, width: 160, height: 130, contentMode: mode) { phase in
                surface(phase, width: 160, height: 130)
            }.background(.surfaceVariant).cornerRadius(8).border(.border, width: 1)
            Text(title).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
    private func surface(_ phase: AsyncImagePhase, width: Float, height: Float) -> AnyView {
        switch phase {
        case .success(let image): return AnyView(image.cornerRadius(8))
        case .loading:
            return AnyView(Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 8) {
                Spinner(size: 20)
                Text("Loading…").font(.caption).foregroundColor(.onSurfaceMuted)
            }.frame(width: width, height: height).accessibility { $0.label = "Loading image"; $0.combinesChildren = true })
        case .empty, .failure:
            let failed: Bool
            let detail: String
            if case .failure(let error) = phase { failed = true; detail = error.description }
            else { failed = false; detail = "Choose an image source" }
            return AnyView(Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 8) {
                Icon(UICommonIcons.user, size: 28, color: .onSurfaceMuted)
                Text(failed ? "Image unavailable" : "No image").font(.caption)
            }.frame(width: width, height: height).tooltip(detail)
                .accessibility { $0.label = failed ? "Image unavailable" : "No image"; $0.help = detail; $0.combinesChildren = true })
        }
    }
}
