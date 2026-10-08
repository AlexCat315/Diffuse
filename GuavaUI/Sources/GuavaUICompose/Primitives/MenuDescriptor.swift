/// Pure data describing a context menu or popover menu. Host layers can build
/// these descriptors without depending on a concrete menu renderer.
public struct MenuDescriptor: Sendable {
    public var items: [MenuItemDescriptor]

    public init(items: [MenuItemDescriptor]) {
        self.items = items
    }
}

public enum MenuItemDescriptor: Sendable {
    case separator
    case label(String)
    case submenu(title: String, isEnabled: Bool = true, items: [MenuItemDescriptor])
    case action(title: String,
                shortcut: KeyboardShortcut? = nil,
                isEnabled: Bool = true,
                action: @Sendable () -> Void)
}
