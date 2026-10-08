import Foundation

/// Platform-neutral meaning of a scene element. Geometry and actions remain runtime data.
public enum AccessibilityRole: String, Sendable, Codable {
    case group, button, staticText, textField, checkbox, toggle, slider, radio, tab
    case list, listItem, tree, treeItem, table, row, cell, dialog, status, progress, image
}

public struct AccessibilityState: Sendable, Equatable, Codable {
    public var isEnabled = true
    public var isSelected = false
    public var isExpanded: Bool?
    public var isRequired = false
    public var isInvalid = false
    public var isReadOnly = false
    public var isSecure = false
    public init() {}
}

public struct AccessibilitySemantics: Sendable, Equatable {
    public var role: AccessibilityRole
    public var label = ""
    public var value = ""
    public var help = ""
    public var identifier = ""
    public var state = AccessibilityState()
    /// A control combines decorative text, while retaining nested actionable controls.
    public var combinesChildren = false
    public var isHidden = false
    public init(_ role: AccessibilityRole, configure: (inout Self) -> Void = { _ in }) {
        self.role = role; configure(&self)
    }
}

/// Closures operate on the same controlled bindings as pointer and keyboard input.
public struct AccessibilityActions {
    public var activate: (() -> Void)?
    public var setValue: ((String) -> Void)?
    public var increment: (() -> Void)?
    public var decrement: (() -> Void)?
    public init() {}
}

/// Large values are materialized only when an assistive client asks for them.
/// A cheap revision lets platform bridges publish changes without reading text.
public struct AccessibilityValueProvider {
    public let revision: AnyHashable
    public let read: () -> String
    public init(revision: AnyHashable, read: @escaping () -> String) {
        self.revision = revision; self.read = read
    }
}

public extension Node {
    var accessibility: AccessibilitySemantics? {
        get { attachments["__accessibility.semantics"] as? AccessibilitySemantics }
        set { attachments["__accessibility.semantics"] = newValue }
    }
    var accessibilityActions: AccessibilityActions {
        get { attachments["__accessibility.actions"] as? AccessibilityActions ?? AccessibilityActions() }
        set { attachments["__accessibility.actions"] = newValue }
    }
    var accessibilityValueProvider: AccessibilityValueProvider? {
        get { attachments["__accessibility.valueProvider"] as? AccessibilityValueProvider }
        set { attachments["__accessibility.valueProvider"] = newValue }
    }
    var resolvedAccessibilityValue: String {
        let value = accessibilityValueProvider?.read() ?? accessibility?.value ?? ""
        return accessibility?.state.isSecure == true ? String(repeating: "•", count: value.count) : value
    }
}

public struct AccessibilityElement {
    public let node: Node
    public let semantics: AccessibilitySemantics
    public let frame: CGRect
    public let children: [AccessibilityElement]
    public var id: ElementID { node.id }
}

public enum AccessibilityTree {
    public static func snapshot(root: Node, viewport: CGRect? = nil, resolveValues: Bool = true) -> [AccessibilityElement] {
        collect(root, clip: viewport ?? root.absoluteFrame, combinesText: false, resolveValues: resolveValues)
    }
    private static func collect(_ node: Node, clip: CGRect, combinesText: Bool, resolveValues: Bool) -> [AccessibilityElement] {
        guard node.isInteractionEnabled, node.opacity > 0, node.subtreeOpacity > 0,
              node.accessibility?.isHidden != true else { return [] }
        let bounds = node.absoluteFrame
        let childClip = node.clipsToBounds ? clip.intersection(bounds) : clip
        guard !childClip.isNull else { return [] }
        let semantic = node.accessibility
        let children = node.children.flatMap { collect($0, clip: childClip, combinesText: combinesText || semantic?.combinesChildren == true, resolveValues: resolveValues) }
        guard var semantic else { return children }
        if combinesText && semantic.role == .staticText { return children }
        let frame = bounds.intersection(clip)
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return children }
        if semantic.label.isEmpty && semantic.combinesChildren {
            semantic.label = labelText(in: node).joined(separator: " ")
            if semantic.label.isEmpty { semantic.label = semantic.help }
        }
        if semantic.role == .cell && semantic.value.isEmpty { semantic.value = labelText(in: node).joined(separator: " ") }
        if semantic.role == .listItem && semantic.label.isEmpty {
            semantic.label = children.filter { $0.semantics.role == .cell }.map { "\($0.semantics.label): \($0.semantics.value)" }.joined(separator: ", ")
        }
        if resolveValues, node.accessibilityValueProvider != nil { semantic.value = node.resolvedAccessibilityValue }
        else if semantic.state.isSecure { semantic.value = String(repeating: "•", count: semantic.value.count) }
        return [AccessibilityElement(node: node, semantics: semantic, frame: frame, children: children)]
    }
    private static func labelText(in node: Node) -> [String] {
        node.children.flatMap { child -> [String] in
            if let semantics = child.accessibility {
                if semantics.isHidden { return [] }
                if semantics.role == .staticText { return [semantics.label] }
                if semantics.role != .group { return [] }
            }
            return labelText(in: child)
        }
    }
}
