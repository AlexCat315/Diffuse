import Foundation
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
    @State var count = 0
    @State var dark = false
    let drawList = DrawList()
    let vertexBuffer = ExportBuffer()
    let indexBuffer = ExportBuffer()
    let snapshotBuffer = ExportBuffer()
    let responseBuffer = ExportBuffer()
    let shaderBuffer = ExportBuffer()
    var frame: Frame?
    var hovered: String?
    var selected: String?
    var buttons: [(String, UIRect)] = []
    var subscriptions = Set<String>()
    var pendingInvalidations = [InvalidationRecord]()
    var frameNumber: UInt64 = 0
    var renderMilliseconds: Double = 0

    init() {
        _count._setOnChange { [weak self] in self?.invalidate("counter") }
        _dark._setOnChange { [weak self] in self?.invalidate("theme") }
        UIShader.wgsl.utf8.withContiguousStorageIfAvailable { bytes in
            shaderBuffer.replace(UnsafeRawBufferPointer(bytes))
        }
    }

    func invalidate(_ scope: String) {
        pendingInvalidations.append(InvalidationRecord(target: "1", source: "stateWrite(\(scope))",
                                                       phase: "render", timestamp: Date().timeIntervalSince1970))
        pendingInvalidations = Array(pendingInvalidations.suffix(32))
    }

    func render(width rawWidth: Float, height rawHeight: Float) {
        let startedAt = Date().timeIntervalSince1970
        let width = rawWidth.isFinite ? max(280, min(4096, rawWidth)) : 640
        let height = rawHeight.isFinite ? max(360, min(4096, rawHeight)) : 460
        drawList.reset()
        drawList.setViewportBounds(UIRect(x: 0, y: 0, width: width, height: height))
        buttons.removeAll(keepingCapacity: true)
        var labels = [Label]()
        var nodes = [NodeSummary]()
        let text = dark ? "#f1f5f9" : "#162338"
        let foreground = dark ? Color(red: 241, green: 245, blue: 249) : Color(red: 22, green: 35, blue: 56)
        let background = dark ? Color(red: 20, green: 29, blue: 45) : Color(red: 244, green: 247, blue: 252)
        drawList.addRoundedRect(UIRect(x: 1, y: 1, width: width - 2, height: height - 2), radius: 16, color: background)

        func label(_ string: String, x: Float, y: Float, size: Float = 16) {
            labels.append(Label(text: string, x: x, y: y, size: size, color: text))
        }
        func node(_ id: String, _ tag: String, _ rect: UIRect, focusable: Bool = false) -> NodeSummary {
            NodeSummary(id: id, viewTag: tag, debugName: "browser.\(tag.lowercased())",
                        frame: NodeFrame(x: Double(rect.x), y: Double(rect.y), w: Double(rect.width), h: Double(rect.height)),
                        flags: NodeFlags(hitTestable: focusable, focusable: focusable, clipsToBounds: false,
                                         hasBackground: true, hasBorder: selected == id),
                        children: [], elementID: id)
        }
        label("GuavaUI · Swift in your browser", x: 24, y: 40, size: 22)
        label("Shared State, Binding and DrawList", x: 24, y: 72, size: 14)
        let card = UIRect(x: 24, y: 94, width: width - 48, height: 126)
        drawList.addRoundedRect(card, radius: 12, color: foreground.multipliedAlpha(0.06))
        label("Counter", x: 44, y: 126, size: 14)
        label(String(count), x: 44, y: 178, size: 42)
        let gap: Float = 12
        let buttonWidth = (width - 48 - gap) / 2
        func button(_ id: String, _ title: String, _ rect: UIRect) {
            let color = hovered == id ? Color(red: 29, green: 110, blue: 210) : Color(red: 40, green: 130, blue: 235)
            drawList.addRoundedRect(rect, radius: 9, color: color)
            if selected == id { drawList.addRoundedRectStroke(rect, radius: 9, width: 3, color: Color(red: 250, green: 180, blue: 40)) }
            labels.append(Label(text: title, x: rect.x + 16, y: rect.y + 31, size: 16, color: "#ffffff"))
            buttons.append((id, rect)); nodes.append(node(id, title, rect, focusable: true))
        }
        button("2", "+ Increment", UIRect(x: 24, y: 238, width: buttonWidth, height: 48))
        button("3", "Reset", UIRect(x: 24 + buttonWidth + gap, y: 238, width: buttonWidth, height: 48))
        button("4", dark ? "Light theme" : "Dark theme", UIRect(x: 24, y: 302, width: width - 48, height: 48))
        nodes.insert(node("5", "Counter", card), at: 0)
        let root = NodeSummary(id: "1", viewTag: "BrowserPrototype", debugName: "browser.root",
                               frame: NodeFrame(x: 0, y: 0, w: Double(width), h: Double(height)),
                               flags: NodeFlags(hitTestable: false, focusable: false, clipsToBounds: true,
                                                hasBackground: true, hasBorder: false), children: nodes, elementID: "1")
        let tree = TreeSnapshotPayload(root: root, invalidations: pendingInvalidations,
                                       renderInventory: RenderInventoryPayload(objectCount: nodes.count + 1, layerRoots: []),
                                       inputInventory: InputInventoryPayload(nodeCount: nodes.count + 1,
                                                                            focusables: ["2", "3", "4"], hitTestables: ["2", "3", "4"]))
        frame = Frame(count: count, dark: dark, width: width, height: height,
                      vertices: drawList.vertices.count, indices: drawList.indices.count,
                      batches: drawList.batches.map { batch in
                          Batch(offset: batch.indexOffset, count: batch.indexCount,
                                clip: batch.scissor.map { [$0.x, $0.y, $0.width, $0.height] })
                      }, labels: labels, tree: tree)
        drawList.vertices.withUnsafeBytes { vertexBuffer.replace($0) }
        drawList.indices.withUnsafeBytes { indexBuffer.replace($0) }
        snapshotBuffer.encode(frame!)
        frameNumber &+= 1
        renderMilliseconds = max(0, (Date().timeIntervalSince1970 - startedAt) * 1000)
    }

    func pointer(kind: Int32, x: Float, y: Float) {
        let hit = buttons.first { _, r in x >= r.minX && x < r.maxX && y >= r.minY && y < r.maxY }?.0
        hovered = hit
        guard kind == 1 else { return }
        switch hit {
        case "2": count = min(999_999, count + 1)
        case "3": _count.projectedValue.wrappedValue = 0
        case "4": dark.toggle()
        default: break
        }
    }

    private func json<T: Encodable>(_ value: T) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func hello() {
        responseBuffer.encode(DevToolsEnvelope(type: "hello", payload: json(HelloPayload(
            host: HelloHostInfo(pid: 0, appTitle: "GuavaUI Wasm prototype", platform: "WebAssembly"),
            capabilities: ["tree", "select", "timing", "state"]))))
    }

    func dispatch(_ bytes: UnsafeRawBufferPointer) {
        guard let request = try? JSONDecoder().decode(DevToolsEnvelope.self, from: Data(bytes)) else {
            responseBuffer.encode(DevToolsEnvelope(type: "request.err", payload: json(ErrorPayload(code: "bad_request", message: "Invalid JSON"))))
            return
        }
        var response = DevToolsEnvelope(type: request.type + ".ok", id: request.id)
        func fail(_ message: String) { response.type = request.type + ".err"; response.payload = json(ErrorPayload(code: "bad_request", message: message)) }
        switch request.type {
        case "hello.ack": break
        case "tree.subscribe":
            subscriptions.insert("tree")
            response.type = "tree.snapshot"; response.payload = json(frame!.tree)
        case "tree.unsubscribe": subscriptions.remove("tree")
        case "timing.subscribe": subscriptions.insert("timing")
        case "timing.unsubscribe": subscriptions.remove("timing")
        case "select.node":
            if let id = request.payload?.objectValue?["id"]?.stringValue,
               ["1", "2", "3", "4", "5"].contains(id) { selected = id }
            else { fail("Unknown node") }
        case "select.clear": selected = nil
        case "state.checkpoint": response.payload = json(["count": String(count), "dark": String(dark)])
        case "state.restore":
            if let object = request.payload?.objectValue,
               object.values.allSatisfy({ $0.stringValue != nil }),
               let count = object["count"]?.stringValue.flatMap(Int.init), (0...999_999).contains(count),
               let darkString = object["dark"]?.stringValue, ["true", "false"].contains(darkString) {
                self.count = count; self.dark = darkString == "true"
            } else { fail("State requires count (0…999999) and dark (true/false), as strings") }
        case "bye": subscriptions.removeAll(); selected = nil
        default: fail("Unsupported browser prototype message")
        }
        responseBuffer.encode(response)
    }

    func events() {
        var messages = [DevToolsEnvelope]()
        if subscriptions.contains("tree"), let frame {
            messages.append(DevToolsEnvelope(type: "tree.delta", payload: json(frame.tree)))
        }
        if subscriptions.contains("timing"), let frame {
            messages.append(DevToolsEnvelope(type: "timing.frame", payload: json(TimingFramePayload(
                frame: frameNumber, layoutMs: 0, drawMs: renderMilliseconds, presentMs: 0, totalMs: renderMilliseconds,
                nodeCount: frame.tree.root!.children.count + 1, batchCount: frame.batches.count))))
        }
        responseBuffer.encode(messages)
    }
}

// This reactor is single-threaded. JavaScript invokes these exports on the same
// browser thread; pointers remain valid until the next corresponding mutation.
nonisolated(unsafe) private let app = BrowserPrototype()

@_cdecl("guava_render") public func guavaRender(_ width: Float, _ height: Float) { app.render(width: width, height: height) }
@_cdecl("guava_pointer") public func guavaPointer(_ kind: Int32, _ x: Float, _ y: Float) { app.pointer(kind: kind, x: x, y: y) }
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
