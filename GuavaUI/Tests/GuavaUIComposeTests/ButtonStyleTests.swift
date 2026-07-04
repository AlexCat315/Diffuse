import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7.5 ButtonStyle", .serialized)
struct ButtonStyleTests: GuavaUIComposeSerializedSuite {

    private struct StatefulFillButtonStyle: ButtonStyle, Hashable {
        let active: Bool

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label)
            }
            .frame(height: 24, minWidth: 24)
            .background(active ? Color(r: 1, g: 0, b: 0) : Color(r: 0, g: 1, b: 0))
        }
    }

    private struct StatefulStyleHarness: View {
        @State var active = true

        var body: some View {
            Button(action: { active.toggle() }) {
                Text("State")
            }
            .buttonStyle(StatefulFillButtonStyle(active: active))
        }
    }

    private func findButtonHost(_ root: Node) -> Node? {
        if root.attachments[ButtonHost.pressedKey] != nil { return root }
        for c in root.children {
            if let n = findButtonHost(c) { return n }
        }
        return nil
    }

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

    @Test("role:.destructive does not implicitly change style")
    func destructiveRoleDoesNotAutoMapStyle() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button("Delete", role: .destructive) { }
        )

        let filled = findFilled(tree.root!)
        #expect(filled?.backgroundColor == Theme.defaultDark.colors.accent)
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

    @Test("Keyboard Return activates Button action")
    func returnKeyActivatesButton() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var fired = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Go") { fired += 1 })

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        let key = registry.handlers(for: host).key
        #expect(key != nil)

        let event = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)
        #expect(key?(event, .target) == .handled)
        #expect(fired == 1)
    } }

    @Test("Keyboard repeat does not re-trigger Button action")
    func repeatKeyIgnored() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var fired = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Go") { fired += 1 })

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        let key = registry.handlers(for: host).key
        #expect(key != nil)

        let event = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: true)
        #expect(key?(event, .target) == .ignored)
        #expect(fired == 0)
    } }

    @Test("Built-in Button interaction updates chrome without recomposing")
    func builtInInteractionDoesNotRecompose() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            var fired = 0
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Button("Tap") { fired += 1 })
            graph.computeLayout(width: 120, height: 40)

            guard let host = findButtonHost(tree.root!) else {
                Issue.record("no ButtonHost found in tree"); return
            }
            let hover = registry.handlers(for: host).hover
            let pointer = registry.handlers(for: host).pointer
            #expect(hover != nil)
            #expect(pointer != nil)
            guard let hover, let pointer else { return }

            tree.flush()
            #expect(graph.recomposer.hasPending == false)

            hover(.enter)
            #expect(graph.recomposer.hasPending == false)
            scheduler.tick(deltaTime: 1)
            #expect(findFilled(tree.root!)?.backgroundColor == theme.colors.accentHover)

            tree.flush()
            let event = MouseButtonEvent(button: .left, x: 8, y: 8, clicks: 1)
            #expect(pointer(event, .down, .target) == .handled)
            #expect(graph.recomposer.hasPending == false)
            scheduler.tick(deltaTime: 1)
            #expect(findFilled(tree.root!)?.backgroundColor == theme.colors.accentPressed)

            tree.flush()
            #expect(pointer(event, .up, .target) == .handled)
            #expect(graph.recomposer.hasPending == false)
            scheduler.tick(deltaTime: 1)
            #expect(findFilled(tree.root!)?.backgroundColor == theme.colors.accentHover)
            #expect(fired == 1)
        }
    } }

    @Test("Disabled Button does not register key handler")
    func disabledButtonHasNoKeyHandler() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button("Go", isEnabled: false) { })

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        #expect(registry.handlers(for: host).key == nil)
    } }

    @Test("Hashable ButtonStyle instance changes update composition local")
    func hashableStyleValueUpdatesCompositionLocal() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: StatefulStyleHarness())

        #expect(findFilled(tree.root!)?.backgroundColor == Color(r: 1, g: 0, b: 0))

        guard let host = findButtonHost(tree.root!) else {
            Issue.record("no ButtonHost found in tree"); return
        }
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 32)
        let pointer = registry.handlers(for: host).pointer
        #expect(pointer != nil)

        let evt = MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1)
        #expect(pointer?(evt, .down, .target) == .handled)
        recomp.commitAll()
        #expect(pointer?(evt, .up, .target) == .handled)
        recomp.commitAll()

        #expect(findFilled(tree.root!)?.backgroundColor == Color(r: 0, g: 1, b: 0))
    } }
    private struct ToggleHarness: View {
        let isSelected: Bool

        var body: some View {
            Button(isSelected: isSelected, action: {}) {
                Text("Chip")
            }
            .buttonStyle(.toggle)
        }
    }

    @Test("ToggleButtonStyle pairs accent background with onAccent foreground when selected")
    func toggleStyleSelectedContrast() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        defer { InteractionRegistryHolder.current = nil }

        func filledColor(selected: Bool) -> Color? {
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: ToggleHarness(isSelected: selected))
            graph.computeLayout(width: 200, height: 60)
            return tree.root.flatMap(findFilled).flatMap(\.backgroundColor)
        }

        let theme = Theme.defaultDark
        // Selected: solid accent fill (the theme guarantees onAccent contrast
        // against it). Unselected at rest: no fill at all.
        #expect(filledColor(selected: true) == theme.colors.accent)
        #expect(filledColor(selected: false) == nil)
    } }

}
