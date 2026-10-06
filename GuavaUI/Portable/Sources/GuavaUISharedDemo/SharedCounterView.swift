import Foundation
import GuavaUIComposeCore

/// One Compose source used by both SDL and browser hosts. Text painting is the
/// host boundary: both hosts can shape text into their shared font atlas.
public struct DemoText: Sendable {
    public var text: String
    public var size: Float
    public var color: Color
    public var inset: Float
}

public enum SharedDemoText {
    public static let attachment = "GuavaUI.sharedDemo.text"
    public typealias Painter = (DemoText, DrawList, CGPoint) -> Void
    public static let painter = CompositionLocal<Painter?>(defaultValue: nil)
}

public struct SharedCounterView: View {
    @State public var count = 0
    @State public var dark = false
    @State public var note = ""

    public init() {}
    public var checkpoint: [String: String] { ["count": String(count), "dark": String(dark), "note": note] }
    @discardableResult public func restore(_ values: [String: String]) -> Bool {
        guard let count = values["count"].flatMap(Int.init), (0...999_999).contains(count),
              let dark = values["dark"], ["true", "false"].contains(dark),
              (values["note"]?.count ?? 0) <= 2048 else { return false }
        self.count = count; self.dark = dark == "true"
        if let note = values["note"] { self.note = note }
        return true
    }

    public var body: some View {
        let foreground = dark ? Color(red: 241, green: 245, blue: 249) : Color(red: 22, green: 35, blue: 56)
        let background = dark ? Color(red: 20, green: 29, blue: 45) : Color(red: 244, green: 247, blue: 252)
        return Box(direction: .column, alignItems: .stretch, spacing: 12) {
            DemoLabel("GuavaUI · Swift in your browser", size: 22, color: foreground, height: 36)
            DemoLabel("Shared Compose · ViewGraph · Yoga", size: 14, color: foreground, height: 24)
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                DemoLabel("Counter", size: 14, color: foreground, height: 24)
                DemoLabel(String(count), size: 42, color: foreground, height: 50).debugName("counter.value")
            }.modifier(DemoStyle(height: 126, padding: 20, background: foreground.multipliedAlpha(0.06)))
             .debugName("counter.card")
            Row(spacing: 12) {
                DemoButton("+ Increment", name: "counter.increment", grow: 1) { count = min(999_999, count + 1) }
                DemoButton("Reset", name: "counter.reset", grow: 1) { count = 0 }
            }
            DemoButton(dark ? "Light theme" : "Dark theme", name: "counter.theme") { dark.toggle() }
            DemoNote(value: $note, color: foreground)
        }.modifier(DemoStyle(padding: 24, background: background, grow: 1))
         .debugName("browser.root")
    }
}

private struct DemoStyle: ViewModifier {
    var height: Float? = nil
    var padding: Float = 0
    var background: Color? = nil
    var grow: Float = 0
    func apply(node: Node) { node.backgroundColor = background; node.cornerRadius = 12; node.isHitTestable = false }
    func apply(layout: LayoutNode) {
        layout.height = height; layout.setPadding(padding); layout.flexGrow = grow
        layout.setWidthPercent(100)
    }
}

private struct DemoLabel: _PrimitiveView {
    let text: String
    let size: Float
    let color: Color
    let height: Float
    init(_ text: String, size: Float, color: Color, height: Float) {
        self.text = text; self.size = size; self.color = color; self.height = height
    }
    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) {
        node.isHitTestable = false
        installText(DemoText(text: text, size: size, color: color, inset: 0), on: node)
    }
    func _updateLayout(_ layout: LayoutNode) { layout.height = height }
}

private func installText(_ text: DemoText, on node: Node) {
    node.attachments[SharedDemoText.attachment] = text
    let painter = node.compositionValue(of: SharedDemoText.painter)
    node.draw = { [weak node] list, origin in
        var painted = text
        painted.color = node?.inheritedForegroundColor ?? text.color
        let p = node?.layoutNode?.resolvedPadding
        painter?(painted, list, CGPoint(x: origin.x + CGFloat(p?.left ?? 0), y: origin.y + CGFloat(p?.top ?? 0)))
    }
}

