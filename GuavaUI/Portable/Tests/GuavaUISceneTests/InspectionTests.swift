import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIDevToolsScene
import GuavaUIDevToolsProtocol

private func named(_ node: Node, _ name: String) -> Node? {
    if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
    for child in node.children { if let found = named(child, name) { return found } }
    return nil
}
private func command(_ type: String, node: Node? = nil, properties: [String: JSONValue]? = nil) -> DevToolsEnvelope {
    var p: [String: JSONValue] = [:]
    if let node { p["id"] = .string(String(node.id.rawValue)) }
    if let properties { p["properties"] = .object(properties) }
    return DevToolsEnvelope(type: "inspect." + type, id: 123, payload: p.isEmpty ? nil : .object(p))
}
private func padding(_ n: Double) -> JSONValue { .object(["top": .number(n), "right": .number(n), "bottom": .number(n), "left": .number(n)]) }

@Test @MainActor
func inspectionStylesSurviveComposeAndClearToLatestAppStyle() throws {
    let counter = SharedCounterView(), context = PlatformInputContext(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    let inspector = SceneInspector(tree: tree, renderTree: graph.renderTree)
    try context.withCurrent {
        graph.install(root: counter); graph.computeLayout(width: 640, height: 460)
        let root = try #require(tree.root)
        let container = try #require(named(root, "browser.root"))
        let title = try #require(named(root, "counter.value"))
        let id = String(container.id.rawValue)
        inspector.editor.select(id)
        let baseline = container.backgroundColor
        let beforeX = title.absoluteFrame.minX
        #expect(inspector.editor.handle(command("style.set", node: container, properties: ["padding": padding(36), "backgroundColor": .string("#ff000080")])).type == "inspect.style.set.ok")
        #expect(graph.layoutNeedsUpdate(width: 640, height: 460))
        graph.computeLayoutIfNeeded(width: 640, height: 460)
        #expect(title.absoluteFrame.minX == beforeX + 12)
        #expect(container.backgroundColor == Color(red: 255, green: 0, blue: 0, alpha: 128))
        counter.dark = true; counter.count = 8; recomposer.commitAll(); graph.computeLayoutIfNeeded(width: 640, height: 460)
        #expect(named(root, "browser.root") === container)
        #expect(container.layoutNode?.resolvedPadding.left == 36)
        #expect(container.backgroundColor?.r == 1)
        #expect(inspector.snapshot().inspection?.selectedID == id)
        _ = inspector.editor.handle(command("style.undo"))
        graph.computeLayoutIfNeeded(width: 640, height: 460)
        #expect(container.layoutNode?.resolvedPadding.left == 24)
        #expect(container.backgroundColor != baseline && container.backgroundColor?.r == Float(20)/255)
        _ = inspector.editor.handle(command("style.redo"))
        #expect(container.backgroundColor?.r == 1)
        _ = inspector.editor.handle(command("style.clear", node: container))
        #expect(container.backgroundColor?.r == Float(20)/255)
        #expect(inspector.editor.state.overrideCount == 0)
        _ = inspector.editor.handle(command("style.undo"))
        #expect(inspector.editor.state.overrideCount == 1)
        inspector.editor.reset()
        #expect(container.backgroundColor?.r == Float(20)/255)
        #expect(!inspector.editor.state.canUndo && !inspector.editor.state.canRedo)
    }
}

@Test
func paddingOverridesRestorePercentAndLogicalRTLStylesIncludingNewWrites() {
    let root = LayoutNode(), child = LayoutNode()
    root.width = 200; root.height = 100; root.addChild(child)
    child.direction = .rtl; child.width = 100; child.height = 50
    child.setPaddingPercent(5); child.setPadding(7, edge: .start)
    root.calculateLayout(availableWidth: 200, availableHeight: 100)
    #expect(child.resolvedPadding.left == 10 && child.resolvedPadding.right == 7)
    child.debugPadding = LayoutInsets(top: 21, right: 22, bottom: 23, left: 24)
    child.setPadding(13, edge: .start); child.setPaddingPercent(6)
    root.calculateLayout(availableWidth: 200, availableHeight: 100)
    #expect(child.resolvedPadding.left == 24 && child.resolvedPadding.right == 22)
    child.debugPadding = nil
    root.calculateLayout(availableWidth: 200, availableHeight: 100)
    #expect(child.resolvedPadding.left == 12 && child.resolvedPadding.right == 13)
    #expect(child.resolvedPadding.top == 12 && child.resolvedPadding.bottom == 12)
}

@Test @MainActor
func visualPickingUsesPaintOrderScrollAndClipEvenForNoninteractiveNodes() {
    let tree = NodeTree(), root = Node(), low = Node(), high = Node(), child = Node()
    tree.root = root; root.frame = CGRect(x: 0, y: 0, width: 200, height: 100); root.backgroundColor = .white
    root.addChild(high); root.addChild(low)
    for n in [low, high] { n.frame = CGRect(x: 20, y: 10, width: 60, height: 60); n.backgroundColor = .white; n.isHitTestable = false; n.allowsHitTesting = false }
    high.zIndex = 1; high.isInteractionEnabled = false
    let editor = SceneEditor(tree: tree)
    #expect(editor.pick(at: CGPoint(x: 30, y: 20)) === high)
    high.opacity = 0
    #expect(editor.pick(at: CGPoint(x: 30, y: 20)) === low)
    high.opacity = 1; high.contentOffset = CGPoint(x: 10, y: 0)
    high.addChild(child); child.frame = CGRect(x: 60, y: 0, width: 30, height: 30); child.backgroundColor = .black
    #expect(editor.pick(at: CGPoint(x: 85, y: 20)) === child)
    high.clipsToBounds = true
    #expect(editor.pick(at: CGPoint(x: 85, y: 20)) === root)
    #expect(editor.pick(at: CGPoint(x: 75, y: 20)) === child)
}

@Test @MainActor
func pickingConsumesGestureAndRecordingButNormalClicksStillWork() throws {
    let counter = SharedCounterView(), context = PlatformInputContext(), tree = NodeTree()
    let graph = ViewGraph(tree: tree, recomposer: Recomposer()), inspector = SceneInspector(tree: tree)
    let dispatcher = EventDispatcher(tree: tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
    var recorded = 0
    dispatcher.eventSink = { _ in recorded += 1 }
    dispatcher.eventInterceptor = { inspector.editor.intercept($0) }
    try context.withCurrent {
        graph.install(root: counter); graph.computeLayout(width: 640, height: 460)
        let button = try #require(tree.root.flatMap { named($0, "counter.increment") })
        let f = button.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
        _ = inspector.editor.handle(command("pick.start"))
        #expect(!dispatcher.dispatch(.mouseButtonDown(event)))
        #expect(inspector.editor.selectedNode === button && !inspector.editor.picking)
        #expect(!dispatcher.dispatch(.mouseButtonUp(event)))
        #expect(recorded == 0 && counter.count == 0 && context.pointerCapture.target == nil)
        dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
        #expect(counter.count == 1 && recorded == 2)
        _ = inspector.editor.handle(command("pick.start"))
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 41, keycode: 0, modifiers: [], isRepeat: false)))
        #expect(!inspector.editor.picking && recorded == 2)
    }
}

