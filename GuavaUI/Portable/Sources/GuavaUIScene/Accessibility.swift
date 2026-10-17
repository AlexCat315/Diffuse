import Foundation

/// Platform-neutral meaning of a scene element. Geometry and actions remain runtime data.
public enum AccessibilityRole: String, Sendable, Codable {
    case group, toolbar, button, staticText, heading, textField, checkbox, toggle, slider, radio, tab
    case list, listItem, tree, treeItem, table, row, cell, dialog, status, progress, image, link
    case scrollArea, comboBox
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

public struct AccessibilitySemantics: Sendable, Equatable, Codable {
    public var role: AccessibilityRole
    public var label = ""
    public var value = ""
    public var help = ""
    public var identifier = ""
    /// Identifier of another element whose label/value describes this one.
    public var describedBy: String?
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
        let elements = collect(root, clip: viewport ?? root.absoluteFrame, combinesText: false, resolveValues: resolveValues)
        var byIdentifier: [String: AccessibilityElement] = [:]
        func index(_ list: [AccessibilityElement]) {
            for element in list {
                if !element.semantics.identifier.isEmpty {
                    byIdentifier[element.semantics.identifier] = byIdentifier[element.semantics.identifier] ?? element
                }
                index(element.children)
            }
        }
        index(elements)
        func resolve(_ list: [AccessibilityElement]) -> [AccessibilityElement] {
            list.map { element in
                var semantics = element.semantics
                if let identifier = semantics.describedBy,
                   let target = byIdentifier[identifier] {
                    let description = target.semantics.label.isEmpty
                        ? target.semantics.value : target.semantics.label
                    if !description.isEmpty, !semantics.help.contains(description) {
                        semantics.help = semantics.help.isEmpty
                            ? description : semantics.help + ". " + description
                    }
                }
                return AccessibilityElement(node: element.node, semantics: semantics,
                                            frame: element.frame,
                                            children: resolve(element.children))
            }
        }
        return resolve(elements)
    }
    private static func collect(_ node: Node, clip: CGRect, combinesText: Bool, resolveValues: Bool) -> [AccessibilityElement] {
        guard node.isLayoutVisible, node.isInteractionEnabled, node.opacity > 0, node.subtreeOpacity > 0,
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
            semantic.label = resolvedLabel(for: node)
        }
        if semantic.role == .cell && semantic.value.isEmpty { semantic.value = labelText(in: node).joined(separator: " ") }
        if semantic.role == .listItem && semantic.label.isEmpty {
            semantic.label = children.filter { $0.semantics.role == .cell }.map { "\($0.semantics.label): \($0.semantics.value)" }.joined(separator: ", ")
        }
        if resolveValues, node.accessibilityValueProvider != nil { semantic.value = node.resolvedAccessibilityValue }
        else if semantic.state.isSecure { semantic.value = String(repeating: "•", count: semantic.value.count) }
        return [AccessibilityElement(node: node, semantics: semantic, frame: frame, children: children)]
    }
    /// Resolves `describedBy` links for clients that read semantics directly
    /// instead of walking `snapshot` (for example DevTools node queries).
    package static func resolvingDescriptions(
        in meanings: [String: AccessibilitySemantics]
    ) -> [String: AccessibilitySemantics] {
        var byIdentifier: [String: AccessibilitySemantics] = [:]
        for semantics in meanings.values where !semantics.identifier.isEmpty {
            byIdentifier[semantics.identifier] = byIdentifier[semantics.identifier] ?? semantics
        }
        return meanings.mapValues { semantics in
            var resolved = semantics
            guard let identifier = resolved.describedBy,
                  let target = byIdentifier[identifier] else { return resolved }
            let description = target.label.isEmpty ? target.value : target.label
            if !description.isEmpty, !resolved.help.contains(description) {
                resolved.help = resolved.help.isEmpty ? description : resolved.help + ". " + description
            }
            return resolved
        }
    }

    /// Shared by native accessibility and agent diagnostics; never evaluates a
    /// lazy value provider or treats an editable field value as its label.
    package static func resolvedLabel(for node: Node) -> String {
        guard let semantic = node.accessibility else { return "" }
        guard semantic.label.isEmpty && semantic.combinesChildren else { return semantic.label }
        let text = labelText(in: node).joined(separator: " ")
        return text.isEmpty ? semantic.help : text
    }

    private static func labelText(in node: Node) -> [String] {
        node.children.flatMap { child -> [String] in
            guard child.isLayoutVisible, child.isInteractionEnabled, child.opacity > 0, child.subtreeOpacity > 0 else { return [] }
            if let semantics = child.accessibility {
                if semantics.isHidden { return [] }
                if semantics.role == .staticText { return [semantics.label] }
                if semantics.role != .group { return [] }
            }
            return labelText(in: child)
        }
    }
}
