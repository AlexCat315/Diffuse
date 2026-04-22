import Foundation
import Testing
@testable import GuavaUICompose

/// Phase R.C — `DockController.defaultTabMenu` shape + behaviour.
/// Verifies that the produced descriptor contains every documented
/// command, that the per-state enable flags reflect controller state,
/// and that invoking each action dispatches the expected operation.
@Suite("Phase R.C DockController defaultTabMenu")
struct DockCommandMenuTests {

    /// Pull only the action titles in order (separators excluded).
    private func actionTitles(_ menu: MenuDescriptor) -> [String] {
        menu.items.compactMap { item in
            if case .action(let title, _, _, _) = item { return title }
            return nil
        }
    }

    /// Find an enabled action by title and invoke it.
    private func invoke(_ menu: MenuDescriptor, title: String) {
        for item in menu.items {
            if case .action(let t, _, _, let action) = item, t == title {
                action()
                return
            }
        }
        Issue.record("menu had no action titled '\(title)'")
    }

    private func enabled(_ menu: MenuDescriptor, title: String) -> Bool? {
        for item in menu.items {
            if case .action(let t, _, let isEnabled, _) = item, t == title {
                return isEnabled
            }
        }
        return nil
    }

    // MARK: shape

    @Test("Default menu lists every documented command in canonical order")
    func canonicalOrder() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([a, b])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        #expect(actionTitles(menu) == [
            "Close Tab",
            "Close Others",
            "Close to the Right",
            "Pin Tab",
            "Detach into New Window",
            "Reopen Closed Tab",
        ])
    }

    @Test("Pin label flips to 'Unpin Tab' when the tab is already pinned")
    func pinLabelFlips() {
        let a = DockTab(userKey: "a", title: "A", isPinned: true)
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        #expect(actionTitles(menu).contains("Unpin Tab"))
        #expect(!actionTitles(menu).contains("Pin Tab"))
    }

    // MARK: enable flags

    @Test("Single-tab leaf disables Close Others and Close to the Right")
    func disableMultiCloseOnSingleTab() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        #expect(enabled(menu, title: "Close Others") == false)
        #expect(enabled(menu, title: "Close to the Right") == false)
    }

    @Test("Detach is disabled for the root leaf")
    func detachDisabledOnRoot() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        #expect(enabled(menu, title: "Detach into New Window") == false)
    }

    @Test("Reopen is disabled until the history is non-empty")
    func reopenGatedOnHistory() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([a, b])
        let controller = DockController(root: leaf)

        let before = controller.defaultTabMenu(for: a.id, leafID: leaf.id)
        #expect(enabled(before, title: "Reopen Closed Tab") == false)

        controller.apply(.closeTab(b.id))
        let after = controller.defaultTabMenu(for: a.id, leafID: leaf.id)
        #expect(enabled(after, title: "Reopen Closed Tab") == true)
    }

    // MARK: actions wire to ops

    @Test("Invoking 'Close Tab' dispatches .closeTab")
    func actionCloseTab() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([a, b])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        invoke(menu, title: "Close Tab")
        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [b.id])
    }

    @Test("Invoking 'Pin Tab' dispatches .setPinned(true)")
    func actionPin() {
        let a = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([a])
        let controller = DockController(root: leaf)
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)

        invoke(menu, title: "Pin Tab")
        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs[0].isPinned == true)
    }

    @Test("Reopen Closed Tab restores the previously closed tab")
    func actionReopen() {
        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leaf = DockLayoutNode.tabs([a, b])
        let controller = DockController(root: leaf)

        controller.apply(.closeTab(b.id))
        let menu = controller.defaultTabMenu(for: a.id, leafID: leaf.id)
        invoke(menu, title: "Reopen Closed Tab")

        guard case .tabs(_, let tabs, _) = controller.root else {
            Issue.record("expected tabs leaf"); return
        }
        #expect(tabs.map(\.id) == [a.id, b.id])
    }
}
