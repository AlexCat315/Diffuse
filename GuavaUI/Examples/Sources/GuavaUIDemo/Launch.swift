import GuavaUI
import GalleryContent
import CounterExample

@MainActor
struct ShowcaseLaunch {
    let configuration: ApplicationConfiguration
    let checkpoint: ApplicationCheckpoint?
    let root: AnyView

    init(arguments: [String]) {
        configuration = ApplicationConfiguration(title: "GuavaUI — Component Showcase") {
            $0.rendering.vsync = !arguments.contains("--no-vsync")
            $0.diagnostics.showsPerformanceHUD = arguments.contains("--performance-hud")
            $0.frames.policy = arguments.contains("--benchmark") ? .continuous : .eventDriven
        }
        if arguments.contains("--shared-counter") {
            let counter = CounterView()
            checkpoint = ApplicationCheckpoint(capture: { counter.checkpoint }, restore: { counter.restore($0) })
            root = AnyView(CounterContent(counter: counter))
        } else {
            let page = arguments.firstIndex(of: "--component").flatMap {
                arguments.indices.contains($0 + 1) ? GalleryCatalog.page(named: arguments[$0 + 1]) : nil
            } ?? .introduction
            checkpoint = nil
            root = AnyView(GalleryView(initialPage: page))
        }
    }
}
