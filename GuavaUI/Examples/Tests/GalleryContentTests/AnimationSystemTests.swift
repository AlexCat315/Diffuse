import Foundation
import Testing
import GuavaUI
import GuavaUIRuntime
@testable import GalleryContent

@Suite("Applied animation system", .serialized)
@MainActor
struct AnimationSystemTests {
    @Test("Tracks, domain phases and explicit loops finish or cancel without leaked clocks",
          arguments: [Float(390), 720, 1280], [Appearance.light, .dark])
    func sequences(width: Float, appearance: Appearance) throws {
        try fixture(width: width, appearance: appearance) { graph, scheduler in
            try activate("animation-sequence-play", graph); settle(graph, width)
            #expect(texts(graph.tree.root!).contains("Working"))
            scheduler.tick(deltaTime: 0.08); settle(graph, width)
            #expect(try named("animation-keyframe", graph).transform.scale > 1)
            try activate("animation-geometry-move", graph); settle(graph, width)
            scheduler.tick(deltaTime: 0.2); settle(graph, width)
            #expect(texts(graph.tree.root!).contains("Done"))
            scheduler.tick(deltaTime: 1); settle(graph, width)
            #expect(try named("animation-keyframe", graph).transform.scale == 1)
            #expect(scheduler.activeCount == 0)
            try activate("animation-loop-toggle", graph); settle(graph, width)
            scheduler.tick(deltaTime: 2.17); settle(graph, width)
            #expect(scheduler.activeCount > 0)
            try activate("animation-loop-toggle", graph); settle(graph, width)
            #expect(!texts(graph.tree.root!).contains("Repeating"))
            scheduler.tick(deltaTime: 1); settle(graph, width)
            #expect(scheduler.activeCount == 0)
            #expect(!graph.recomposer.hasPending)
        }
    }

    @Test("Shared geometry moves, resizes and reverses from its displayed rectangle")
    func geometry() throws {
        try fixture(width: 390) { graph, scheduler in
            let first = try named("animation-geometry-surface", graph).absoluteFrame
            #expect(first.width == 90 && first.height == 28)
            try activate("animation-geometry-move", graph); settle(graph, 390)
            #expect(try named("animation-geometry-surface", graph).absoluteFrame == first)
            scheduler.tick(deltaTime: 0.08); settle(graph, 390)
            let halfway = try named("animation-geometry-surface", graph).absoluteFrame
            #expect(halfway.width > 90 && halfway.width < 130 && halfway.minX > first.minX)
            try activate("animation-geometry-move", graph); settle(graph, 390)
            #expect(try named("animation-geometry-surface", graph).absoluteFrame == halfway)
            scheduler.tick(deltaTime: 1); settle(graph, 390)
            #expect(try named("animation-geometry-surface", graph).absoluteFrame == first)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Numeric accessibility receives the target while display interpolates; completion fires once")
    func numbersAndCompletion() throws {
        try fixture(width: 720) { graph, scheduler in
            try activate("animation-number-add", graph); settle(graph, 720)
            let number = try named("animation-number", graph)
            #expect(number.accessibility?.label == "22")
            #expect(texts(number).contains("12"))
            scheduler.tick(deltaTime: 0.09); settle(graph, 720)
            #expect(!texts(number).contains("12") && !texts(number).contains("22"))
            // Replacing the parent view value must refresh the callback binding
            // while preserving this already-running numeric controller.
            try activate("animation-geometry-move", graph); settle(graph, 720)
            scheduler.tick(deltaTime: 1); settle(graph, 720)
            #expect(texts(number).contains("22"))
            try activate("animation-completion-play", graph); settle(graph, 720)
            scheduler.tick(deltaTime: 0.15); settle(graph, 720)
            let bar = try named("animation-completion-bar", graph)
            #expect(bar.frame.width > 80 && bar.frame.width < 200)
            #expect(texts(graph.tree.root!).contains("Completed: 0"))
            scheduler.tick(deltaTime: 1); settle(graph, 720)
            #expect(texts(graph.tree.root!).contains("Completed: 1"))
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Reduced motion settles sequences, geometry, numbers and loops without scheduler work")
    func reducedMotion() throws {
        try fixture(width: 390, reduced: true) { graph, scheduler in
            for button in ["animation-sequence-play", "animation-geometry-move", "animation-number-add", "animation-loop-toggle"] {
                try activate(button, graph); settle(graph, 390)
            }
            #expect(texts(graph.tree.root!).contains("Done"))
            #expect(try named("animation-geometry-surface", graph).absoluteFrame.width == 130)
            #expect(texts(try named("animation-number", graph)).contains("22"))
            #expect(scheduler.activeCount == 0)
            #expect(!graph.recomposer.hasPending)
        }
    }

    @Test("Unmounting the actual repeating story immediately clears its scheduler")
    func unmount() throws {
        try fixture(width: 720) { graph, scheduler in
            try activate("animation-loop-toggle", graph); settle(graph, 720)
            #expect(scheduler.activeCount > 0)
            graph.install(root: EmptyView())
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Geometry completion waits for layout enrollment when the host ticks before layout")
    func geometryCompletion() throws {
        try fixture(width: 720) { graph, scheduler in
            var completions = 0
            try withAnimation(Animation(duration: 0.4, curve: .linear), completionCriteria: .removed) {
                try activate("animation-geometry-move", graph)
            } completion: { completions += 1 }
            graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 0.01)
            #expect(completions == 0)
            settle(graph, 720)
            scheduler.tick(deltaTime: 0.2); settle(graph, 720)
            #expect(completions == 0)
            scheduler.tick(deltaTime: 1); settle(graph, 720)
            #expect(completions == 1 && scheduler.activeCount == 0)
        }
    }

    @Test("Explicit nil snaps a numeric transition and leaves the scene idle")
    func disabledNumericAnimation() throws {
        try fixture(width: 390) { graph, scheduler in
            try withAnimation(nil) { try activate("animation-number-add", graph) }
            settle(graph, 390)
            #expect(texts(try named("animation-number", graph)).contains("22"))
            #expect(scheduler.activeCount == 0 && !graph.recomposer.hasPending)
        }
    }

    private func fixture(width: Float, appearance: Appearance = .light, reduced: Bool = false,
                         work: (ViewGraph, AnimatorScheduler) throws -> Void) rethrows {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext(), scheduler = AnimatorScheduler()
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 10) }
            graph.install(root: AnimationSystemExamples(isEnabled: true)
                .theme(appearance == .light ? .defaultLight : .defaultDark).reducedMotion(reduced))
            settle(graph, width)
            #expect(scheduler.activeCount == 0)
            try work(graph, scheduler)
        } }
    }
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func texts(_ node: Node) -> [String] {
        var result: [String] = []
        for node in nodes(node) { if let text = node.layoutNode?.textInputs?.text { result.append(text) } }
        return result
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        var result: Node?
        for node in nodes(graph.tree.root!) {
            if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { result = node; break }
        }
        return try #require(result)
    }
    private func activate(_ name: String, _ graph: ViewGraph) throws {
        let action = try #require(try named(name, graph).accessibilityActions.activate); action()
    }
    private func settle(_ graph: ViewGraph, _ width: Float) {
        for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 1_800) }
    }
}
