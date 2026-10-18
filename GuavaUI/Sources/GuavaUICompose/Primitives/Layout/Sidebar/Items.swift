import GuavaUIRuntime

public struct SidebarItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    /// Uses the active IconTheme, including resource replacements and scaling.
    public var icon: BundleImageResource?
    public var iconSize: SemanticIconSize = .medium
    public var badge: String?
    public var isEnabled = true
    /// A nonempty group expands instead of activating a destination.
    public var children: [Self] = []
    /// Per-item actions. macOS right-click opens them; a trailing ellipsis
    /// keeps the same menu reachable by pointer, keyboard and touch.
    public var contextMenu: [MenuEntry] = []
    public init(_ id: ID, _ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.id = id; self.title = title; configure(&self)
    }
}

public struct SidebarSection<ID: Hashable>: Identifiable {
    public let id: String
    public let title: String
    public let items: [SidebarItem<ID>]
    public init(_ id: String, title: String = "", items: [SidebarItem<ID>]) { self.id = id; self.title = title; self.items = items }
}
