#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

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