@Test @MainActor
func malformedOrStaleEditsAreAtomicAndSelectionOverlayPreservesBorders() {
    let root = Node(), tree = NodeTree(), editor = SceneEditor(tree: tree)
    tree.root = root; root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    root.backgroundColor = .white; root.borderColor = .black; root.borderWidth = 5
    for properties: [String: JSONValue] in [
        ["backgroundColor": .string("#ff0000"), "padding": padding(-1)],
        ["padding": padding(.infinity)], ["backgroundColor": .string("#ab")],
        ["backgroundColor": .string("#１２３４５６")], ["width": .number(20)]] {
        let response = editor.handle(command("style.set", node: root, properties: properties))
        #expect(response.type == "inspect.style.set.err" && response.id == 123)
        #expect(root.backgroundColor == .white && !editor.state.canUndo)
    }
    let other = Node()
    #expect(editor.handle(command("style.set", node: other, properties: ["backgroundColor": .string("#ffffff")])).type == "inspect.style.set.err")
    editor.select(String(root.id.rawValue)); editor.drawOverlay(into: DrawList()); editor.select(nil)
    #expect(root.borderColor == .black && root.borderWidth == 5)
}

@Test @MainActor
func partialClearAndRemovedNodesDoNotResurrectDuringUndo() {
    let root = Node(), child = Node(), tree = NodeTree()
    root.addChild(child); tree.root = root
    let editor = SceneEditor(tree: tree)
    root.foregroundColor = .black
    _ = editor.handle(command("style.set", node: root, properties: ["backgroundColor": .string("#ff0000"), "foregroundColor": .string("#00ff00")]))
    #expect(child.inheritedForegroundColor == Color(red: 0, green: 255, blue: 0))
    root.foregroundColor = .white
    _ = editor.handle(command("style.set", node: root, properties: ["foregroundColor": .null]))
    #expect(root.foregroundColor == .white && root.debugBackgroundColor != nil)
    _ = editor.handle(command("style.set", node: child, properties: ["backgroundColor": .string("#0000ff")]))
    editor.select(String(child.id.rawValue)); root.removeChild(child)
    #expect(editor.state.overrideCount == 1 && editor.state.selectedID == nil)
    #expect(child.debugBackgroundColor == nil)
    _ = editor.handle(command("style.undo")); _ = editor.handle(command("style.redo"))
    #expect(editor.state.overrideCount == 1 && !root.children.contains { $0 === child })
    _ = editor.handle(command("style.clearAll"))
    #expect(root.backgroundColor == nil && root.foregroundColor == .white)
}

@Test @MainActor
func styleHistoryAndNodeBudgetsAreBounded() {
    let root = Node(), tree = NodeTree(); tree.root = root
    let editor = SceneEditor(tree: tree)
    for i in 0..<140 {
        _ = editor.handle(command("style.set", node: root, properties: ["backgroundColor": .string(i % 2 == 0 ? "#000000" : "#ffffff")]))
    }
    var undos = 0
    while editor.state.canUndo && undos < 150 { _ = editor.handle(command("style.undo")); undos += 1 }
    #expect(undos == 128)
    editor.reset()
    for _ in 0..<256 {
        let child = Node(); root.addChild(child)
        #expect(editor.handle(command("style.set", node: child, properties: ["backgroundColor": .string("#ffffff")])).type == "inspect.style.set.ok")
    }
    let extra = Node(); root.addChild(extra)
    #expect(editor.handle(command("style.set", node: extra, properties: ["backgroundColor": .string("#ffffff")])).type == "inspect.style.set.err")
    #expect(extra.debugBackgroundColor == nil && editor.state.overrideCount == 256)
    _ = editor.handle(command("style.clearAll")); #expect(editor.state.overrideCount == 0)
}
