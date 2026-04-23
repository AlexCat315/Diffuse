import CoreGraphics
import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

/// Phase T — every DockAppearance geometry token must drive its primitive's
/// frame, with no leftover hardcoded `32` / `1` / `16` / `6` constants.
@Suite("Phase T DockAppearance wiring", .serialized)
@MainActor
struct DockAppearanceWiringTests: GuavaUIComposeSerializedSuite {

    /// Custom DockStyle that overrides every geometric token to a value
    /// distinguishable from the default (`tabBarHeight 32`, divider `1`,
    /// close `16`, satellite `24`).
    struct OversizedDockStyle: DockStyle {
        func resolve(_ config: DockStyleConfiguration) -> DockAppearance {
            let base = DefaultDockStyle().resolve(config)
            return DockAppearance(
                tabBarBackground: base.tabBarBackground,
                tabBarHeight: 48,
                tabHorizontalPadding: base.tabHorizontalPadding,
                tabHorizontalSpacing: base.tabHorizontalSpacing,
                tabVerticalPadding: base.tabVerticalPadding,
                tabActiveBackground: base.tabActiveBackground,
                tabActiveForeground: base.tabActiveForeground,
                tabInactiveForeground: base.tabInactiveForeground,
                tabActiveAccentBar: base.tabActiveAccentBar,
                tabActiveAccentBarHeight: base.tabActiveAccentBarHeight,
                closeButtonSize: 20,
                splitDividerThickness: 4,
                splitDividerColor: base.splitDividerColor,
                splitDividerHitSlop: 6,
                leafBackground: base.leafBackground,
                emptyLeafBackground: base.emptyLeafBackground,
                satelliteTitleBarHeight: 36
            )
        }
    }

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    /// Walk a node subtree, returning every node passing `predicate`.
    private func collect(_ root: Node,
                         _ predicate: (Node) -> Bool) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if predicate(n) { out.append(n) }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    @Test("Custom DockStyle drives tab strip + close-button + divider geometry")
    func tokensFlowIntoFrames() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tabA = DockTab(userKey: "a", title: "A", isClosable: true)
        let tabB = DockTab(userKey: "b", title: "B", isClosable: true)
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let split = DockLayoutNode.split(id: DockNodeID(),
                                          axis: .horizontal,
                                          fraction: 0.5,
                                          first: leafA,
                                          second: leafB)
        let controller = DockController(root: split)

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            DockContainer(controller: controller, content: makeContent())
                .dockStyle(OversizedDockStyle())
        )
        graph.computeLayout(width: 800, height: 400)
        let root = tree.root!

        // Tab strip: every node that backgrounds with `tabBarBackground`
        // and has a measurable height should be at the new 48pt height.
        let appearance = OversizedDockStyle().resolve(
            DockStyleConfiguration(theme: root.theme))
        let strips = collect(root) { n in
            n.backgroundColor == appearance.tabBarBackground
                && n.frame.width > 0 && n.frame.height > 0
        }
        #expect(!strips.isEmpty)
        for s in strips {
            #expect(abs(Float(s.frame.height) - 48) < 0.5,
                    "tab strip should respect tabBarHeight=48 (got \(s.frame.height))")
        }

        // Close button host: marker attachment uniquely identifies it.
        let closeHosts = collect(root) {
            $0.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] != nil
        }
        #expect(!closeHosts.isEmpty)
        for h in closeHosts {
            #expect(abs(Float(h.frame.width) - 20) < 0.5,
                    "close button width should be 20")
            #expect(abs(Float(h.frame.height) - 20) < 0.5,
                    "close button height should be 20")
        }

        // Resize handle: hit-pad width = thickness + 2 * hit slop = 4 + 12 = 16.
        let handles = collect(root) { $0.cursor == .resizeHorizontal }
        #expect(!handles.isEmpty)
        for h in handles {
            let total: Float = 4 + 6 * 2
            #expect(abs(Float(h.frame.width) - total) < 0.5,
                    "horizontal resize handle hit-pad width should be \(total)")
        }
    }}

    @Test("Default DockStyle preserves the legacy 32 / 1 / 16 / 24 sizes")
    func defaultsUnchanged() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "x", title: "X", isClosable: true)
        let controller = DockController(root: .tabs([tab]))

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 400, height: 300)
        let root = tree.root!

        let appearance = DefaultDockStyle().resolve(
            DockStyleConfiguration(theme: root.theme))
        let strips = collect(root) { n in
            n.backgroundColor == appearance.tabBarBackground && n.frame.height > 0
        }
        #expect(!strips.isEmpty)
        for s in strips {
            #expect(abs(Float(s.frame.height) - 32) < 0.5)
        }

        let closeHosts = collect(root) {
            $0.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] != nil
        }
        #expect(!closeHosts.isEmpty)
        for h in closeHosts {
            #expect(abs(Float(h.frame.width) - 16) < 0.5)
        }
    }}
}
