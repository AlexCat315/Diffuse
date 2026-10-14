import Foundation
import Testing
import GuavaUI
import GuavaUIRuntime
@testable import GalleryContent

@Suite("Gallery timing curves", .serialized)
@MainActor
struct AnimationTests {
    @Test("Four curves animate geometry in both directions across widths and themes",
          arguments: [Float(390), 720, 1280], [Appearance.light, .dark])
    func geometry(width: Float, appearance: Appearance) throws {
        try fixture(width: width, appearance: appearance) { graph, scheduler in
            for (choice, intermediate): (String, Float) in [
                ("steps", 104), ("linear", 137.6), ("bounce", 116.3), ("elastic", 230)
            ] {
                try activate("animation-curve-choice-\(choice)", in: graph)
                settle(graph, width: width)
                scheduler.tick(deltaTime: 1); settle(graph, width: width)
                #expect(try named("animation-curve-choice-\(choice)", in: graph).accessibility?.state.isSelected == true)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 80)
                try activate("animation-curve-play", in: graph); settle(graph, width: width)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 80)
                scheduler.tick(deltaTime: 0.2); settle(graph, width: width)
                #expect(abs(Float(try named("animation-curve-bar", in: graph).frame.width) - intermediate) <= 1)
                scheduler.tick(deltaTime: 1); settle(graph, width: width)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 200)
                #expect(scheduler.activeCount == 0)
                try activate("animation-curve-play", in: graph); settle(graph, width: width)
                scheduler.tick(deltaTime: 0.2); settle(graph, width: width)
                #expect(abs(Float(try named("animation-curve-bar", in: graph).frame.width) - (280 - intermediate)) <= 1)
                scheduler.tick(deltaTime: 1); settle(graph, width: width)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 80)
                #expect(scheduler.activeCount == 0)
            }
        }
    }

    @Test("Reduced motion snaps each curve to its target without scheduling")
    func reducedMotion() throws {
        try fixture(width: 390, reducedMotion: true) { graph, scheduler in
            for choice in ["steps", "linear", "bounce", "elastic"] {
                try activate("animation-curve-choice-\(choice)", in: graph); settle(graph, width: 390)
                try activate("animation-curve-play", in: graph); settle(graph, width: 390)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 200)
                #expect(scheduler.activeCount == 0)
                try activate("animation-curve-play", in: graph); settle(graph, width: 390)
                #expect(try named("animation-curve-bar", in: graph).frame.width == 80)
            }
        }
    }

    @Test("Disabled gallery options remove curve and playback activation")
    func disabled() throws {
        try fixture(width: 390, isEnabled: false) { graph, scheduler in
            for name in ["animation-curve-play"] + ["steps", "linear", "bounce", "elastic"].map({ "animation-curve-choice-\($0)" }) {
                let node = try named(name, in: graph)
                #expect(node.accessibility?.state.isEnabled == false)
                #expect(node.accessibilityActions.activate == nil)
            }
            #expect(try named("animation-curve-bar", in: graph).frame.width == 80)
            #expect(scheduler.activeCount == 0)
        }
    }

    private func fixture(width: Float, appearance: Appearance = .light, reducedMotion: Bool = false,
                         isEnabled: Bool = true, work: (ViewGraph, AnimatorScheduler) throws -> Void) rethrows {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext(), scheduler = AnimatorScheduler()
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1) }
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = width == 390 ? [.touch, .keyboard] : width == 720 ? [.touch, .pointer, .keyboard] : [.pointer, .keyboard]
            var options = GalleryOptions()
            options.isEnabled = isEnabled
            graph.install(root: AnimationStory(options: options)
                .theme(appearance == .light ? .defaultLight : .defaultDark)
                .surfaceEnvironment(surface).reducedMotion(reducedMotion))
            settle(graph, width: width)
            #expect(scheduler.activeCount == 0)
            try work(graph, scheduler)
        } }
    }

    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        var pending = graph.tree.root.map { [$0] } ?? []
        var found: Node?
        while let node = pending.popLast() {
            if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { found = node; break }
            pending.append(contentsOf: node.children)
        }
        return try #require(found)
    }
    private func activate(_ name: String, in graph: ViewGraph) throws {
        let action = try #require(try named(name, in: graph).accessibilityActions.activate)
        action()
    }
    private func settle(_ graph: ViewGraph, width: Float) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 700) }
    }
}
