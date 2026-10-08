import Foundation
import GuavaUIScene
import PlatformShell
#if os(macOS)
import AppKit
#endif

/// Updates native accessibility after layout; registrations leave with the root node.
@MainActor
public enum NativeAccessibility {
    public static func synchronize(host: SDL3PlatformHost, session: PlatformWindowSession, root: Node) {
#if os(macOS)
        guard case .appKit(let pointer) = host.nativeWindowReference(for: session.id),
              let view = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue().contentView else { return }
        let bridge: MacAccessibilityBridge
        if let existing = root.firstResource(MacAccessibilityBridge.self) { bridge = existing }
        else { bridge = MacAccessibilityBridge(view: view); root.addResource(bridge) }
        bridge.update(root: root, focus: session.focusChain) { [weak session] action in
            guard let session else { return }
            session.withCurrent { action(); session.recomposer.commitAll() }
            session.requestDisplay()
        }
#endif
    }
}

#if os(macOS)
@MainActor
final class MacAccessibilityBridge: NodeResource {
    private weak var view: NSView?
    private let originalChildren: [Any]?
    private let originalIsElement: Bool
    private var elements: [ElementID: MacSceneAccessibilityElement] = [:]
    private var rootIDs: [ElementID] = []
    init(view: NSView) { self.view = view; originalChildren = view.accessibilityChildren(); originalIsElement = view.isAccessibilityElement() }
    nonisolated func mount(node: Node) {}
    nonisolated func unmount(node: Node) {
        MainActor.assumeIsolated {
            view?.setAccessibilityChildren(originalChildren)
            view?.setAccessibilityElement(originalIsElement)
            elements.values.forEach { $0.invalidate() }; elements.removeAll(); rootIDs.removeAll(); view = nil
        }
    }
    func update(root: Node, focus: FocusChain, perform: @escaping (() -> Void) -> Void) {
        guard let view, let window = view.window else { return }
        let snapshot = AccessibilityTree.snapshot(root: focus.modalRoot ?? root, viewport: root.absoluteFrame, resolveValues: false)
        var next: [ElementID: MacSceneAccessibilityElement] = [:]
        func materialize(_ item: AccessibilityElement, parent: Any) -> MacSceneAccessibilityElement {
            let element = elements[item.id] ?? MacSceneAccessibilityElement()
            next[item.id] = element
            let bounds = item.frame
            let local = NSRect(x: bounds.minX, y: view.isFlipped ? bounds.minY : view.bounds.height - bounds.maxY,
                               width: bounds.width, height: bounds.height)
            let screen = window.convertToScreen(view.convert(local, to: nil))
            element.update(item: item, parent: parent, frame: screen, focused: focus.focused === item.node, perform: perform, permitted: { focus.permitsInput(item.node) },
                           focus: { [weak node = item.node] in if let node { focus.focus(node, visible: true) } })
            element.setAccessibilityChildren(item.children.map { materialize($0, parent: element) })
            return element
        }
        let children = snapshot.map { materialize($0, parent: view) }
        let changed = rootIDs != snapshot.map(\.id)
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren(children)
        for (id, element) in elements where next[id] == nil { element.invalidate() }
        elements = next; rootIDs = snapshot.map(\.id)
        if changed { NSAccessibility.post(element: view, notification: .layoutChanged) }
    }
}

