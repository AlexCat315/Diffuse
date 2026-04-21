import EngineKernel

/// Process-wide interaction registry holder. The active window context swaps
/// this before compose/materialise work and before event dispatch.
public enum InteractionRegistryHolder {
    nonisolated(unsafe) public static var current: InteractionRegistry?
}

/// Process-wide focus chain holder used by focus-aware primitives.
public enum FocusChainHolder {
    nonisolated(unsafe) public static var current: FocusChain?
}

/// Process-wide clipboard bridge.
public enum ClipboardHolder {
    nonisolated(unsafe) public static var read: (() -> String?)?
    nonisolated(unsafe) public static var write: ((String) -> Void)?
}

/// Process-wide pointer-capture holder used by drag-driven primitives.
public enum PointerCaptureHolder {
    nonisolated(unsafe) public static var current: PointerCapture?
}

/// Runtime services bound to one platform window.
public final class PlatformInputContext {
    public let interactions: InteractionRegistry
    public let focusChain: FocusChain
    public let pointerCapture: PointerCapture

    public init(interactions: InteractionRegistry = InteractionRegistry(),
                focusChain: FocusChain = FocusChain(),
                pointerCapture: PointerCapture = PointerCapture()) {
        self.interactions = interactions
        self.focusChain = focusChain
        self.pointerCapture = pointerCapture
    }

    @discardableResult
    public func withCurrent<R>(_ body: () throws -> R) rethrows -> R {
        let previousInteractions = InteractionRegistryHolder.current
        let previousFocus = FocusChainHolder.current
        let previousCapture = PointerCaptureHolder.current

        InteractionRegistryHolder.current = interactions
        FocusChainHolder.current = focusChain
        PointerCaptureHolder.current = pointerCapture
        defer {
            InteractionRegistryHolder.current = previousInteractions
            FocusChainHolder.current = previousFocus
            PointerCaptureHolder.current = previousCapture
        }

        return try body()
    }
}