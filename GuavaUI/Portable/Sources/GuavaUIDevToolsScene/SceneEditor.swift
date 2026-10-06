import Foundation
import GuavaUIScene
import GuavaUIDevToolsProtocol
import GuavaPlatformCore

/// Scene-thread-only inspection. Diagnostic styles are independent of authored
/// styles, so recomposition cannot erase them or freeze the restoration value.
public final class SceneEditor: @unchecked Sendable {
    private final class NodeRef {
        weak var node: Node?
        init(_ node: Node) { self.node = node }
    }
    private struct Style: Equatable {
        var padding: LayoutInsets?
        var background, foreground: Color?
        var isEmpty: Bool { padding == nil && background == nil && foreground == nil }
    }
    private let tree: NodeTree
    private weak var indexedRoot: Node?
    private var indexedVersion: UInt64?
    private var nodeIndex: [String: NodeRef] = [:]
    private var overrides: [String: Style] = [:]
    private var overrideNodes: [String: NodeRef] = [:]
    private var undo: [[String: Style]] = []
    private var redo: [[String: Style]] = []
    public private(set) weak var selectedNode: Node?
    public private(set) weak var hoveredNode: Node?
    public private(set) var picking = false
    private var swallowedButtons: Set<MouseButton> = []
    public var onChange: (() -> Void)?
    public init(tree: NodeTree) { self.tree = tree }

    private func find(_ id: String) -> Node? {
        guard let root = tree.root else { nodeIndex.removeAll(); indexedRoot = nil; indexedVersion = nil; return nil }
        if indexedRoot !== root || indexedVersion != root.subtreeStructureVersion {
            nodeIndex.removeAll(keepingCapacity: true)
            func walk(_ node: Node) {
                let ref = NodeRef(node)
                nodeIndex[String(node.id.rawValue)] = ref
                nodeIndex[SceneInspector.identifier(for: node)] = ref
                for child in node.children { walk(child) }
            }
            walk(root); indexedRoot = root; indexedVersion = root.subtreeStructureVersion
        }
        return nodeIndex[id]?.node
    }
    public func select(_ id: String?) {
        selectedNode = id.flatMap(find); hoveredNode = nil; onChange?()
    }
    public var state: InspectionState {
        prune()
        return InspectionState(selectedID: selectedNode.map { String($0.id.rawValue) },
                               hoveredID: hoveredNode.map { String($0.id.rawValue) }, picking: picking,
                               canUndo: !undo.isEmpty, canRedo: !redo.isEmpty, overrideCount: overrides.count)
    }
    public func prune() {
        let live = overrides.filter { find($0.key) != nil }
        if live.count != overrides.count { apply(live) }
        if let node = selectedNode, find(String(node.id.rawValue)) == nil { selectedNode = nil }
        if let node = hoveredNode, find(String(node.id.rawValue)) == nil { hoveredNode = nil }
    }
    /// Disconnect/stop discards temporary styles and history. An outstanding
    /// picker mouse-up is still consumed to avoid leaking half a gesture.
    public func reset() {
        apply([:]); undo.removeAll(); redo.removeAll()
        selectedNode = nil; hoveredNode = nil; picking = false; onChange?()
    }
    private func apply(_ next: [String: Style]) {
        let live = next.filter { find($0.key) != nil }
        for id in Set(overrides.keys).union(live.keys) {
            if overrides[id] == live[id] { continue }
            guard let node = find(id) ?? overrideNodes[id]?.node else { overrideNodes[id] = nil; continue }
            let style = live[id]
            node.debugBackgroundColor = style?.background
            node.debugForegroundColor = style?.foreground
            node.layoutNode?.debugPadding = style?.padding
            node.markRenderDirty(reason: .styleSet(field: "debugStyle"))
            overrideNodes[id] = style == nil ? nil : NodeRef(node)
        }
        overrides = live
    }
    private func commit(_ next: [String: Style]) {
        guard next != overrides else { return }
        undo.append(overrides); if undo.count > 128 { undo.removeFirst() }
        redo.removeAll(); apply(next)
    }
    public func handle(_ request: DevToolsEnvelope) -> DevToolsEnvelope {
        if let error = InspectionValidation.error(request) { return DevToolsSession.error(request, code: "bad_request", message: error) }
        prune()
        let p = request.payload?.objectValue
        switch request.type {
        case "inspect.pick.start": picking = true; hoveredNode = nil
        case "inspect.pick.stop": picking = false; hoveredNode = nil
        case "inspect.hover", "inspect.pick":
            let node = pick(at: CGPoint(x: InspectionValidation.number(p?["x"])!, y: InspectionValidation.number(p?["y"])!))
            if request.type == "inspect.hover" { hoveredNode = node }
            else { selectedNode = node; hoveredNode = nil; picking = false }
        case "inspect.style.set", "inspect.style.clear":
            guard let node = find(p!["id"]!.stringValue!) else {
                return DevToolsSession.error(request, code: "stale_node", message: "Selected node is no longer in the scene")
            }
            let id = String(node.id.rawValue)
            var next = overrides
            if request.type == "inspect.style.clear" { next[id] = nil }
            else {
                let properties = p!["properties"]!.objectValue!
                if let value = properties["padding"], value.objectValue != nil, node.layoutNode == nil {
                    return DevToolsSession.error(request, code: "unsupported", message: "This composition anchor has no layout box; select a child")
                }
                var style = next[id] ?? Style()
                for (key, value) in properties {
                    if key == "padding" {
                        style.padding = value.objectValue.map { e in
                            LayoutInsets(top: Float(InspectionValidation.number(e["top"])!), right: Float(InspectionValidation.number(e["right"])!),
                                         bottom: Float(InspectionValidation.number(e["bottom"])!), left: Float(InspectionValidation.number(e["left"])!))
                        }
                    } else if key == "backgroundColor" { style.background = value.stringValue.flatMap(Self.color) }
                    else { style.foreground = value.stringValue.flatMap(Self.color) }
                }
                next[id] = style.isEmpty ? nil : style
            }
            guard next.count <= 256 else { return DevToolsSession.error(request, code: "limit", message: "At most 256 nodes may have temporary styles") }
            commit(next)
        case "inspect.style.clearAll": commit([:])
        case "inspect.style.undo":
            if let previous = undo.popLast() { redo.append(overrides); apply(previous) }
        case "inspect.style.redo":
            if let next = redo.popLast() { undo.append(overrides); apply(next) }
        default: break
        }
        onChange?()
        return DevToolsEnvelope(type: request.type + ".ok", id: request.id, payload: DevToolsCodec.json(state))
    }

