#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Per-window store of tooltip/overlay draws, keyed by the owning node.
///
/// Phase 3 (坏味 #3): the storage moved off a process-global `enum` static into
/// this instance so each window's `PlatformInputContext` owns its own — one
/// window's hovering tooltip can never paint into another's. The legacy
/// `TooltipOverlayRegistry` static API is preserved as a thin shim forwarding
/// to the current context's store.
public final class TooltipStore {
    private var draws: [(ObjectIdentifier, (DrawList) -> Void)] = []

    public init() {}

    public func register(_ node: Node, draw: @escaping (DrawList) -> Void) {
        let id = ObjectIdentifier(node)
        draws.removeAll(where: { $0.0 == id })
        draws.append((id, draw))
    }

    public func unregister(_ node: Node) {
        let id = ObjectIdentifier(node)
        draws.removeAll(where: { $0.0 == id })
    }

    public func contains(_ node: Node) -> Bool {
        let id = ObjectIdentifier(node)
        return draws.contains(where: { $0.0 == id })
    }

    public func unregisterAll() {
        draws.removeAll()
    }

    public func drawAll(into list: DrawList) {
        for (_, draw) in draws {
            draw(list)
        }
    }
}

/// Holds the tooltip store made "current" by `PlatformInputContext.withCurrent`.
/// Defaults to a shared instance so single-window hosts and tests that never
/// install a context keep working unchanged.
public enum TooltipStoreHolder {
    nonisolated(unsafe) public static let shared = TooltipStore()
    /// Main-thread-only ambient: the UI tree is single-threaded, so the active
    /// store is swapped only on the main thread inside `withCurrent`.
    nonisolated(unsafe) public static var current: TooltipStore = shared
}

/// Compatibility shim: forwards the legacy static API to the current scope's
/// `TooltipStore`. Call sites are unchanged; storage is now per-window.
public enum TooltipOverlayRegistry {
    public static func register(_ node: Node, draw: @escaping (DrawList) -> Void) {
        TooltipStoreHolder.current.register(node, draw: draw)
    }
    public static func unregister(_ node: Node) {
        TooltipStoreHolder.current.unregister(node)
    }
    public static func contains(_ node: Node) -> Bool {
        TooltipStoreHolder.current.contains(node)
    }
    public static func unregisterAll() {
        TooltipStoreHolder.current.unregisterAll()
    }
    public static func drawAll(into list: DrawList) {
        TooltipStoreHolder.current.drawAll(into: list)
    }
}
