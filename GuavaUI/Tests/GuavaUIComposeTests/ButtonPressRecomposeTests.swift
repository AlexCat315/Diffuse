import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Verifies that pointer-driven press transitions on a real `Button`
/// invalidate the owning scope (via `_StatefulButton`'s `@State`) and
/// recompose the styled body. Before this fix, `node.markDirty()` did not
/// re-run `_children(for:)`, so the visual state never changed in
/// production — even though `ButtonStyleAnimationTests` proved the styles
/// themselves transitioned correctly when driven by `@State` directly.
@Suite("Phase 8 / Button press recompose plumbing", .serialized)
struct ButtonPressRecomposeTests: GuavaUIComposeSerializedSuite {

    private func findFilled(_ root: Node) -> Node? {
        if let bg = root.backgroundColor, bg.a > 0 { return root }
        for c in root.children {
            if let n = findFilled(c) { return n }
        }
        return nil
    }

    private func buttonHost(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!.children.first!
    }

    @Test("Pointer down on Button recomposes body with isPressed=true")
    func pointerDownRecomposes() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let pressedColor = theme.colors.accentPressed

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: {}) { Text("Tap") }
            )

            // Resting state.
            let filled = findFilled(tree.root!)
            #expect(filled?.backgroundColor == resting)

            // Drive pointer down on the ButtonHost.
            let host = buttonHost(in: tree)
            let handler = registry.handlers(for: host).pointer
            #expect(handler != nil)
            let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
            _ = handler!(evt, .down, .target)

            // The State write enqueues an invalidation; flush it.
            recomp.commitAll()

            // Settle the implicit press animation to its terminal value so we
            // can assert against `pressedColor` deterministically.
            scheduler.tick(deltaTime: 1.0)

            let after = findFilled(tree.root!)
            #expect(after?.backgroundColor == pressedColor)

            // Release.
            _ = handler!(evt, .up, .target)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)

            let released = findFilled(tree.root!)
            #expect(released?.backgroundColor == resting)
        }
    } }

    @Test("Hover enter on Button recomposes body with isHovered=true")
    func hoverEnterRecomposes() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let hoveredColor = theme.colors.accentHover

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: {}) { Text("Hover") }
            )

            #expect(findFilled(tree.root!)?.backgroundColor == resting)

            let host = buttonHost(in: tree)
            let hover = registry.handlers(for: host).hover
            #expect(hover != nil)

            hover?(.enter)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == hoveredColor)

            hover?(.leave)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == resting)
        }
    } }

    @Test("Dragging outside a pressed Button clears pressed/hover and cancels release")
    func dragOutsideCancelsPress() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let capture = PointerCapture()
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let pressedColor = theme.colors.accentPressed

            var fired = 0
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: { fired += 1 }) { Text("Drag") }
            )

            let host = buttonHost(in: tree)
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 32)
            let handlers = registry.handlers(for: host)
            let pointer = handlers.pointer
            let motion = handlers.motion
            #expect(pointer != nil)
            #expect(motion != nil)

            let down = MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1)
            #expect(pointer?(down, .down, .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == pressedColor)
            #expect(capture.target === host)

            #expect(motion?(MouseMotionEvent(x: 140, y: 10, deltaX: 130, deltaY: 0), .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == resting)

            let upOutside = MouseButtonEvent(button: .left, x: 140, y: 10, clicks: 1)
            #expect(pointer?(upOutside, .up, .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == resting)
            #expect(fired == 0)
            #expect(capture.target == nil)
        }
    } }

    @Test("Dragging back inside a pressed Button restores press and commits on release")
    func dragBackInsideCommitsPress() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let capture = PointerCapture()
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let pressedColor = theme.colors.accentPressed

            var fired = 0
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: { fired += 1 }) { Text("Drag") }
            )

            let host = buttonHost(in: tree)
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 32)
            let handlers = registry.handlers(for: host)
            let pointer = handlers.pointer
            let motion = handlers.motion
            #expect(pointer != nil)
            #expect(motion != nil)

            #expect(pointer?(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)

            #expect(motion?(MouseMotionEvent(x: 140, y: 10, deltaX: 130, deltaY: 0), .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)

            #expect(motion?(MouseMotionEvent(x: 20, y: 10, deltaX: -120, deltaY: 0), .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == pressedColor)

            #expect(pointer?(MouseButtonEvent(button: .left, x: 20, y: 10, clicks: 1), .up, .target) == .handled)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(fired == 1)
            #expect(capture.target == nil)
        }
    } }
}
