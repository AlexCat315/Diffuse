import Testing
import CoreGraphics
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7.5 ButtonStyle", .serialized)
struct ButtonStyleTests: GuavaUIComposeSerializedSuite {

    // Find the inner-most node with a non-clear background — that's the
    // styled body's filled rect produced by the active style.
    private func findFilled(_ root: Node) -> Node? {
        if let bg = root.backgroundColor, bg.a > 0 { return root }
        for c in root.children {
            if let n = findFilled(c) { return n }
        }
        return nil
    }

    @Test("Default style is PrimaryButtonStyle — accent background at rest")
    func defaultStyleIsPrimary() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Save") { })

        let filled = findFilled(tree.root!)
        #expect(filled != nil)
        #expect(filled?.backgroundColor == Theme.defaultDark.colors.accent)
    } }

    @Test(".buttonStyle(.secondary) overrides the default")
    func explicitSecondaryStyle() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button("Cancel") { }
                .buttonStyle(.secondary)
        )

        let filled = findFilled(tree.root!)
        #expect(filled?.backgroundColor == Theme.defaultDark.colors.surfaceVariant)
    } }

    @Test(".buttonStyle(.destructive) uses the error color slot")
    func destructiveStyle() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button("Delete", role: .destructive) { }
                .buttonStyle(.destructive)
        )

        let filled = findFilled(tree.root!)
        #expect(filled?.backgroundColor == Theme.defaultDark.colors.error)
    } }

    @Test("isEnabled = false renders disabled appearance")
    func disabledButton() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Save", isEnabled: false) { })

        let filled = findFilled(tree.root!)
        #expect(filled?.backgroundColor == Theme.defaultDark.colors.surfaceVariant)
    } }

    @Test(".theme(_:) override flows into the button style")
    func customThemeFlowsThroughStyle() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var custom = Theme.defaultDark
        custom.colors.accent = Color(r: 0.0, g: 1.0, b: 0.5)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button("Go") { }
                .theme(custom)
        )

        let filled = findFilled(tree.root!)
        #expect(filled?.backgroundColor == Color(r: 0.0, g: 1.0, b: 0.5))
    } }

    @Test("Color.darker / lighter / mixed sanity")
    func colorAdjustHelpers() {
        let red = Color(r: 1, g: 0, b: 0)
        #expect(red.darker(0.5).r == 0.5)
        #expect(red.lighter(0.5).g == 0.5)
        let mid = red.mixed(with: Color(r: 0, g: 1, b: 0), amount: 0.5)
        #expect(mid.r == 0.5 && mid.g == 0.5)
    }
}
