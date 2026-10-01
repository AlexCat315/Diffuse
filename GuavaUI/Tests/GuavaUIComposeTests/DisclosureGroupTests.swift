import EngineKernel
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Disclosure group", .serialized)
struct DisclosureGroupTests {
    private struct Harness: View {
        @State var expanded = false
        let enabled: Bool
        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 2) {
                DisclosureGroup("Advanced", isExpanded: $expanded, isEnabled: enabled) {
                    Text("Details").frame(height: 120).debugName("disclosure-details")
                }
                Text("Following").frame(height: 24).debugName("disclosure-following")
            }
        }
    }

    @Test("disclosure chrome fills its hit region and the label is left aligned")
    func headerGeometry() throws { try GlobalTestLock.locked {
        let previousText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
        defer { TextEnvironmentHolder.current = previousText }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Harness(enabled: true))
        graph.computeLayout(width: 220, height: 400)
        let header = try #require(firstFocusable(tree.root))
        let chrome = try #require(firstChrome(header))
        let label = try #require(graph.layoutSnapshot().first { $0.debugName == "disclosure-label" }?.absoluteFrame)
        #expect(header.frame.width == 220)
        #expect(chrome.frame.width == header.frame.width)
        #expect(label.minX < header.absoluteFrame.minX + 36)
        #expect(label.width >= 50)
    } }

    @Test("Return and Space toggle content and reflow the following row")
    func keyboardToggle() throws { try AnimatorScheduler.$current.withValue(AnimatorScheduler()) { try GlobalTestLock.locked {
        let previousRegistry = InteractionRegistryHolder.current
        let previousText = TextEnvironmentHolder.current
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
        defer {
            InteractionRegistryHolder.current = previousRegistry
            TextEnvironmentHolder.current = previousText
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let harness = Harness(enabled: true)
        graph.install(root: harness)
        graph.computeLayout(width: 220, height: 400)
        let initialY = try #require(graph.layoutSnapshot().first {
            $0.debugName == "disclosure-following"
        }?.absoluteFrame.minY)
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "disclosure-details" })

        for scanCode: UInt32 in [40, 44] {
            let host = try #require(firstFocusable(tree.root))
            let handler = try #require(registry.handlers(for: host).key)
            #expect(handler(KeyEvent(scancode: scanCode, keycode: 0,
                                     modifiers: [], isRepeat: false), .target) == .handled)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 220, height: 400)
            AnimatorScheduler.current.tick(deltaTime: 1)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 220, height: 400)
            let layout = graph.layoutSnapshot()
            let following = try #require(layout.first { $0.debugName == "disclosure-following" }?.absoluteFrame)
            if harness.expanded {
                let details = try #require(layout.first { $0.debugName == "disclosure-details" }?.absoluteFrame)
                #expect(details.height == 120)
                #expect(following.minY >= details.maxY)
            } else {
                #expect(!layout.contains { $0.debugName == "disclosure-details" })
                #expect(following.minY == initialY)
            }
        }
    } } }

    @Test("disabled disclosure cannot be keyboard activated")
    func disabledHeader() { GlobalTestLock.locked {
        let previous = InteractionRegistryHolder.current
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        defer { InteractionRegistryHolder.current = previous }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Harness(enabled: false))
        #expect(firstFocusable(tree.root) == nil)
    } }

    private func firstFocusable(_ node: Node?) -> Node? {
        guard let node else { return nil }
        if node.isFocusable { return node }
        return node.children.lazy.compactMap { firstFocusable($0) }.first
    }

    private func firstChrome(_ node: Node) -> Node? {
        if node.attachments[BuiltinButtonChrome.stateKey] != nil { return node }
        return node.children.lazy.compactMap { firstChrome($0) }.first
    }
}