// AppKit invokes accessibility callbacks on the main thread, matching the scene ownership contract.
private final class MacSceneAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    private weak var node: Node?
    private var perform: ((() -> Void) -> Void)?
    private var focusAction: (() -> Void)?
    private var updating = false
    private var previousValueIdentity: AnyHashable?
    private var permitted: (() -> Bool)?
    func update(item: AccessibilityElement, parent: Any, frame: NSRect, focused: Bool,
                perform: @escaping (() -> Void) -> Void, permitted: @escaping () -> Bool, focus: @escaping () -> Void) {
        updating = true
        defer { updating = false }
        node = item.node; self.perform = perform; self.permitted = permitted; focusAction = focus
        let semantics = item.semantics
        setAccessibilityElement(true)
        setAccessibilityParent(parent); setAccessibilityRole(semantics.role.nativeRole)
        setAccessibilitySubrole(semantics.state.isSecure ? .secureTextField : nil)
        let staticText = semantics.role == .staticText || semantics.role == .status
        // AppKit reads static text from AXValue. The portable label stores its
        // displayed text; repeating it in AXDescription makes VoiceOver read it twice.
        setAccessibilityLabel(staticText && semantics.value.isEmpty ? nil : semantics.label)
        setAccessibilityHelp(semantics.help)
        setAccessibilityIdentifier(semantics.identifier.isEmpty ? item.id.description : semantics.identifier)
        let actions = item.node.accessibilityActions
        let interactive = item.node.isFocusable || actions.activate != nil || actions.setValue != nil
            || actions.increment != nil || actions.decrement != nil
        setAccessibilityFrame(frame)
        // Pointer-transparent descriptions remain readable. Their lack of an
        // input target does not make the text disabled; actions still consult
        // acceptsSubtreeInput and the current focus scope in invoke().
        setAccessibilityEnabled(semantics.state.isEnabled && (!interactive || item.node.acceptsSubtreeInput))
        setAccessibilitySelected(semantics.state.isSelected); setAccessibilityFocused(focused)
        setAccessibilityExpanded(semantics.state.isExpanded ?? false)
        let displayedValue = staticText && semantics.value.isEmpty ? semantics.label : semantics.value
        let identity = item.node.accessibilityValueProvider?.revision ?? AnyHashable(displayedValue)
        let previous = previousValueIdentity; previousValueIdentity = identity
        let nativeValue: Any
        if semantics.role == .checkbox || semantics.role == .toggle { nativeValue = NSNumber(value: semantics.value == "mixed" ? 2 : semantics.value == "1" ? 1 : 0) }
        else if semantics.role == .slider || semantics.role == .progress { nativeValue = NSNumber(value: Double(semantics.value) ?? 0) }
        else { nativeValue = displayedValue }
        super.setAccessibilityValue(nativeValue)
        if previous != nil && previous != identity { NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    func invalidate() { node = nil; perform = nil; permitted = nil; focusAction = nil; setAccessibilityChildren(nil) }
    private func invoke(_ action: (() -> Void)?) -> Bool {
        precondition(Thread.isMainThread)
        guard permitted?() == true, let node, node.acceptsSubtreeInput, node.accessibility?.state.isEnabled == true,
              let action, let perform else { return false }
        perform(action); return true
    }
    override func accessibilityPerformPress() -> Bool {
        invoke(node?.accessibilityActions.activate)
    }
    override func accessibilityPerformIncrement() -> Bool {
        invoke(node?.accessibilityActions.increment)
    }
    override func accessibilityPerformDecrement() -> Bool {
        invoke(node?.accessibilityActions.decrement)
    }
    override func setAccessibilityValue(_ value: Any?) {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        receive(value: text)
    }
    override func accessibilityValue() -> Any? {
        precondition(Thread.isMainThread)
        if let node, node.accessibilityValueProvider != nil { return node.resolvedAccessibilityValue }
        return super.accessibilityValue()
    }
    private func receive(value: Any?) {
        if updating { super.setAccessibilityValue(value); return }
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, let setter = node?.accessibilityActions.setValue else { return }
        _ = invoke { setter(text) }
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        receive(focused: focused)
    }
    private func receive(focused: Bool) {
        if updating { super.setAccessibilityFocused(focused); return }
        if focused { _ = invoke(focusAction) }
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        let allowed: Bool? = {
            if selector == #selector(accessibilityPerformPress) { return node?.accessibilityActions.activate != nil }
            if selector == #selector(setAccessibilityValue(_:)) { return node?.accessibilityActions.setValue != nil }
            if selector == #selector(accessibilityPerformIncrement) { return node?.accessibilityActions.increment != nil }
            if selector == #selector(accessibilityPerformDecrement) { return node?.accessibilityActions.decrement != nil }
            if selector == #selector(isAccessibilityExpanded) { return node?.accessibility?.state.isExpanded != nil }
            if selector == #selector(setAccessibilityExpanded(_:)) { return false }
            return nil
        }()
        return allowed ?? super.isAccessibilitySelectorAllowed(selector)
    }

}

private extension AccessibilityRole {
    var nativeRole: NSAccessibility.Role {
        switch self {
        case .button: return .button
        case .staticText, .status: return .staticText
        case .textField: return .textField
        case .checkbox, .toggle: return .checkBox
        case .slider: return .slider
        case .radio: return .radioButton
        case .tab: return .radioButton
        case .list: return .list
        case .tree: return .outline
        case .table: return .table
        case .row, .listItem, .treeItem: return .row
        case .cell: return .cell
        case .dialog, .group: return .group
        case .progress: return .progressIndicator
        case .image: return .image
        }
    }
}
#endif
