import Foundation

/// Pure data describing a context-menu (or any popover-with-actions UI)
/// that the dock layer wants the host to render. The dock layer never
/// itself draws the menu; hosts decide whether to forward it to the
/// in-house `Popover/Menu` primitives, an SDL native menu, or
/// something custom.
public struct MenuDescriptor: Sendable {
    public var items: [MenuItemDescriptor]
    public init(items: [MenuItemDescriptor]) { self.items = items }
}

/// One row of a `MenuDescriptor`. Use `.separator` for the visual
/// dividers between groups; everything else is an actionable item.
/// `shortcut` is a display-only hint (e.g. "⌘W") — wiring the actual
/// key binding is the host's job (and the dock-level shortcuts in
/// Phase R.C handle the canonical ones independently).
public enum MenuItemDescriptor: Sendable {
    case separator
    case action(title: String,
                shortcut: String? = nil,
                isEnabled: Bool = true,
                action: @Sendable () -> Void)
}

extension DockController {

    /// Build the canonical right-click menu for `tabID` inside `leafID`.
    /// The action closures call back into `apply(...)` against this
    /// controller, so the descriptor stays valid as long as the
    /// controller is alive. Items missing prerequisite state (e.g.
    /// `Reopen Closed Tab` when the history is empty) are still
    /// emitted but flagged as `isEnabled: false` so menus reflect
    /// the available commands at the moment they are presented.
    public func defaultTabMenu(for tabID: DockTabID,
                               leafID: DockNodeID) -> MenuDescriptor {
        // Resolve the tab's current state so toggle labels and
        // disabled flags reflect reality.
        let snapshot = resolveTab(tabID: tabID, leafID: leafID)
        let canCloseToTheRight = snapshot.tabsInLeaf.last?.id != tabID
            && snapshot.tabsInLeaf.contains(where: { $0.id == tabID })
        let canCloseOthers = snapshot.tabsInLeaf.count > 1
        let canDetach = !satellites.keys.contains(leafID)
            && root.id != leafID
        let canReopen = !closedHistory.isEmpty
        let isPinned = snapshot.tab?.isPinned ?? false
        let pinTitle = isPinned ? "Unpin Tab" : "Pin Tab"

        // Capture controller weakly so the descriptor never holds the
        // controller alive past its expected lifetime.
        let items: [MenuItemDescriptor] = [
            .action(title: "Close Tab",
                    shortcut: "⌘W",
                    isEnabled: snapshot.tab != nil) { [weak self] in
                self?.apply(.closeTab(tabID))
            },
            .action(title: "Close Others",
                    isEnabled: canCloseOthers) { [weak self] in
                self?.apply(.closeOthers(in: leafID, keep: tabID))
            },
            .action(title: "Close to the Right",
                    isEnabled: canCloseToTheRight) { [weak self] in
                self?.apply(.closeToTheRight(in: leafID, of: tabID))
            },
            .separator,
            .action(title: pinTitle,
                    isEnabled: snapshot.tab != nil) { [weak self] in
                self?.apply(.setPinned(tabID: tabID, isPinned: !isPinned))
            },
            .action(title: "Detach into New Window",
                    isEnabled: canDetach) { [weak self] in
                self?.apply(.detach(leafID: leafID))
            },
            .separator,
            .action(title: "Reopen Closed Tab",
                    shortcut: "⌘⇧T",
                    isEnabled: canReopen) { [weak self] in
                self?.apply(.reopenLastClosed)
            },
        ]
        return MenuDescriptor(items: items)
    }

    /// Resolved snapshot of `tabID` plus the sibling tabs in `leafID`.
    /// Used by `defaultTabMenu` to compute which items are enabled.
    private struct TabSnapshot {
        var tab: DockTab?
        var tabsInLeaf: [DockTab]
    }

    private func resolveTab(tabID: DockTabID, leafID: DockNodeID) -> TabSnapshot {
        let leafCandidate = Self.findNode(leafID, in: root) ?? satellites[leafID]
        guard case .tabs(_, let tabs, _) = leafCandidate else {
            return TabSnapshot(tab: nil, tabsInLeaf: [])
        }
        return TabSnapshot(
            tab: tabs.first(where: { $0.id == tabID }),
            tabsInLeaf: tabs
        )
    }
}
