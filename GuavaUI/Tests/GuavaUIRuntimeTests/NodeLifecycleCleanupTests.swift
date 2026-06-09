import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
@testable import GuavaUIRuntime

/// Phase 6 acceptance: every node-keyed external registration is released by the
/// node lifecycle (规则 2 / 坏味 #4), with no ViewGraph teardown side-effect.
/// Removing a node from its parent releases its interaction handlers, tooltip
/// draw, pointer capture, and focus — for the whole departing subtree.
@Suite("Node-lifecycle cleanup (Phase 6)", .serialized)
struct NodeLifecycleCleanupTests {

    @Test("Interaction handler is removed when the node leaves the tree")
    func interactionHandlerReleasedOnRemoval() {
        let registry = InteractionRegistry()
        let saved = InteractionRegistryHolder.current
        InteractionRegistryHolder.current = registry
        defer { InteractionRegistryHolder.current = saved }

        let parent = Node()
        let child = Node()
        parent.addChild(child)
        registry.setPointer(child) { _, _, _ in .handled }
        #expect(registry.count == 1)

        parent.removeChild(child)
        #expect(registry.count == 0) // released by node lifecycle, not ViewGraph
    }

    @Test("Handler registered deep in a removed subtree is released")
    func interactionReleasedForSubtree() {
        let registry = InteractionRegistry()
        let saved = InteractionRegistryHolder.current
        InteractionRegistryHolder.current = registry
        defer { InteractionRegistryHolder.current = saved }

        let root = Node(); let mid = Node(); let leaf = Node()
        root.addChild(mid); mid.addChild(leaf)
        registry.setKey(leaf) { _, _ in .handled }
        #expect(registry.count == 1)

        root.removeChild(mid)
        #expect(registry.count == 0)
    }

    @Test("Tooltip draw is removed when the node leaves the tree")
    func tooltipReleasedOnRemoval() {
        let store = TooltipStore()
        let saved = TooltipStoreHolder.current
        TooltipStoreHolder.current = store
        defer { TooltipStoreHolder.current = saved }

        let parent = Node()
        let child = Node()
        parent.addChild(child)
        store.register(child) { _ in }
        #expect(store.contains(child))

        parent.removeChild(child)
        #expect(!store.contains(child))
    }

    @Test("Pointer capture is released when the captured node is torn down")
    func captureReleasedOnRemoval() {
        let capture = PointerCapture()
        let saved = PointerCaptureHolder.current
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = saved }

        let parent = Node()
        let child = Node()
        parent.addChild(child)
        capture.acquire(child)
        #expect(capture.target === child)

        // The captured node leaves the tree: capture must NOT keep pointing at a
        // detached node (the stuck-capture bug — every later event would route
        // to it).
        parent.removeChild(child)
        #expect(capture.target == nil)
    }

    @Test("Focus is cleared when the focused node is torn down")
    func focusClearedOnRemoval() {
        let focus = FocusChain()
        let saved = FocusChainHolder.current
        FocusChainHolder.current = focus
        defer { FocusChainHolder.current = saved }

        let parent = Node()
        let child = Node()
        child.isFocusable = true
        parent.addChild(child)
        focus.focus(child)
        #expect(focus.focused === child)

        parent.removeChild(child)
        #expect(focus.focused == nil)
    }

    @Test("Capture for a node that stays in the tree is untouched")
    func captureForRetainedNodeUntouched() {
        let capture = PointerCapture()
        let saved = PointerCaptureHolder.current
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = saved }

        let parent = Node()
        let a = Node(); let b = Node()
        parent.addChild(a); parent.addChild(b)
        capture.acquire(a)

        // Removing a *different* node must not disturb the capture.
        parent.removeChild(b)
        #expect(capture.target === a)
    }
}
