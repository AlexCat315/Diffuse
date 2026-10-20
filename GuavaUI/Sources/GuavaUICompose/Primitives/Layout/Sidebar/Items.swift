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
    /// Caller views placed inside the row (expanded presentation only).
    public var slots = SidebarItemSlots()
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

/// Inline views for one sidebar row. `leading` and `trailing` sit inside the
/// destination's hit area, so they are decorative and hidden from assistive
/// technology (the title remains the row's name). `accessory` sits outside the
/// destination button at the trailing edge and may be interactive, such as a
/// visibility toggle; it reserves `accessoryWidth` so the title never runs
/// under it. Rail presentations keep only the icon.
public struct SidebarItemSlots {
    public var leading: AnyView?
    public var trailing: AnyView?
    public var accessory: AnyView?
    public var accessoryWidth: Float = 44 {
        didSet { accessoryWidth = accessoryWidth.isFinite ? max(0, min(240, accessoryWidth)) : 44 }
    }
    public init() {}
    /// Leading lane content wins over the item's icon.
    var occupiesLeadingLane: Bool { leading != nil }
}
