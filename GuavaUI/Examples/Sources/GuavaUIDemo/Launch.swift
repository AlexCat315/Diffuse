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
            if let width = Self.extent("--width", arguments: arguments) { $0.window.width = width }
            if let height = Self.extent("--height", arguments: arguments) { $0.window.height = height }
            $0.rendering.vsync = !arguments.contains("--no-vsync")
            $0.diagnostics.showsPerformanceHUD = arguments.contains("--performance-hud")
            $0.frames.policy = arguments.contains("--benchmark") ? .continuous : .eventDriven
            if let rate = Self.extent("--frame-rate", arguments: arguments) { $0.frames.targetRate = Double(rate) }
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

    private static func extent(_ name: String, arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1),
              let value = Int32(arguments[index + 1]), (1...8192).contains(value) else { return nil }
        return value
    }
}
