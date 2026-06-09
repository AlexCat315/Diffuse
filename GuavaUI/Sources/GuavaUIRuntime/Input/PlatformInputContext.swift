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

/// A per-window ambient owned by a higher layer (e.g. GuavaUICompose's portal
/// store, which cannot live in the runtime layer) that must be made "current"
/// exactly while this window's context is current. `PlatformInputContext`
/// activates it on `withCurrent` entry and runs the returned restore closure on
/// exit, so the higher-layer ambient is swapped in lockstep with the runtime
/// registries — there is no second, independently-managed global (坏味 #3).
public protocol ScopedAmbient: AnyObject {
    /// Make this ambient current; return a closure that restores the previous.
    func activate() -> () -> Void
}

/// Runtime input services bound to one platform window.
public typealias InputContext = PlatformInputContext

/// Runtime services bound to one platform window.
///
/// This is the per-window scope (规则 3): every registry the UI consults —
/// interactions, focus, pointer capture, the invalidation log, tooltip draws,
/// and (via `scopedAmbients`) the Compose-layer portal store — is owned here
/// and made current only for the duration of `withCurrent`. One window's state
/// can never pollute another's.
public final class PlatformInputContext {
    public let interactions: InteractionRegistry
    public let focusChain: FocusChain
    public let pointerCapture: PointerCapture
    /// Per-window invalidation log. Installed as the current log inside
    /// `withCurrent { ... }` so every `Node.markDirty` / `markRenderDirty`
    /// performed under that scope is attributed to this window.
    public let invalidationLog: InvalidationLog
    /// Per-window tooltip/overlay draw store.
    public let tooltips: TooltipStore

    /// Higher-layer ambients (e.g. the Compose portal store) swapped in lockstep
    /// with this context. Attach with `addScopedAmbient`.
    private var scopedAmbients: [ScopedAmbient] = []

    public init(interactions: InteractionRegistry = InteractionRegistry(),
                focusChain: FocusChain = FocusChain(),
                pointerCapture: PointerCapture = PointerCapture(),
                invalidationLog: InvalidationLog = InvalidationLog(),
                tooltips: TooltipStore = TooltipStore()) {
        self.interactions = interactions
        self.focusChain = focusChain
        self.pointerCapture = pointerCapture
        self.invalidationLog = invalidationLog
        self.tooltips = tooltips
    }

    /// Register a higher-layer ambient to be scoped with this context. Idempotent
    /// for identical objects.
    public func addScopedAmbient(_ ambient: ScopedAmbient) {
        if !scopedAmbients.contains(where: { $0 === ambient }) {
            scopedAmbients.append(ambient)
        }
    }

    @discardableResult
    public func withCurrent<R>(_ body: () throws -> R) rethrows -> R {
        let previousInteractions = InteractionRegistryHolder.current
        let previousFocus = FocusChainHolder.current
        let previousCapture = PointerCaptureHolder.current
        let previousLog = InvalidationLogHolder.current
        let previousTooltips = TooltipStoreHolder.current

        InteractionRegistryHolder.current = interactions
        FocusChainHolder.current = focusChain
        PointerCaptureHolder.current = pointerCapture
        InvalidationLogHolder.current = invalidationLog
        TooltipStoreHolder.current = tooltips

        let restores = scopedAmbients.map { $0.activate() }
        defer {
            for restore in restores.reversed() { restore() }
            InteractionRegistryHolder.current = previousInteractions
            FocusChainHolder.current = previousFocus
            PointerCaptureHolder.current = previousCapture
            InvalidationLogHolder.current = previousLog
            TooltipStoreHolder.current = previousTooltips
        }

        return try body()
    }
}