    /// Visual hit test, in reverse paint order. Text and disabled controls are
    /// inspectable; clipping, scrolling and invisible subtrees match rendering.
    public func pick(at point: CGPoint) -> Node? {
        func visit(_ node: Node) -> Node? {
            guard node.opacity > 0, node.subtreeOpacity > 0, node.layoutNode?.display != Display.none else { return nil }
            let inside = node.absoluteFrame.contains(point)
            if !inside && node.clipsToBounds { return nil }
            let children = node.children.enumerated().sorted {
                $0.element.zIndex == $1.element.zIndex ? $0.offset > $1.offset : $0.element.zIndex > $1.element.zIndex
            }
            for child in children { if let hit = visit(child.element) { return hit } }
            return inside && (node.layoutNode != nil || node.draw != nil || node.backgroundColor != nil) ? node : nil
        }
        return tree.root.flatMap(visit)
    }
    public func intercept(_ event: InputEvent) -> Bool {
        if case .mouseButtonUp(let e) = event, swallowedButtons.remove(e.button) != nil { return true }
        guard picking else { return false }
        switch event {
        case .mouseMotion(let e): hoveredNode = pick(at: CGPoint(x: CGFloat(e.x), y: CGFloat(e.y))); onChange?(); return true
        case .mouseButtonDown(let e):
            swallowedButtons.insert(e.button)
            if e.button == .left {
                selectedNode = pick(at: CGPoint(x: CGFloat(e.x), y: CGFloat(e.y)))
                picking = false; hoveredNode = nil; onChange?()
            }
            return true
        case .keyDown(let e):
            if e.scancode == 41 { picking = false; hoveredNode = nil; onChange?() }
            return true
        case .mouseButtonUp, .mouseWheel, .keyUp, .textInput, .textEditing: return true
        default: return false
        }
    }
    public func drawOverlay(into list: DrawList) {
        prune()
        guard let node = hoveredNode ?? selectedNode else { return }
        let f = node.absoluteFrame
        guard f.width > 0, f.height > 0 else { return }
        var clips = [Node](); var parent = node.parent
        while let p = parent { if p.clipsToBounds { clips.append(p) }; parent = p.parent }
        for p in clips { let r = p.absoluteFrame; list.pushClip(UIRect(x: Float(r.minX), y: Float(r.minY), width: Float(r.width), height: Float(r.height))) }
        let x = Float(f.minX), y = Float(f.minY), w = Float(f.width), h = Float(f.height)
        if hoveredNode != nil, let padding = node.layoutNode?.resolvedPadding {
            let tint = Color(red: 100, green: 210, blue: 130, alpha: 75)
            list.addRect(UIRect(x: x, y: y, width: w, height: min(h, padding.top)), color: tint)
            list.addRect(UIRect(x: x, y: y + max(0, h - padding.bottom), width: w, height: min(h, padding.bottom)), color: tint)
            list.addRect(UIRect(x: x, y: y, width: min(w, padding.left), height: h), color: tint)
            list.addRect(UIRect(x: x + max(0, w - padding.right), y: y, width: min(w, padding.right), height: h), color: tint)
        }
        let c = hoveredNode != nil ? Color(red: 250, green: 180, blue: 40) : Color(red: 80, green: 160, blue: 255)
        list.addRect(UIRect(x: x, y: y, width: w, height: min(2, h)), color: c)
        list.addRect(UIRect(x: x, y: y + max(0, h - 2), width: w, height: min(2, h)), color: c)
        list.addRect(UIRect(x: x, y: y, width: min(2, w), height: h), color: c)
        list.addRect(UIRect(x: x + max(0, w - 2), y: y, width: min(2, w), height: h), color: c)
        for _ in clips { list.popClip() }
    }
    static func hex(_ color: Color?) -> String? {
        color.map { c in
            let rgba = c.rgba8
            return String(format: "#%02x%02x%02x%02x", rgba & 255, (rgba >> 8) & 255, (rgba >> 16) & 255, (rgba >> 24) & 255)
        }
    }
    private static func color(_ hex: String) -> Color? {
        guard let n = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        let rgba = hex.count == 7 ? (n << 8) | 255 : n
        return Color(red: UInt8((rgba >> 24) & 255), green: UInt8((rgba >> 16) & 255), blue: UInt8((rgba >> 8) & 255), alpha: UInt8(rgba & 255))
    }
}
