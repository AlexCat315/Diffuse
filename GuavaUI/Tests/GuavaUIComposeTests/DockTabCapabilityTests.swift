import Foundation
import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Phase D9 — DockTab capability bits: `isClosable`, `icon`, right-click
/// context menu forwarding, and Codable backward compatibility.
@Suite("Phase D9 / DockTab capabilities", .serialized)
struct DockTabCapabilityTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    /// Walk the tree collecting all close-button hosts (marked via the
    /// sentinel attachment).
    private func findCloseButtons(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] != nil {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    private func findTabItems(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == .pointer,
               n.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] == nil {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    // MARK: - isClosable

    @Test("Closable tab renders a close button; non-closable hides it")
    func closeButtonRespectsIsClosable() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let openTab    = DockTab(userKey: "a", title: "A", isClosable: true)
        let pinnedTab  = DockTab(userKey: "b", title: "B", isClosable: false)
        let controller = DockController(root: .tabs([openTab, pinnedTab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let buttons = findCloseButtons(tree.root!)
        #expect(buttons.count == 1)
    } }

    @Test("Clicking the close button applies .closeTab on the controller")
    func closeButtonAppliesCloseTab() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root: .tabs([a, b]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let buttons = findCloseButtons(tree.root!)
        #expect(buttons.count == 2)
        let firstClose = buttons[0]

        let handler = registry.handlers(for: firstClose).pointer!
        _ = handler(MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1), .down, .target)
        _ = handler(MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1), .up, .target)

        // One of the original tabs is gone.
        if case .tabs(_, let leftover, _) = controller.root {
            #expect(leftover.count == 1)
        } else {
            Issue.record("root is no longer a tabs leaf")
        }
    } }

    // MARK: - Right-click context menu forwarding

    @Test("Right-click on a tab fires controller.onTabContextMenu without starting a drag")
    func rightClickInvokesContextMenuCallback() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))

        var captured: (DockTabID, DockNodeID, Float, Float)?
        controller.onTabContextMenu = { id, leaf, x, y in
            captured = (id, leaf, x, y)
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        #expect(items.count == 1)
        let tabNode = items[0]
        let pointer = registry.handlers(for: tabNode).pointer!

        _ = pointer(MouseButtonEvent(button: .right, x: 42, y: 7, clicks: 1), .down, .target)

        #expect(captured?.0 == tab.id)
        #expect(captured?.2 == 42)
        #expect(captured?.3 == 7)
        // Right-click never starts a drag and never acquires capture.
        #expect(controller.dragSession.isActive == false)
        #expect(PointerCaptureHolder.current?.target == nil)
    } }

    // MARK: - Codable backward compat

    @Test("Old DockTab snapshot decodes with default capability values")
    func oldSnapshotDecodesWithDefaults() throws {
        // A tab JSON shape from before D9 — only the three original fields.
        let legacyJSON = #"""
        {
            "id": { "raw": "00000000-0000-0000-0000-000000000001" },
            "userKey": "legacy",
            "title": "Legacy"
        }
        """#

        // The tab is stored under its UUID; build the encoded id payload by
        // round-tripping through the actual encoder so the key shape matches.
        let liveTab = DockTab(userKey: "x", title: "X")
        let liveData = try JSONEncoder().encode(liveTab)
        let liveDict = try #require(try JSONSerialization.jsonObject(with: liveData) as? [String: Any])
        var minimal: [String: Any] = [:]
        minimal["id"] = liveDict["id"]
        minimal["userKey"] = "legacy"
        minimal["title"] = "Legacy"

        let payload = try JSONSerialization.data(withJSONObject: minimal)
        let decoded = try JSONDecoder().decode(DockTab.self, from: payload)
        #expect(decoded.userKey == "legacy")
        #expect(decoded.title == "Legacy")
        // Defaults must apply when the keys are missing.
        #expect(decoded.isClosable == true)
        #expect(decoded.icon == nil)
        _ = legacyJSON  // documentation-only reference
    }
}
