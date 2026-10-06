import Foundation
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIDevToolsScene
import GuavaUICore
import GuavaUIDevToolsProtocol

private struct Label: Codable {
    var text: String
    var x: Float
    var y: Float
    var size: Float
    var color: String
}

private struct Batch: Codable {
    var offset: UInt32
    var count: UInt32
    var clip: [Float]?
}

private struct Frame: Codable {
    var count: Int
    var dark: Bool
    var note: String
    var focused: String?
    var width: Float
    var height: Float
    var vertices: Int
    var indices: Int
    var batches: [Batch]
    var labels: [Label]
    var tree: TreeSnapshotPayload
}

/// Buffers have explicit lifetimes across the Swift/JavaScript boundary.
private final class ExportBuffer {
    private(set) var pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 4)
    private(set) var count = 0
    func replace(_ bytes: UnsafeRawBufferPointer) {
        let next = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes.count), alignment: 4)
        if let source = bytes.baseAddress, !bytes.isEmpty {
            next.copyMemory(from: source, byteCount: bytes.count)
        }
        pointer.deallocate()
        pointer = next
        count = bytes.count
    }
    func encode<T: Encodable>(_ value: T) {
        // All protocol values produced here are finite and Codable.
        let data = try! JSONEncoder().encode(value)
        data.withUnsafeBytes { replace($0) }
    }
    deinit { pointer.deallocate() }
}

