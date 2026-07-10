import XCTest
import EngineKernel
@testable import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell

final class WindowChromeInteractionTests: XCTestCase {
    func testCollectorIndexesChromeNodesOnceAndReadsGeometryLive() throws {
        let root = Node()
        root.frame = CGRect(x: 3, y: 4, width: 900, height: 600)
        root.contentOffset = CGPoint(x: 0, y: 2)

        let chrome = Node()
        chrome.attachments[WindowChromeAttachmentKey.configuration] = WindowChromeHitTest(
            titleBarHeight: 34,
            resizeBorderWidth: 0,
            usesExplicitDragRects: true
        )
        root.addChild(chrome)

        let drag = Node()
        drag.frame = CGRect(x: 10, y: 20, width: 100, height: 24)
        drag.attachments[WindowChromeAttachmentKey.dragRegion] = true
        chrome.addChild(drag)

        let collector = WindowChromeHitTestCollector()
        let first = try XCTUnwrap(collector.collect(root: root))
        XCTAssertEqual(collector.discoveryPassCount, 1)
        XCTAssertEqual(first.draggableRects.first?.x, 13)
        XCTAssertEqual(first.draggableRects.first?.y, 22)

        drag.frame.origin.x = 30
        root.contentOffset.y = 6
        let moved = try XCTUnwrap(collector.collect(root: root))
        XCTAssertEqual(collector.discoveryPassCount, 1)
        XCTAssertEqual(moved.draggableRects.first?.x, 33)
        XCTAssertEqual(moved.draggableRects.first?.y, 18)

        let interactive = Node()
        interactive.frame = CGRect(x: 5, y: 7, width: 20, height: 10)
        interactive.attachments[WindowChromeAttachmentKey.interactiveRegion] = true
        chrome.addChild(interactive)
        let structurallyChanged = try XCTUnwrap(collector.collect(root: root))
        XCTAssertEqual(collector.discoveryPassCount, 2)
        XCTAssertEqual(structurallyChanged.nonDraggableRects.count, 1)
    }

    func testTitleBarControlsRemainHitTestableAcrossTheWholeBar() throws {
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

        let menuState = MenuOpenState()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root:
            ImmersiveWindowTitleBar(controlStyle: .custom) {
                Row(alignment: .center, spacing: 0) {
                    menuTrigger("File", index: 0, state: menuState)
                    menuTrigger("Edit", index: 1, state: menuState)
                    menuTrigger("Window", index: 2, state: menuState)
                    menuTrigger("Tools", index: 3, state: menuState)
                    menuTrigger("Build", index: 4, state: menuState)
                    menuTrigger("Help", index: 5, state: menuState)
                }
            }
        )
        graph.computeLayout(width: 900, height: 34)

        let dispatcher = EventDispatcher(tree: graph.tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)

        let snapshots = graph.layoutSnapshot()
        let buildFrame = try XCTUnwrap(snapshots.first { $0.debugName == "menu-Build" }?.absoluteFrame)
        let helpFrame = try XCTUnwrap(snapshots.first { $0.debugName == "menu-Help" }?.absoluteFrame)
        let titleBarFrame = try XCTUnwrap(snapshots.first { $0.debugName == "app-window-title-bar" }?.absoluteFrame)

        click(dispatcher, x: Float(buildFrame.midX), y: Float(buildFrame.midY))
        XCTAssertEqual(menuState.openIndex, 4)

        click(dispatcher, x: Float(helpFrame.midX), y: Float(helpFrame.midY))
        XCTAssertEqual(menuState.openIndex, 5)

        let controlNames = [
            "window-control-minimize",
            "window-control-maximize",
            "window-control-close",
        ]
        let controlFrames = try controlNames.map { name in
            try XCTUnwrap(snapshots.first { $0.debugName == name }?.absoluteFrame)
        }
        XCTAssertEqual(controlFrames.count, 3)

        for button in controlFrames {
            let point = CGPoint(x: button.midX, y: button.midY)
            let hit = HitTester.hitTest(rootNode: graph.tree.root!, point: point)
            XCTAssertNotNil(hit)
            XCTAssertNotNil(registry.handlers(for: hit!.node).pointer)
            XCTAssertEqual(hit!.node.cursor, .pointer)
        }

        let chrome = try XCTUnwrap(graph.tree.root.flatMap(WindowChromeHitTestCollector.collect(root:)))
        XCTAssertTrue(chrome.usesExplicitDragRects)
        XCTAssertTrue(chrome.draggableRects.contains { $0.contains(x: Float(titleBarFrame.midX),
                                                                    y: Float(titleBarFrame.midY)) })
        XCTAssertTrue(chrome.nonDraggableRects.contains { $0.contains(x: Float(buildFrame.midX),
                                                                       y: Float(buildFrame.midY)) })
        XCTAssertTrue(chrome.nonDraggableRects.contains { $0.contains(x: Float(helpFrame.midX),
                                                                       y: Float(helpFrame.midY)) })
        for button in controlFrames {
            XCTAssertTrue(chrome.nonDraggableRects.contains { $0.contains(x: Float(button.midX),
                                                                           y: Float(button.midY)) })
        }
    }

    private func click(_ dispatcher: EventDispatcher, x: Float, y: Float) {
        let down = MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(down))
        dispatcher.dispatch(.mouseButtonUp(down))
    }

    private func menuTrigger(_ name: String, index: Int, state: MenuOpenState) -> some View {
        let binding = Binding<Bool>(
            get: { state.openIndex == index },
            set: { presented in
                if presented {
                    state.openIndex = index
                } else if state.openIndex == index {
                    state.openIndex = nil
                }
            }
        )
        return Popover(isPresented: binding, width: 220) {
            Text(name)
                .font(.body)
                .padding(horizontal: 10, vertical: 0)
                .frame(height: 28)
        } content: {
            Menu([
                .item(MenuItem(id: "\(name)-item", title: "\(name) Item", action: {})),
            ], width: 220)
        }
        .debugName("menu-\(name)")
    }

    private final class MenuOpenState {
        var openIndex: Int?
    }
}
