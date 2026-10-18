import GuavaUICore
import Foundation

/// Tracks an explicit pointer-capture target.
///
/// When a node calls `acquire(_:)` during a `mouseButtonDown` handler, all
/// subsequent `mouseMotion` and `mouseButtonUp` events for that pointer go
/// directly to the captured node (skipping hit-test) until `release()`.
///
/// Touch surfaces use this same primary-pointer dispatcher. Simultaneous
/// multi-pointer capture is not supported.
public final class PointerCapture {

    public private(set) var target: Node?
    /// A pending tap may yield to an ancestor scroll gesture; a slider or
    /// resize drag keeps exclusive capture unless it explicitly opts in.
    private(set) var allowsGestureTransfer = false

    public init() {}

    public var isActive: Bool { target != nil }

    public func acquire(_ node: Node, allowsGestureTransfer: Bool = false) {
        guard target !== node else { self.allowsGestureTransfer = allowsGestureTransfer; return }
        let previous = target
        target = node
        self.allowsGestureTransfer = allowsGestureTransfer
        (previous?.attachments[PointerCaptureAttachmentKey.didLoseCapture] as? () -> Void)?()
    }

    public func release() {
        let previous = target
        target = nil
        allowsGestureTransfer = false
        (previous?.attachments[PointerCaptureAttachmentKey.didLoseCapture] as? () -> Void)?()
    }
}

/// Controls can cancel a pending press when an ancestor gesture takes capture.
/// The callback must not acquire or release capture; the transfer is already complete.
public enum PointerCaptureAttachmentKey {
    public static let didLoseCapture = "__pointerCapture.didLoseCapture"
}
