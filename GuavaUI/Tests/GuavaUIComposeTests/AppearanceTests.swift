import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7.5 Appearance")
struct AppearanceTests {

    @Test("Theme.defaultLight has light surface")
    func lightSurface() {
        let bg = Theme.defaultLight.colors.background
        // Light theme background should be near-white (channel sum well above
        // 2.5/3.0 in 0…1 space).
        let sum = Float(bg.r) + Float(bg.g) + Float(bg.b)
        #expect(sum > 2.7)
    }

    @Test("Theme.defaultDark has dark surface")
    func darkSurface() {
        let bg = Theme.defaultDark.colors.background
        let sum = Float(bg.r) + Float(bg.g) + Float(bg.b)
        #expect(sum < 0.5)
    }

    @Test(".appearance(.light) installs DefaultLightTheme on the subtree")
    func appearanceLight() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _DebugNode(label: "x").appearance(.light))

        var cursor = tree.root!
        while let next = cursor.children.first { cursor = next }
        #expect(cursor.theme.colors.background == Theme.defaultLight.colors.background)
    }

    @Test(".appearance(.dark) installs DefaultDarkTheme on the subtree")
    func appearanceDark() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _DebugNode(label: "x").appearance(.dark))

        var cursor = tree.root!
        while let next = cursor.children.first { cursor = next }
        #expect(cursor.theme.colors.background == Theme.defaultDark.colors.background)
    }

    @Test("Inner .appearance overrides outer for descendants")
    func nestedAppearance() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                _DebugNode(label: "inner").appearance(.light)
            }
            .appearance(.dark)
        )
        var cursor = tree.root!
        while let next = cursor.children.first { cursor = next }
        #expect(cursor.theme.colors.background == Theme.defaultLight.colors.background)
    }
}
