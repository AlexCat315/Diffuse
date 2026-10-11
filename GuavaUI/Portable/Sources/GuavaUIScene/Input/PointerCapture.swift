import GuavaUICore
import Foundation

/// Tracks an explicit pointer-capture target.
///
/// When a node calls `acquire(_:)` during a `mouseButtonDown` handler, all
/// subsequent `mouseMotion` and `mouseButtonUp` events for that pointer go
/// directly to the captured node (skipping hit-test) until `release()`.
///
/// Phase 6.1 supports a single primary pointer. Multi-pointer / touch is
/// out of scope until touch input is added.
public final class PointerCapture {

    public private(set) var target: Node?

    public init() {}

    public var isActive: Bool { target != nil }

    public func acquire(_ node: Node) {
        guard target !== node else { return }
        let previous = target
        target = node
        (previous?.attachments[PointerCaptureAttachmentKey.didLoseCapture] as? () -> Void)?()
    }

    public func release() {
        let previous = target
        target = nil
        (previous?.attachments[PointerCaptureAttachmentKey.didLoseCapture] as? () -> Void)?()
    }
}

/// Controls can cancel a pending press when an ancestor gesture takes capture.
/// The callback must not acquire or release capture; the transfer is already complete.
public enum PointerCaptureAttachmentKey {
    public static let didLoseCapture = "__pointerCapture.didLoseCapture"
}
