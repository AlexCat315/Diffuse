import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Coverage for icon-only `Button` — verifies the texture-source path materialises
/// a Button hierarchy with an Image child carrying the supplied texture
/// id, and that pointer-driven activation invokes the action closure.
@Suite("Button icon", .serialized)
struct ButtonIconTests: GuavaUIComposeSerializedSuite {

    /// Walk the tree looking for the ButtonHost node — it's the only
    /// node carrying the press attachment key.
    private func findButtonHost(_ root: Node) -> Node? {
        if root.attachments[ButtonHost.pressedKey] != nil { return root }
        for c in root.children {
            if let n = findButtonHost(c) { return n }
        }
        return nil
    }

    @Test("Button(icon: .texture) renders a button shell whose label is an Image")
    func texturePathBuildsButton() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(icon: .texture(7), size: 16) {}
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

    @Test("Click on icon Button invokes the action closure exactly once")
    func clickInvokesAction() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var fired = 0
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root:
            Button(icon: .texture(7), size: 16) { fired += 1 }
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

    @Test("Button(icon: .file) without a registry falls back to TextureID.none without crashing")
    func fileFallbackWithoutRegistry() { GlobalTestLock.locked {
        // Make sure no registry is installed for this test.
        ImageAssetRegistryHolder.current = nil

        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(icon: .file(path: "/this/path/does/not/exist.png"), size: 14) {}
        )
        graph.computeLayout(width: 60, height: 40)

        // Materialised without crashing; layout produced a button host.
        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        #expect(host.isHitTestable == true)
    } }

    @Test("ButtonIcon default tint defers to semantic foreground")
    func defaultTintIsSemantic() {
        let icon = ButtonIcon(.texture(1))
        #expect(icon.tint == nil)
    }

    @Test("ButtonIcon explicit tint remains supported")
    func explicitTintStillWorks() {
        let custom = Color(r: 0.25, g: 0.5, b: 0.75, a: 1)
        let icon = ButtonIcon(.texture(1), tint: custom)
        #expect(icon.tint == custom)
    }

    @Test("Icon Button tooltip value is preserved")
    func tooltipValueIsPreserved() {
        let button = Button(icon: .texture(1), tooltip: "Close") {}
        #expect(button.tooltip == "Close")
    }

    @Test("Button tooltips share delayed portals and leave with disabled or removed controls")
    @MainActor
    func tooltipPortalLifecycle() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
        context.addScopedAmbient(PortalStoreAmbient(portal))
        let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            func content(enabled: Bool) -> AnyView {
                AnyView(LayerRoot { Button(icon: .texture(7), isEnabled: enabled, tooltip: "Pin") {} })
            }
            graph.install(root: content(enabled: true)); graph.computeLayout(width: 320, height: 180)
            let host = try #require(findButtonHost(graph.tree.root!))
            #expect(host.accessibility?.help == "Pin")
            context.interactions.handlers(for: host).hover?(.enter)
            scheduler.tick(deltaTime: 0.44); #expect(portal.entries.isEmpty)
            scheduler.tick(deltaTime: 0.02); #expect(portal.entries.count == 1)
            graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 180)
            graph.install(root: content(enabled: false))
            #expect(portal.entries.isEmpty)
            scheduler.tick(deltaTime: 1); #expect(portal.entries.isEmpty)
            graph.install(root: content(enabled: true)); graph.computeLayout(width: 320, height: 180)
            let next = try #require(findButtonHost(graph.tree.root!))
            context.interactions.handlers(for: next).hover?(.enter); scheduler.tick(deltaTime: 0.46)
            #expect(portal.entries.count == 1)
            graph.install(root: EmptyView()); #expect(portal.entries.isEmpty)
        } }
    } }

    @Test("Keyboard button tooltips fit the window, preserve focus and dismiss with Escape")
    @MainActor
    func tooltipKeyboardAndPlacement() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
        context.addScopedAmbient(PortalStoreAmbient(portal))
        let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            var activations = 0
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                Column { Spacer(); Button(icon: .texture(7), tooltip: "Open Scene…") { activations += 1 } }
                    .frame(width: 320, height: 180)
            }); graph.computeLayout(width: 320, height: 180)
            let host = try #require(findButtonHost(graph.tree.root!))
            context.focusChain.focus(host, visible: true); scheduler.tick(deltaTime: 0.46)
            #expect(portal.entries.count == 1)
            graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 180)
            graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 180)
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let slot = try #require(all(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.layoutRole] as? String == "portal-entry" })
            #expect(slot.absoluteFrame.minY >= 6 && slot.absoluteFrame.maxY <= host.absoluteFrame.minY)
            #expect(slot.absoluteFrame.minX >= 6 && slot.absoluteFrame.maxX <= 314)
            #expect(slot.absoluteFrame.width > 60 && slot.absoluteFrame.width < 200)
            func elements(_ entries: [AccessibilityElement]) -> [AccessibilityElement] { entries + entries.flatMap { elements($0.children) } }
            let accessible = elements(AccessibilityTree.snapshot(root: graph.tree.root!))
            #expect(accessible.contains { $0.semantics.role == .staticText && $0.semantics.label == "Open Scene…" })
            let handler = try #require(context.interactions.handlers(for: host).key)
            #expect(handler(KeyEvent(scancode: Scancode.escape, keycode: 0, modifiers: [], isRepeat: false), .target) == .handled)
            #expect(portal.entries.isEmpty && context.focusChain.focused === host && activations == 0)
            scheduler.tick(deltaTime: 1); #expect(portal.entries.isEmpty)
            context.focusChain.clear(); context.focusChain.focus(host, visible: true); scheduler.tick(deltaTime: 0.46)
            #expect(portal.entries.count == 1)
            _ = handler(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(activations == 1 && portal.entries.isEmpty)
            graph.install(root: EmptyView())
        } }
    } }

    @Test("Icon Button renders across style and theme combinations")
    func rendersAcrossStyleThemeCombos() { GlobalTestLock.locked {
        let cases: [(Theme, AnyView)] = [
            (
                .defaultLight,
                AnyView(
                    Button(icon: .texture(7), size: 16) {}
                        .buttonStyle(.ghost)
                        .theme(.defaultLight)
                )
            ),
            (
                .defaultDark,
                AnyView(
                    Button(icon: .texture(7), size: 16) {}
                        .buttonStyle(.secondary)
                        .theme(.defaultDark)
                )
            ),
            (
                .defaultDark,
                AnyView(
                    Button(icon: .texture(7), size: 16, role: .destructive) {}
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
