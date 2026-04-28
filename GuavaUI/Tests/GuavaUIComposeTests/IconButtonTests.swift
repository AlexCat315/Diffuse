import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Coverage for `IconButton` — verifies the texture-source path materialises
/// a Button hierarchy with an Image child carrying the supplied texture
/// id, and that pointer-driven activation invokes the action closure.
@Suite("IconButton", .serialized)
struct IconButtonTests: GuavaUIComposeSerializedSuite {

    /// Walk the tree looking for the ButtonHost node — it's the only
    /// node carrying the press attachment key, regardless of how many
    /// wrapper levels (`IconButton` → `Button` → `_StatefulButton`)
    /// sit above it.
    private func findButtonHost(_ root: Node) -> Node? {
        if root.attachments[ButtonHost.pressedKey] != nil { return root }
        for c in root.children {
            if let n = findButtonHost(c) { return n }
        }
        return nil
    }

    @Test("IconButton(textureID:) renders a button shell whose label is an Image")
    func texturePathBuildsButton() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            IconButton(textureID: 7, size: 16) {}
        )
        graph.computeLayout(width: 60, height: 40)

        // The button host is hit-testable.
        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        #expect(host.isHitTestable == true)
        var sawIcon = false
        func walk(_ n: Node) {
            let f = n.frame
            if abs(Float(f.width) - 16) < 0.5 && abs(Float(f.height) - 16) < 0.5 {
                sawIcon = true
            }
            for c in n.children { walk(c) }
        }
        walk(host)
        #expect(sawIcon)
    } }

    @Test("Click on IconButton invokes the action closure exactly once")
    func clickInvokesAction() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var fired = 0
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root:
            IconButton(textureID: 7, size: 16) { fired += 1 }
        )
        graph.computeLayout(width: 60, height: 40)

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        let handler = registry.handlers(for: host).pointer
        #expect(handler != nil)
        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        _ = handler!(evt, .down, .target)
        recomp.commitAll()
        _ = handler!(evt, .up, .target)
        recomp.commitAll()

        #expect(fired == 1)
    } }

    @Test("IconButton(file:) without a registry falls back to TextureID.none without crashing")
    func fileFallbackWithoutRegistry() { GlobalTestLock.locked {
        // Make sure no registry is installed for this test.
        ImageAssetRegistryHolder.current = nil

        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            IconButton(file: "/this/path/does/not/exist.png", size: 14) {}
        )
        graph.computeLayout(width: 60, height: 40)

        // Materialised without crashing; layout produced a button host.
        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        #expect(host.isHitTestable == true)
    } }

    @Test("IconButton default tint defers to semantic foreground")
    func defaultTintIsSemantic() {
        let button = IconButton(textureID: 1) {}
        #expect(button.tint == nil)
    }

    @Test("IconButton explicit tint remains supported")
    func explicitTintStillWorks() {
        let custom = Color(r: 0.25, g: 0.5, b: 0.75, a: 1)
        let button = IconButton(textureID: 1, tint: custom) {}
        #expect(button.tint == custom)
    }

    @Test("IconButton tooltip value is preserved")
    func tooltipValueIsPreserved() {
        let button = IconButton(textureID: 1, tooltip: "Close") {}
        #expect(button.tooltip == "Close")
    }

    @Test("IconButton tooltip installs host overlay draw")
    func tooltipInstallsOverlayDraw() { GlobalTestLock.locked {
        TooltipOverlayRegistry.unregisterAll()
        defer { TooltipOverlayRegistry.unregisterAll() }

        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            IconButton(textureID: 7, tooltip: "Pin") {}
        )
        graph.computeLayout(width: 60, height: 40)

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        #expect((host.attachments[ButtonHost.tooltipKey] as? String) == "Pin")
        #expect(TooltipOverlayRegistry.contains(host))
    } }

    @Test("Button tooltip flips below top-edge controls")
    func tooltipFlipsBelowTopEdgeControls() { GlobalTestLock.locked {
        TooltipOverlayRegistry.unregisterAll()
        defer { TooltipOverlayRegistry.unregisterAll() }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
        defer { TextEnvironmentHolder.current = nil }

        let host = ButtonHost(role: .normal,
                              isEnabled: true,
                              tooltip: "Open Scene...",
                              isPressed: false,
                              isHovered: true,
                              label: AnyView(EmptyView()),
                              onHoverChange: { _ in },
                              onDown: {},
                              onUp: { false },
                              onKey: { _, _ in .ignored })
        let node = host._makeNode()
        node.frame = CGRect(x: 10, y: 0, width: 34, height: 34)
        host._updateNode(node)

        let list = DrawList()
        list.setViewportBounds(UIRect(x: 0, y: 0, width: 200, height: 120))
        TooltipOverlayRegistry.drawAll(into: list)

        let minY = list.vertices.map(\.posY).min() ?? -1
        #expect(minY >= 30)
    } }

    @Test("IconButton renders across style and theme combinations")
    func rendersAcrossStyleThemeCombos() { GlobalTestLock.locked {
        let cases: [(Theme, AnyView)] = [
            (
                .defaultLight,
                AnyView(
                    IconButton(textureID: 7, size: 16) {}
                        .buttonStyle(.ghost)
                        .theme(.defaultLight)
                )
            ),
            (
                .defaultDark,
                AnyView(
                    IconButton(textureID: 7, size: 16) {}
                        .buttonStyle(.secondary)
                        .theme(.defaultDark)
                )
            ),
            (
                .defaultDark,
                AnyView(
                    IconButton(textureID: 7, size: 16, role: .destructive) {}
                        .buttonStyle(.destructive)
                        .theme(.defaultDark)
                )
            ),
        ]

        for (_, view) in cases {
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: view)
            graph.computeLayout(width: 60, height: 40)

            guard let host = findButtonHost(tree.root!) else {
                Issue.record("no ButtonHost found in tree"); return
            }
            #expect(host.isHitTestable == true)
        }
    } }
}