private struct DemoButton: _PrimitiveView {
    let title: String
    let name: String
    let grow: Float
    let action: () -> Void
    init(_ title: String, name: String, grow: Float = 0, action: @escaping () -> Void) {
        self.title = title; self.name = name; self.grow = grow; self.action = action
    }
    func _makeNode() -> Node { Node() }
    func _updateLayout(_ layout: LayoutNode) { layout.height = 48; layout.flexGrow = grow; if grow > 0 { layout.setFlexBasis(0) } else { layout.setFlexBasisAuto() } }
    func _updateNode(_ node: Node) {
        node.isFocusable = true; node.isHitTestable = true; node.cursor = .pointer
        node.cornerRadius = 9; node.backgroundColor = Color(red: 40, green: 130, blue: 235)
        node.attachments[LayoutDebugAttachmentKey.debugName] = name
        installText(DemoText(text: title, size: 16, color: .white, inset: 16), on: node)
        guard let registry = InteractionRegistryHolder.current else { return }
        let capture = PointerCaptureHolder.current
        let focus = FocusChainHolder.current
        registry.setPointer(node) { [weak node] event, phase, delivery in
            guard delivery == .target, event.button == .left, let node else { return .ignored }
            if phase == .down {
                node.attachments["pressed"] = true; capture?.acquire(node)
            } else {
                let pressed = node.attachments.removeValue(forKey: "pressed") as? Bool == true
                capture?.release()
                if pressed, node.absoluteFrame.contains(CGPoint(x: Double(event.x), y: Double(event.y))) { action() }
            }
            return .handled
        }
        registry.setKey(node) { event, delivery in
            guard delivery == .target, !event.isRepeat, [UInt32(40), 44].contains(event.scancode) else { return .ignored }
            action(); return .handled
        }
        registry.setHover(node) { [weak node] phase in
            node?.backgroundColor = phase == .enter ? Color(red: 29, green: 110, blue: 210) : Color(red: 40, green: 130, blue: 235)
        }
        node.overlayDraw = { [weak node] list, origin in
            guard let node, focus?.focused === node, focus?.isFocusVisible == true else { return }
            list.addRoundedRectStroke(UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height)), radius: 9, width: 2, color: Color(red: 250, green: 180, blue: 40))
        }
    }
}


/// Small append-at-caret-end text example, not the native full TextField editor.
private struct DemoNote: _PrimitiveView {
    let value: Binding<String>
    let color: Color
    func _makeNode() -> Node { Node() }
    func _updateLayout(_ layout: LayoutNode) { layout.height = 48 }
    func _updateNode(_ node: Node) {
        node.isHitTestable = true; node.isFocusable = true; node.cursor = .ibeam
        node.cornerRadius = 9; node.backgroundColor = color.multipliedAlpha(0.06)
        node.attachments[LayoutDebugAttachmentKey.debugName] = "counter.note"
        let label = DemoText(text: value.wrappedValue.isEmpty ? "Type a note · Unicode / IME" : value.wrappedValue,
                             size: 16, color: color, inset: 16)
        node.attachments[SharedDemoText.attachment] = label
        let painter = node.compositionValue(of: SharedDemoText.painter)
        node.draw = { [weak node] list, origin in
            var text = label
            if let preedit = node?.attachments["preedit"] as? String, !preedit.isEmpty {
                text.text = value.wrappedValue + preedit
            }
            painter?(text, list, origin)
        }
        node.attachments[TextInputAttachmentKey.areaResolver] = { (node: Node, origin: CGPoint) in
            TextInputArea(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: 48, cursorX: 16)
        } as TextInputAreaResolver
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setText(node) { [weak node] text, phase in
            guard phase == .target else { return .ignored }
            value.wrappedValue = String((value.wrappedValue + text).prefix(2048))
            node?.attachments.removeValue(forKey: "preedit")
            return .handled
        }
        registry.setEditing(node) { [weak node] event, phase in
            guard phase == .target, let node else { return .ignored }
            node.attachments["preedit"] = event.text
            node.markRenderDirty(); return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, event.scancode == 42 else { return .ignored }
            if !value.wrappedValue.isEmpty { value.wrappedValue.removeLast() }
            return .handled
        }
    }
}
