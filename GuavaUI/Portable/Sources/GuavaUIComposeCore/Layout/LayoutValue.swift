import GuavaUIScene

/// A per-child value a custom `Layout` reads from its subviews, such as a grid
/// cell's span. Values live with the child's layout node, so children declare
/// them with `.layoutValue(key:value:)` and need no wrapper type.
public protocol LayoutValueKey {
    associatedtype Value: Equatable
    static var defaultValue: Value { get }
}

enum LayoutValueStorage {
    static func key<K: LayoutValueKey>(_: K.Type) -> String { "layoutValue.\(ObjectIdentifier(K.self))" }
}

private struct LayoutValueModifier<K: LayoutValueKey>: ViewModifier {
    let value: K.Value
    func apply(layout: LayoutNode) {
        let key = LayoutValueStorage.key(K.self)
        guard layout.attachments[key] as? K.Value != value else { return }
        layout.attachments[key] = value
        // The owning custom layout measures through its own callback.
        if let parent = layout.parent, parent.hasMeasureFunc { parent.markDirty() }
    }
}

public extension View {
    func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> some View {
        modifier(LayoutValueModifier<K>(value: value))
    }
}
