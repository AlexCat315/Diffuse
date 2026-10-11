import Foundation
import Testing
import GuavaUIComposeCore

@Suite("Capture cancellation")
struct CaptureCancellationTests {
    @Test("Transfer cancels the old owner once and exposes the new owner during cancellation")
    func transfer() {
        let capture = PointerCapture(), old = Node(), next = Node()
        var cancellations = 0
        old.attachments[PointerCaptureAttachmentKey.didLoseCapture] = {
            cancellations += 1
            #expect(capture.target === next)
        }
        capture.acquire(old); capture.acquire(old)
        #expect(cancellations == 0)
        capture.acquire(next)
        #expect(cancellations == 1)
        next.attachments[PointerCaptureAttachmentKey.didLoseCapture] = {
            cancellations += 1
            #expect(capture.target == nil)
        }
        capture.release(); capture.release()
        #expect(cancellations == 2)
    }

    @Test("Disabled ancestors reject stale captured and focused input across every route")
    func disabledAncestor() {
        let context = PlatformInputContext(), tree = NodeTree(), root = Node(), child = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        child.frame = root.frame; child.isFocusable = true
        root.addChild(child); tree.root = root
        let dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
            capture: context.pointerCapture, focusChain: context.focusChain)
        var delivered = 0, cancellations = 0
        child.attachments[PointerCaptureAttachmentKey.didLoseCapture] = { cancellations += 1 }
        context.interactions.setPointer(child) { _, _, _ in delivered += 1; return .handled }
        context.interactions.setKey(child, route: .shortcut) { _, _ in delivered += 1; return .handled }
        context.pointerCapture.acquire(child); context.focusChain.focus(child)
        root.allowsHitTesting = false
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1)))
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.space, keycode: 0, modifiers: [], isRepeat: false)))
        dispatcher.dispatch(.textInput("ignored"))
        #expect(delivered == 0 && cancellations == 1)
        #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
        root.allowsHitTesting = true
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1)))
        #expect(delivered == 1)
    }
}
