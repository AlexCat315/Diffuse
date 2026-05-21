import Testing
import CoreGraphics
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

private struct _PopoverProbe: _PrimitiveView {
    let id: String
    let width: Float
    let height: Float

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["probeID"] = id
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = width
        layout.height = height
    }
}

@Suite("Popover")
struct PopoverTests {
    private final class ActionBox {
        var fired = 0
    }

    struct Harness: View {
        @State var isPresented: Bool = false

        var body: some View {
            Column(alignment: .leading, spacing: 8) {
                Popover(isPresented: $isPresented,
                        width: 120) {
                    _PopoverProbe(id: "trigger", width: 80, height: 20)
                } content: {
                    _PopoverProbe(id: "menu", width: 120, height: 60)
                }

                _PopoverProbe(id: "sibling", width: 80, height: 20)
            }
        }
    }

    @Test("Opening Popover does not move following siblings")
    func openingPopoverDoesNotAffectSiblingLayout() {
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let harness = Harness()

        graph.install(root: harness)
        graph.computeLayout(width: 240, height: 200)

        let initialSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(initialSiblingY != nil)

        harness.$isPresented.wrappedValue = true
        recomposer.commitAll()
        graph.computeLayout(width: 240, height: 200)

        let expandedSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(expandedSiblingY == initialSiblingY)
    }

    private struct MenuHarness: View {
        let box: ActionBox
        @State var isPresented: Bool = false

        var body: some View {
            LayerRoot {
                Popover(isPresented: $isPresented,
                        width: 140) {
                    _PopoverProbe(id: "trigger", width: 80, height: 24)
                } content: {
                    Menu([
                        .item(MenuItem(id: "new-scene", title: "New Scene") {
                            box.fired += 1
                        })
                    ], width: 140)
                }
            } portals: {
                PortalHost()
            }
        }
    }

    @Test("Popover menu item receives pointer activation through portal layer")
    func popoverMenuItemReceivesPointerActivation() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus
        defer {
            InteractionRegistryHolder.current = nil
            PointerCaptureHolder.current = nil
            FocusChainHolder.current = nil
        }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let box = ActionBox()
        graph.install(root: MenuHarness(box: box))
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        click(dispatcher, x: 10, y: 10)
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)

        guard let menuButton = buttonHosts(in: tree.root)
            .filter({ $0.origin.y > 20 })
            .sorted(by: { $0.origin.y < $1.origin.y })
            .first
        else {
            Issue.record("menu item button was not materialized")
            return
        }

        click(dispatcher,
              x: Float(menuButton.origin.x + menuButton.node.frame.width * 0.5),
              y: Float(menuButton.origin.y + menuButton.node.frame.height * 0.5))

        #expect(box.fired == 1)
    } }

    private func click(_ dispatcher: EventDispatcher, x: Float, y: Float) {
        let event = MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        dispatcher.dispatch(.mouseButtonUp(event))
    }

    private func buttonHosts(in node: Node?) -> [(node: Node, origin: CGPoint)] {
        var out: [(node: Node, origin: CGPoint)] = []
        collectButtonHosts(node, parentOrigin: .zero, into: &out)
        return out
    }

    private func collectButtonHosts(_ node: Node?,
                                    parentOrigin: CGPoint,
                                    into out: inout [(node: Node, origin: CGPoint)]) {
        guard let node else { return }
        let origin = CGPoint(x: parentOrigin.x + node.frame.origin.x,
                             y: parentOrigin.y + node.frame.origin.y)
        if node.attachments[ButtonHost.pressedKey] != nil {
            out.append((node, origin))
        }

        let childOrigin = CGPoint(x: origin.x - node.contentOffset.x,
                                  y: origin.y - node.contentOffset.y)
        for child in node.children {
            collectButtonHosts(child, parentOrigin: childOrigin, into: &out)
        }
    }

    private func findProbe(id: String, in node: Node?) -> Node? {
        guard let node else { return nil }
        if node.attachments["probeID"] as? String == id {
            return node
        }
        for child in node.children {
            if let match = findProbe(id: id, in: child) {
                return match
            }
        }
        return nil
    }
}
