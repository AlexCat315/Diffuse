#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

public struct PortalEntry: Identifiable {
    public let id: String
    public var position: CGPoint
    public var width: Float?
    public var content: AnyView

    public init(id: String,
                position: CGPoint,
                width: Float? = nil,
                content: AnyView) {
        self.id = id
        self.position = position
        self.width = width
        self.content = content
    }
}

/// Per-window store of overlay (popover/menu/tooltip) entries.
///
/// Phase 3 (坏味 #3): the storage moved off `PortalRegistry`'s process-global
/// `enum` statics into this instance so each window owns its own overlay layer —
/// one window's open dropdown can never paint into, or swallow clicks for,
/// another's. The legacy `PortalRegistry` static API is kept as a thin shim
/// forwarding to the current scope's store (see `PortalStoreHolder`), so every
/// existing call site is unchanged.
public final class PortalStore {
    private var storage: [String: PortalEntry] = [:]
    private var observers: [UUID: (Int) -> Void] = [:]
    private var currentRevision: Int = 0

    public init() {}

    public var entries: [PortalEntry] {
        storage.values.sorted { $0.id < $1.id }
    }

    public var revision: Int { currentRevision }

    @discardableResult
    public func register(id: String = UUID().uuidString,
                         position: CGPoint,
                         width: Float? = nil,
                         content: AnyView) -> String {
        storage[id] = PortalEntry(id: id, position: position, width: width, content: content)
        notifyChanged()
        return id
    }

    public func updatePosition(_ id: String, position: CGPoint) {
        guard var entry = storage[id] else { return }
        guard entry.position != position else { return }
        entry.position = position
        storage[id] = entry
        notifyChanged()
    }

    public func updateContent(_ id: String, content: AnyView) {
        guard var entry = storage[id] else { return }
        entry.content = content
        storage[id] = entry
        notifyChanged()
    }

    public func contains(_ id: String) -> Bool { storage[id] != nil }

    public func unregister(_ id: String) {
        guard storage.removeValue(forKey: id) != nil else { return }
        notifyChanged()
    }

    public func clear() {
        guard !storage.isEmpty else { return }
        storage.removeAll()
        notifyChanged()
    }

    @discardableResult
    func addObserver(_ observer: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyChanged() {
        currentRevision &+= 1
        let revision = currentRevision
        for observer in observers.values {
            observer(revision)
        }
    }
}

/// Holds the portal store made "current" by the active window's
/// `PlatformInputContext` (via `PortalStoreAmbient`). Defaults to a shared
/// instance so single-window hosts and tests that never install a scope keep
/// working unchanged.
public enum PortalStoreHolder {
    nonisolated(unsafe) public static let shared = PortalStore()
    /// Main-thread-only ambient: overlays are mutated only on the main thread,
    /// and the active store is swapped only inside `withCurrent`.
    nonisolated(unsafe) public static var current: PortalStore = shared
}

/// Adapts a per-window `PortalStore` to the runtime's `ScopedAmbient` hook so it
/// is swapped in lockstep with that window's input registries. Attach one to a
/// window's `PlatformInputContext` via `addScopedAmbient`.
public final class PortalStoreAmbient: ScopedAmbient {
    public let store: PortalStore
    public init(_ store: PortalStore) { self.store = store }
    public func activate() -> () -> Void {
        let previous = PortalStoreHolder.current
        PortalStoreHolder.current = store
        return { PortalStoreHolder.current = previous }
    }
}

/// Compatibility shim: forwards the legacy static API to the current scope's
/// `PortalStore`. Call sites (PortalHost, PortalResource) are unchanged; the
/// storage is now per-window.
public enum PortalRegistry {
    public static var entries: [PortalEntry] { PortalStoreHolder.current.entries }
    public static var revision: Int { PortalStoreHolder.current.revision }

    @discardableResult
    public static func register(id: String = UUID().uuidString,
                                position: CGPoint,
                                width: Float? = nil,
                                content: AnyView) -> String {
        PortalStoreHolder.current.register(id: id, position: position, width: width, content: content)
    }
    public static func updatePosition(_ id: String, position: CGPoint) {
        PortalStoreHolder.current.updatePosition(id, position: position)
    }
    public static func updateContent(_ id: String, content: AnyView) {
        PortalStoreHolder.current.updateContent(id, content: content)
    }
    public static func contains(_ id: String) -> Bool {
        PortalStoreHolder.current.contains(id)
    }
    public static func unregister(_ id: String) {
        PortalStoreHolder.current.unregister(id)
    }
    public static func clear() {
        PortalStoreHolder.current.clear()
    }
    @discardableResult
    static func addObserver(_ observer: @escaping (Int) -> Void) -> UUID {
        PortalStoreHolder.current.addObserver(observer)
    }
    static func removeObserver(_ id: UUID) {
        PortalStoreHolder.current.removeObserver(id)
    }
}

/// A `PortalRegistry` entry owned by the lifetime of the node that presents it
/// (坏味 #4). The overlay host attaches one in `_makeNode`; `present` registers
/// or updates the entry, and `unmount` — invoked by `Node.removeChild` when the
/// popover's subtree leaves the tree for ANY reason — unregisters it. Cleanup
/// no longer depends on a modifier side-effect running, so a torn-down-while-open
/// popover cannot leak a phantom overlay that swallows later clicks.
final class PortalResource: NodeResource {
    private(set) var entryID: String?

    func mount(node: Node) {}

    /// Idempotent: safe to call more than once during teardown.
    func unmount(node: Node) {
        if let id = entryID {
            PortalRegistry.unregister(id)
        }
        entryID = nil
    }

    /// Register the overlay entry, or update it in place if already live. Re-
    /// registers if a prior entry was unregistered (e.g. this resource's node
    /// was reused after a close), so the overlay reliably reappears.
    func present(position: CGPoint, width: Float?, content: AnyView) {
        if let id = entryID, PortalRegistry.contains(id) {
            PortalRegistry.updatePosition(id, position: position)
            PortalRegistry.updateContent(id, content: content)
        } else {
            entryID = PortalRegistry.register(position: position,
                                              width: width,
                                              content: content)
        }
    }
}
