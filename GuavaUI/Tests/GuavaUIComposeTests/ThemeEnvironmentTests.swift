import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ThemeEnvironment + Semantic Modifiers")
struct ThemeEnvironmentTests {

    private func descendant(of root: Node) -> Node {
        var cursor = root
        while let next = cursor.children.first {
            cursor = next
        }
        return cursor
    }

    @Test(".theme(_:) makes Node.theme return the provided theme")
    func themeProvision() {
        var custom = Theme.defaultDark
        custom.colors.accent = Color(r: 0.9, g: 0.1, b: 0.1)

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf").theme(custom))

        let leaf = descendant(of: tree.root!)
        #expect(leaf.theme.colors.accent == Color(r: 0.9, g: 0.1, b: 0.1))
    }

    @Test("Without .theme(_:), Node.theme falls back to Theme.defaultDark")
    func themeFallback() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf"))

        let leaf = descendant(of: tree.root!)
        #expect(leaf.theme.colors.accent == Theme.defaultDark.colors.accent)
    }

    @Test("Semantic background resolves against the provided theme on first install")
    func semanticBackgroundOnInstall() {
        var custom = Theme.defaultDark
        custom.colors.surface = Color(r: 0.5, g: 0.0, b: 0.5)

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf")
            .background(SemanticColorRef.surface)
            .theme(custom))

        // The semantic-background modifier writes onto the _DebugNode's
        // primitive node (a descendant of the synthetic theme anchor).
        let leaf = descendant(of: tree.root!)
        #expect(leaf.backgroundColor == Color(r: 0.5, g: 0.0, b: 0.5))
    }

    @Test("Semantic foreground resolves against the provided theme")
    func semanticForegroundOnInstall() {
        var custom = Theme.defaultDark
        custom.colors.onSurface = Color(r: 0.1, g: 0.9, b: 0.2)

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf")
            .foregroundColor(SemanticColorRef.onSurface)
            .theme(custom))

        let leaf = descendant(of: tree.root!)
        #expect(leaf.foregroundColor == Color(r: 0.1, g: 0.9, b: 0.2))
    }

    @Test("Semantic font writes both font and lineHeight attachments")
    func semanticFontWritesAttachments() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf")
            .font(SemanticFontRef.title))

        let leaf = descendant(of: tree.root!)
        let font = leaf.attachments[StyleAttachmentKey.font] as? Font
        let lineHeight = leaf.attachments[StyleAttachmentKey.lineHeight] as? Float
        #expect(font == Theme.defaultDark.typography.title.font)
        #expect(lineHeight == Theme.defaultDark.typography.title.lineHeight)
    }

    @Test("Nested .theme(_:) overrides an outer one for descendants")
    func nestedThemeOverrides() {
        var outer = Theme.defaultDark
        outer.colors.accent = Color(r: 1, g: 0, b: 0)
        var inner = Theme.defaultDark
        inner.colors.accent = Color(r: 0, g: 1, b: 0)

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "leaf")
            .theme(inner)
            .theme(outer))

        let leaf = descendant(of: tree.root!)
        // Innermost wins.
        #expect(leaf.theme.colors.accent == Color(r: 0, g: 1, b: 0))
    }
}
