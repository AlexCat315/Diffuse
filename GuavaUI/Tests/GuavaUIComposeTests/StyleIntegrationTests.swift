import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// End-to-end integration tests for Phase 7.5: build a small UI tree, walk
/// it after layout, and verify that visual attributes (backgroundColor,
/// foregroundColor, etc.) actually pick up theme tokens from the active
/// `.appearance(_:)` scope.
@Suite("Phase 7.5 Style Integration")
struct StyleIntegrationTests {

    // MARK: - Helpers

    private func collect(into out: inout [Node], from node: Node) {
        out.append(node)
        for c in node.children { collect(into: &out, from: c) }
    }

    private func allNodes(in tree: NodeTree) -> [Node] {
        guard let root = tree.root else { return [] }
        var out: [Node] = []
        collect(into: &out, from: root)
        return out
    }

    // MARK: - Divider

    @Test("Semantic .background(.divider) resolves against the active appearance")
    func dividerFollowsTheme() {
        // Use the SemanticBackgroundModifier path (resolved at apply time)
        // rather than the primitive's `_updateNode`-time fallback.
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Box { EmptyView() }.background(SemanticColorRef.divider).appearance(.light)
        )
        graph.computeLayout(width: 200, height: 4)

        let hit = allNodes(in: tree).first { $0.backgroundColor == Theme.defaultLight.colors.divider }
        #expect(hit != nil)
    }

    // MARK: - Panel

    @Test("Panel default style uses theme surface for the body background")
    func panelBodyUsesThemeSurface() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Panel("X") { Text("hi") }.appearance(.dark)
        )
        graph.computeLayout(width: 240, height: 160)

        // The Column emitted by DefaultPanelStyle carries
        // `.background(.surface)`. Walk the tree and look for the dark theme's
        // surface color.
        let nodes = allNodes(in: tree)
        let surfaceHits = nodes.filter { $0.backgroundColor == Theme.defaultDark.colors.surface }
        #expect(!surfaceHits.isEmpty)
    }

    @Test("Switching appearance flips Panel chrome from dark to light")
    func panelFollowsAppearanceFlip() {
        // Dark panel: surface should be the dark theme's `surface`.
        let darkTree = NodeTree()
        let darkGraph = ViewGraph(tree: darkTree, recomposer: Recomposer())
        darkGraph.install(root: Panel("X") { Text("hi") }.appearance(.dark))
        darkGraph.computeLayout(width: 200, height: 100)
        let darkHit = allNodes(in: darkTree).first { $0.backgroundColor == Theme.defaultDark.colors.surface }
        #expect(darkHit != nil)

        // Light panel: same node should now carry the light theme's `surface`.
        let lightTree = NodeTree()
        let lightGraph = ViewGraph(tree: lightTree, recomposer: Recomposer())
        lightGraph.install(root: Panel("X") { Text("hi") }.appearance(.light))
        lightGraph.computeLayout(width: 200, height: 100)
        let lightHit = allNodes(in: lightTree).first { $0.backgroundColor == Theme.defaultLight.colors.surface }
        #expect(lightHit != nil)

        // Sanity: the two themes have different surface colors so the test
        // actually distinguishes them.
        #expect(Theme.defaultDark.colors.surface != Theme.defaultLight.colors.surface)
    }

    // MARK: - List row

    @Test("Selected List row paints theme.colors.selection")
    func listRowSelectionFollowsTheme() {
        struct Row: Identifiable { let id: Int; let title: String }
        struct Harness: View {
            let items = [Row(id: 1, title: "A"), Row(id: 2, title: "B")]
            var body: some View {
                List(items, selection: .constant(2)) { row, _ in
                    Text(row.title)
                }
                .appearance(.light)
            }
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Harness())
        graph.computeLayout(width: 200, height: 120)

        let selectedFill = Theme.defaultLight.colors.selection
        let hits = allNodes(in: tree).filter { $0.backgroundColor == selectedFill }
        // Exactly one row should carry the selected fill.
        #expect(hits.count == 1)
    }

    // MARK: - TextField

    @Test("TextField default chrome resolves to theme.colors.surfaceSunken")
    func textFieldUsesThemeChrome() {
        struct H: View {
            @State var s = ""
            var body: some View {
                TextField("p", text: $s).appearance(.dark)
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: H())
        graph.computeLayout(width: 200, height: 36)

        let nodes = allNodes(in: tree)
        let hit = nodes.first { $0.backgroundColor == Theme.defaultDark.colors.surfaceSunken }
        #expect(hit != nil)
        #expect(hit?.cornerRadius == Theme.defaultDark.radius.sm)
    }

    @Test("TextField chrome flips with appearance")
    func textFieldFlipsWithAppearance() {
        struct H: View {
            @State var s = ""
            let app: Appearance
            var body: some View {
                Panel("X") { TextField("p", text: $s) }.appearance(app)
            }
        }
        let darkTree = NodeTree()
        let darkGraph = ViewGraph(tree: darkTree, recomposer: Recomposer())
        darkGraph.install(root: H(app: .dark))
        darkGraph.computeLayout(width: 200, height: 80)
        let dHit = allNodes(in: darkTree).first { $0.backgroundColor == Theme.defaultDark.colors.surfaceSunken }
        #expect(dHit != nil)

        let lightTree = NodeTree()
        let lightGraph = ViewGraph(tree: lightTree, recomposer: Recomposer())
        lightGraph.install(root: H(app: .light))
        lightGraph.computeLayout(width: 200, height: 80)
        let lHit = allNodes(in: lightTree).first { $0.backgroundColor == Theme.defaultLight.colors.surfaceSunken }
        #expect(lHit != nil)
    }

    // MARK: - Button

    @Test("PrimaryButtonStyle paints theme.colors.accent in resting state")
    func primaryButtonUsesThemeAccent() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Hi") {}.appearance(.light))
        graph.computeLayout(width: 120, height: 40)

        let accentHit = allNodes(in: tree).first { $0.backgroundColor == Theme.defaultLight.colors.accent }
        #expect(accentHit != nil)
    }

    @Test("DestructiveButtonStyle paints theme.colors.error")
    func destructiveButtonUsesThemeError() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button("Delete", role: .destructive) {}
                .buttonStyle(.destructive)
                .appearance(.dark)
        )
        graph.computeLayout(width: 120, height: 40)

        let errorHit = allNodes(in: tree).first { $0.backgroundColor == Theme.defaultDark.colors.error }
        #expect(errorHit != nil)
    }

    // MARK: - Mixed scope

    @Test("Inner .appearance overrides outer for nested Panels")
    func nestedAppearanceOverride() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                Panel("Outer") {
                    Panel("Inner") { Text("nested") }
                        .appearance(.light)
                }
            }
            .appearance(.dark)
        )
        graph.computeLayout(width: 240, height: 240)

        let darkSurface = Theme.defaultDark.colors.surface
        let lightSurface = Theme.defaultLight.colors.surface
        let nodes = allNodes(in: tree)
        // Both surface colors should appear somewhere — outer panel uses
        // dark, inner panel uses light.
        #expect(nodes.contains { $0.backgroundColor == darkSurface })
        #expect(nodes.contains { $0.backgroundColor == lightSurface })
    }
}