private final class BrowserPrototype {
    let counter = SharedCounterView()
    var count: Int { counter.count }
    var dark: Bool { counter.dark }
    let tree = NodeTree()
    let context = PlatformInputContext()
    let recomposer = Recomposer()
    lazy var graph = ViewGraph(tree: tree, recomposer: recomposer)
    lazy var dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                                         capture: context.pointerCapture, focusChain: context.focusChain)
    lazy var inspector = SceneInspector(tree: tree, invalidationLog: context.invalidationLog, renderTree: graph.renderTree)
    let drawList = DrawList()
    let vertexBuffer = ExportBuffer()
    let indexBuffer = ExportBuffer()
    let snapshotBuffer = ExportBuffer()
    let responseBuffer = ExportBuffer()
    let shaderBuffer = ExportBuffer()
    var frame: Frame?
    var selected: String?
    let session = DevToolsSession()
    let recorder = InputRecorder()
    var frameNumber: UInt64 = 0
    var renderMilliseconds: Double = 0
    var layoutMilliseconds: Double = 0

    init() {
        dispatcher.eventSink = { [weak self] event in self?.recorder.record(event) }
        context.withCurrent { graph.install(root: counter) }
        UIShader.wgsl.utf8.withContiguousStorageIfAvailable { bytes in
            shaderBuffer.replace(UnsafeRawBufferPointer(bytes))
        }
    }

    func render(width rawWidth: Float, height rawHeight: Float) {
        let startedAt = Date().timeIntervalSince1970
        let width = rawWidth.isFinite ? max(280, min(4096, rawWidth)) : 640
        let height = rawHeight.isFinite ? max(360, min(4096, rawHeight)) : 460
        var labels = [Label]()
        context.withCurrent {
            recomposer.commitAll()
            graph.computeLayoutIfNeeded(width: width, height: height)
            layoutMilliseconds = max(0, (Date().timeIntervalSince1970 - startedAt) * 1000)
            drawList.reset()
            if let root = tree.root { NodeRenderer().render(root: root, into: drawList) }
            func walk(_ node: Node) {
                if let text = node.attachments[SharedDemoText.attachment] as? DemoText {
                    let f = node.absoluteFrame
                    let c = text.color
                    let preedit = node.attachments["preedit"] as? String ?? ""
                    let string = node.attachments[LayoutDebugAttachmentKey.debugName] as? String == "counter.note" && !preedit.isEmpty ? counter.note + preedit : text.text
                    labels.append(Label(text: string, x: Float(f.minX) + text.inset,
                                        y: Float(f.minY) + (Float(f.height) + text.size) / 2 - 3,
                                        size: text.size, color: "rgba(\(Int(c.r * 255)),\(Int(c.g * 255)),\(Int(c.b * 255)),\(c.a))"))
                }
                for child in node.children { walk(child) }
            }
            if let root = tree.root { walk(root) }
            tree.flush()
        }
        frame = Frame(count: count, dark: dark, note: counter.note,
                      focused: context.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String, width: width, height: height,
                      vertices: drawList.vertices.count, indices: drawList.indices.count,
                      batches: drawList.batches.map { batch in
                          Batch(offset: batch.indexOffset, count: batch.indexCount,
                                clip: batch.scissor.map { [$0.x, $0.y, $0.width, $0.height] })
                      }, labels: labels, tree: inspector.snapshot())
        drawList.vertices.withUnsafeBytes { vertexBuffer.replace($0) }
        drawList.indices.withUnsafeBytes { indexBuffer.replace($0) }
        snapshotBuffer.encode(frame!)
        frameNumber &+= 1
        renderMilliseconds = max(0, (Date().timeIntervalSince1970 - startedAt) * 1000) - layoutMilliseconds
    }

    func pointer(kind: Int32, x: Float, y: Float) {
        guard x.isFinite, y.isFinite else { return }
        context.withCurrent {
            switch kind {
            case 0: dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: x, y: y, deltaX: 0, deltaY: 0)))
            case 1: dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)))
            case 2: dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)))
            case 3:
                dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)))
                dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)))
            default: break
            }
        }
    }

    func key(_ code: UInt32, modifiers: UInt16, down: Bool, repeated: Bool) {
        context.withCurrent {
            let event = KeyEvent(scancode: code, keycode: 0, modifiers: KeyModifiers(rawValue: modifiers), isRepeat: repeated)
            dispatcher.dispatch(down ? .keyDown(event) : .keyUp(event))
        }
    }

    func text(_ string: String, editing: Bool) {
        guard string.utf8.count <= 32768 else { return }
        context.withCurrent {
            if editing { dispatcher.dispatch(.textEditing(TextEditingEvent(text: string, start: 0, length: 0))) }
            else { dispatcher.dispatch(.textInput(string)) }
        }
    }

    func select(_ id: String?) {
        if let selected, let node = inspector.find(id: selected) { node.borderColor = nil; node.borderWidth = 0 }
        selected = id
        if let id, let node = inspector.find(id: id) { node.borderColor = Color(red: 250, green: 180, blue: 40); node.borderWidth = 3 }
    }

    private func json<T: Encodable>(_ value: T) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func hello() {
        responseBuffer.encode(DevToolsEnvelope(type: "hello", payload: json(HelloPayload(
            host: HelloHostInfo(pid: 0, appTitle: "GuavaUI Wasm prototype", platform: "WebAssembly"),
            capabilities: ["tree", "select", "timing", "state", "recording"]))))
    }

    func dispatch(_ bytes: UnsafeRawBufferPointer) {
        guard let request = try? JSONDecoder().decode(DevToolsEnvelope.self, from: Data(bytes)) else {
            responseBuffer.encode(DevToolsEnvelope(type: "request.err", payload: json(ErrorPayload(code: "bad_request", message: "Invalid JSON"))))
            return
        }
        if let error = session.validate(request) { responseBuffer.encode(error); return }
        var response = DevToolsEnvelope(type: request.type + ".ok", id: request.id)
        func fail(_ message: String) { response.type = request.type + ".err"; response.payload = json(ErrorPayload(code: "bad_request", message: message)) }
        switch request.type {
        case "hello.ack": break
        case "tree.subscribe":
            session.set(.tree, enabled: true)
            response.type = "tree.snapshot"; response.payload = json(frame!.tree)
        case "tree.unsubscribe": session.set(.tree, enabled: false)
        case "timing.subscribe": session.set(.timing, enabled: true)
        case "timing.unsubscribe": session.set(.timing, enabled: false)
        case "select.node":
            if let id = request.payload?.objectValue?["id"]?.stringValue,
               inspector.find(id: id) != nil { select(id) }
            else { fail("Unknown node") }
        case "select.clear": select(nil)
        case "state.checkpoint": response.payload = json(counter.checkpoint)
        case "state.restore":
            if let object = request.payload?.objectValue, object.values.allSatisfy({ $0.stringValue != nil }),
               counter.restore(object.compactMapValues { $0.stringValue }) {} else {
                fail("State requires count (0…999999) and dark (true/false), as strings")
            }
        case "state.diff": response.payload = json(StateDifference(before: DevToolsSession.state(request.payload)!, after: counter.checkpoint))
        case "input.record.start":
            if recorder.isRecording { fail("Already recording") } else {
                recorder.start(state: counter.checkpoint, focusTarget: context.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String)
            }
        case "input.record.stop":
            if let recording = recorder.stop() { response.payload = json(recording) } else { fail("No recording") }
        case "input.replay":
            if recorder.isRecording { fail("Stop recording before replaying") }
            else if let recording = DevToolsCodec.decode(InputRecording.self, request.payload), counter.restore(recording.initialState) {
                context.pointerCapture.release()
                context.withCurrent {
                    recomposer.commitAll()
                    graph.computeLayoutIfNeeded(width: frame!.width, height: frame!.height)
                    func find(_ node: Node, name: String) -> Node? {
                        if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
                        for child in node.children { if let found = find(child, name: name) { return found } }
                        return nil
                    }
                    context.focusChain.focus(recording.focusTarget.flatMap { name in tree.root.flatMap { find($0, name: name) } })
                    for input in recording.events {
                        dispatcher.dispatch(input.event)
                        recomposer.commitAll()
                        graph.computeLayoutIfNeeded(width: frame!.width, height: frame!.height)
                    }
                }
            } else { fail("Invalid recording state") }
        case "bye": session.reset(); _ = recorder.stop(); select(nil)
        default: fail("Unsupported browser prototype message")
        }
        if response.type.hasSuffix(".ok"), response.payload == nil, request.id == nil {
            responseBuffer.encode(JSONValue.null)
        } else { responseBuffer.encode(response) }
    }

    func events() {
        var messages = [DevToolsEnvelope]()
        if session.subscriptions.contains(.tree), let frame {
            messages.append(DevToolsEnvelope(type: "tree.delta", payload: json(frame.tree)))
        }
        if session.subscriptions.contains(.timing), let frame {
            messages.append(DevToolsEnvelope(type: "timing.frame", payload: json(TimingFramePayload(
                frame: frameNumber, layoutMs: layoutMilliseconds, drawMs: renderMilliseconds, presentMs: 0, totalMs: layoutMilliseconds + renderMilliseconds,
                nodeCount: frame.tree.inputInventory?.nodeCount ?? 0, batchCount: frame.batches.count))))
        }
        responseBuffer.encode(messages)
    }
}

