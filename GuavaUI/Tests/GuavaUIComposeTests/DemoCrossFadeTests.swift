import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Step 9 — Demo cross-fade. Wrapping the appearance toggle in
/// `.animation(_:value:)` interpolates every semantic colour resolved
/// against the new theme instead of snapping. This test mirrors the
/// production demo: a subtree with `.appearance(_:)` and `.background(.background)`
/// keyed on an Equatable `Appearance` state.
@Suite("Phase 8 / Demo cross-fade", .serialized)
struct DemoCrossFadeTests: GuavaUIComposeSerializedSuite {

    struct CrossFadeHarness: View {
        @State var appearance: Appearance = .dark
        var body: some View {
            _DebugNode(label: "x")
                .background(.background)
                .appearance(appearance)
                .animation(.easeInOut(duration: 0.30), value: appearance)
        }
    }

    private func findFilled(_ root: Node) -> Node? {
        if let bg = root.backgroundColor, bg.a > 0 { return root }
        for c in root.children {
            if let n = findFilled(c) { return n }
        }
        return nil
    }

    @Test("Toggling appearance cross-fades the background through the scheduler")
    func appearanceToggleCrossFades() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = CrossFadeHarness()
            graph.install(root: h)

            let darkBg = Theme.defaultDark.colors.background
            let lightBg = Theme.defaultLight.colors.background

            let filled = findFilled(tree.root!)
            #expect(filled?.backgroundColor == darkBg)
            #expect(scheduler.activeCount == 0)

            h.$appearance.wrappedValue = .light
            recomp.commitAll()

            // Animation registered; bg still at dark at t=0.
            #expect(scheduler.activeCount >= 1)
            #expect(filled?.backgroundColor == darkBg)

            // Halfway through 0.30 s.
            scheduler.tick(deltaTime: 0.15)
            let mid = filled?.backgroundColor
            #expect(mid != darkBg)
            #expect(mid != lightBg)

            scheduler.tick(deltaTime: 0.15)
            #expect(filled?.backgroundColor == lightBg)
            #expect(scheduler.activeCount == 0)
        }
    } }
}
