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

public enum PortalRegistry {
    nonisolated(unsafe) private static var storage: [String: PortalEntry] = [:]
    nonisolated(unsafe) private static var observers: [UUID: (Int) -> Void] = [:]
    nonisolated(unsafe) private static var currentRevision: Int = 0

    public static var entries: [PortalEntry] {
        storage.values.sorted { $0.id < $1.id }
    }

    public static var revision: Int {
        currentRevision
    }

    @discardableResult
    public static func register(id: String = UUID().uuidString,
                                position: CGPoint,
                                width: Float? = nil,
                                content: AnyView) -> String {
        storage[id] = PortalEntry(id: id,
                                  position: position,
                                  width: width,
                                  content: content)
        notifyChanged()
        return id
    }

    public static func updatePosition(_ id: String, position: CGPoint) {
        guard var entry = storage[id] else { return }
        guard entry.position != position else { return }
        entry.position = position
        storage[id] = entry
        notifyChanged()
    }

    public static func updateContent(_ id: String, content: AnyView) {
        guard var entry = storage[id] else { return }
        entry.content = content
        storage[id] = entry
        notifyChanged()
    }

    /// Whether a live entry with `id` is currently registered. Used by the
    /// Popover overlay host to detect a stale id carried by a reused node.
    public static func contains(_ id: String) -> Bool {
        storage[id] != nil
    }

    public static func unregister(_ id: String) {
        guard storage.removeValue(forKey: id) != nil else { return }
        notifyChanged()
    }

    public static func clear() {
        guard !storage.isEmpty else { return }
        storage.removeAll()
        notifyChanged()
    }

    @discardableResult
    static func addObserver(_ observer: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    static func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private static func notifyChanged() {
        currentRevision &+= 1
        let revision = currentRevision
        for observer in observers.values {
            observer(revision)
        }
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
