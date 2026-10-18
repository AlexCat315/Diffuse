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
            root = AnyView(ShowcaseSurface(arguments: arguments) {
                GalleryView(initialPage: page,
                            appearance: arguments.contains("--dark") ? .dark : .light,
                            textScale: Self.argument("--text-scale", in: arguments).flatMap(Double.init) ?? 1)
            })
        }
    }

    private static func extent(_ name: String, arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1),
              let value = Int32(arguments[index + 1]), (1...8192).contains(value) else { return nil }
        return value
    }

    nonisolated static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// A test surface uses the host's live viewport and the same unified input
/// dispatcher as a device. Overrides are process-local preview settings.
private struct ShowcaseSurface<Content: View>: View {
    let arguments: [String]
    let content: Content

    init(arguments: [String], @ViewBuilder content: () -> Content) {
        self.arguments = arguments
        self.content = content()
    }

    var body: some View {
        SurfaceReader { inherited in
            content.surfaceEnvironment(environment(inherited))
                .reducedMotion(arguments.contains("--reduce-motion") || inherited.reducesMotion)
                .layoutDirection(arguments.contains("--rtl") ? .rtl : .ltr)
        }
    }

    private func environment(_ inherited: UIEnvironment) -> UIEnvironment {
        var surface = inherited
        switch ShowcaseLaunch.argument("--input", in: arguments) {
        case "touch": surface.input = [.touch]
        case "mixed": surface.input = [.touch, .pointer, .keyboard]
        case "pointer": surface.input = [.pointer, .keyboard]
        default: break
        }
        if arguments.contains("--reduce-motion") { surface.reducesMotion = true }
        return surface
    }
}
