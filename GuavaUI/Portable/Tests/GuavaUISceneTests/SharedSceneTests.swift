import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIDevToolsScene
import GuavaUIDevToolsProtocol

private func find(_ node: Node, _ name: String) -> Node? {
    if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
    for child in node.children { if let found = find(child, name) { return found } }
    return nil
}

@Test @MainActor
func sharedComposeUsesYogaAndRetainsNodesAcrossStateAndResize() throws {
    let counter = SharedCounterView()
    let context = PlatformInputContext()
    let tree = NodeTree()
    let recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    let inspector = SceneInspector(tree: tree, invalidationLog: context.invalidationLog, renderTree: graph.renderTree)
    try context.withCurrent {
        graph.install(root: counter)
        graph.computeLayout(width: 640, height: 460)
        let root = try #require(tree.root)
        let increment = try #require(find(root, "counter.increment"))
        let reset = try #require(find(root, "counter.reset"))
        let initialWidth = increment.frame.width
        #expect(initialWidth > 200)
        #expect(abs(increment.frame.width - reset.frame.width) < 0.1)
        #expect(abs(reset.absoluteFrame.minX - increment.absoluteFrame.maxX - 12) < 0.1)
        // Writes outside the current-window context still report to its log.
        counter.count = 7
        #expect(recomposer.hasPending)
        recomposer.commitAll()
        graph.computeLayout(width: 400, height: 460)
        #expect(find(root, "counter.increment") === increment)
        #expect(increment.frame.width < initialWidth)
        #expect((find(root, "counter.value")?.attachments[SharedDemoText.attachment] as? DemoText)?.text == "7")
        let snapshot = inspector.snapshot()
        #expect(snapshot.inputInventory?.nodeCount == snapshot.renderInventory?.objectCount)
        #expect(snapshot.inputInventory!.nodeCount > 5)
        #expect(snapshot.invalidations!.contains { $0.source.hasPrefix("stateWrite(") })
        let list = DrawList()
        NodeRenderer().render(root: root, into: list)
        #expect(!list.vertices.isEmpty)
        #expect(list.vertices.allSatisfy { $0.posX.isFinite && $0.posY.isFinite })
    }
    counter.dark = true
    #expect(context.invalidationLog.snapshot().contains { if case .stateWrite = $0.source { return true }; return false })
}

@Test @MainActor
func sharedInputUsesCaptureFocusAndReleaseSemantics() throws {
    let counter = SharedCounterView()
    let context = PlatformInputContext()
    let tree = NodeTree()
    let graph = ViewGraph(tree: tree, recomposer: Recomposer())
    let dispatcher = EventDispatcher(tree: tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
    try context.withCurrent {
        graph.install(root: counter); graph.computeLayout(width: 640, height: 460)
        let button = try #require(tree.root.flatMap { find($0, "counter.increment") })
        let point = button.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        #expect(counter.count == 0)
        #expect(context.pointerCapture.target === button)
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: -1, y: -1, clicks: 1)))
        #expect(counter.count == 0)
        #expect(context.pointerCapture.target == nil)
        dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
        #expect(counter.count == 1)
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)))
        #expect(counter.count == 2)
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 43, keycode: 0, modifiers: [], isRepeat: false)))
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 44, keycode: 0, modifiers: [], isRepeat: false)))
        #expect(counter.count == 0)
        #expect(!counter.restore(["count": "-1", "dark": "true"]))
        #expect(counter.count == 0 && !counter.dark)
    }
}

@Test
func protocolValidationDiffAndBoundedRecordingRoundTrip() throws {
    let session = DevToolsSession()
    #expect(session.validate(DevToolsEnvelope(type: "state.restore", id: 42, payload: .object(["count": .number(1)])))?.id == 42)
    #expect(session.validate(DevToolsEnvelope(type: "mirror.input"))?.type == "mirror.input.err")
    #expect(DevToolsSession.ok(DevToolsEnvelope(type: "timing.subscribe")) == nil)
    session.set(.tree, enabled: true); session.reset()
    #expect(session.subscriptions.isEmpty)
    let diff = StateDifference(before: ["count":"1", "old":"x"], after: ["count":"2", "new":"y"])
    #expect(diff.changed["count"]?.before == "1" && diff.changed["count"]?.after == "2")
    #expect(diff.removed == ["old":"x"] && diff.added == ["new":"y"])
    let recorder = InputRecorder()
    recorder.start(state: ["count":"0", "dark":"false"], focusTarget: "counter.increment")
    recorder.record(.textInput("中文🙂"))
    for _ in 0..<InputRecorder.limit { recorder.record(.keyDown(KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false))) }
    let recording = try #require(recorder.stop())
    #expect(recording.events.count == InputRecorder.limit && recording.truncated)
    #expect(recording.isValid)
    let decoded = try JSONDecoder().decode(InputRecording.self, from: JSONEncoder().encode(recording))
    if case .textInput(let text) = decoded.events[0].event { #expect(text == "中文🙂") }
    else { Issue.record("Unicode input did not survive Codable round trip") }
    var invalid = recording
    invalid.events[0].milliseconds = -1
    #expect(!invalid.isValid)
    #expect(session.validate(DevToolsEnvelope(type:"input.replay", payload:DevToolsCodec.json(invalid)))?.type == "input.replay.err")
}