// This reactor is single-threaded. JavaScript invokes these exports on the same
// browser thread; pointers remain valid until the next corresponding mutation.
nonisolated(unsafe) private let app = BrowserPrototype()

@_cdecl("guava_render") public func guavaRender(_ width: Float, _ height: Float) { app.render(width: width, height: height) }
@_cdecl("guava_pointer") public func guavaPointer(_ kind: Int32, _ x: Float, _ y: Float) { app.pointer(kind: kind, x: x, y: y) }
@_cdecl("guava_key") public func guavaKey(_ code: UInt32, _ modifiers: UInt32, _ down: Int32, _ repeated: Int32) { app.key(code, modifiers: UInt16(truncatingIfNeeded: modifiers), down: down != 0, repeated: repeated != 0) }
@_cdecl("guava_text") public func guavaText(_ pointer: UnsafeRawPointer, _ count: Int32, _ editing: Int32) {
    guard count >= 0, count <= 32768, let string = String(data: Data(bytes: pointer, count: Int(count)), encoding: .utf8) else { return }
    app.text(string, editing: editing != 0)
}
@_cdecl("guava_vertices") public func guavaVertices() -> UnsafeMutableRawPointer { app.vertexBuffer.pointer }
@_cdecl("guava_vertex_bytes") public func guavaVertexBytes() -> Int32 { Int32(app.vertexBuffer.count) }
@_cdecl("guava_indices") public func guavaIndices() -> UnsafeMutableRawPointer { app.indexBuffer.pointer }
@_cdecl("guava_index_count") public func guavaIndexCount() -> Int32 { Int32(app.indexBuffer.count / 4) }
@_cdecl("guava_snapshot") public func guavaSnapshot() -> UnsafeMutableRawPointer { app.snapshotBuffer.pointer }
@_cdecl("guava_snapshot_size") public func guavaSnapshotSize() -> Int32 { Int32(app.snapshotBuffer.count) }
@_cdecl("guava_response") public func guavaResponse() -> UnsafeMutableRawPointer { app.responseBuffer.pointer }
@_cdecl("guava_response_size") public func guavaResponseSize() -> Int32 { Int32(app.responseBuffer.count) }
@_cdecl("guava_shader") public func guavaShader() -> UnsafeMutableRawPointer { app.shaderBuffer.pointer }
@_cdecl("guava_shader_size") public func guavaShaderSize() -> Int32 { Int32(app.shaderBuffer.count) }
@_cdecl("guava_hello") public func guavaHello() { app.hello() }
@_cdecl("guava_events") public func guavaEvents() { app.events() }
@_cdecl("guava_alloc") public func guavaAlloc(_ count: Int32) -> UnsafeMutableRawPointer? {
    guard count > 0, count <= 1024 * 1024 else { return nil }
    return .allocate(byteCount: Int(count), alignment: 4)
}
@_cdecl("guava_free") public func guavaFree(_ pointer: UnsafeMutableRawPointer) { pointer.deallocate() }
@_cdecl("guava_dispatch") public func guavaDispatch(_ pointer: UnsafeRawPointer, _ count: Int32) {
    guard count >= 0, count <= 1024 * 1024 else { return }
    app.dispatch(UnsafeRawBufferPointer(start: pointer, count: Int(count)))
}

@main struct BrowserEntry { static func main() {} }
