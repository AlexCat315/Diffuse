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

    public static var entries: [PortalEntry] {
        storage.values.sorted { $0.id < $1.id }
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
        return id
    }

    public static func updatePosition(_ id: String, position: CGPoint) {
        guard var entry = storage[id] else { return }
        entry.position = position
        storage[id] = entry
    }

    public static func updateContent(_ id: String, content: AnyView) {
        guard var entry = storage[id] else { return }
        entry.content = content
        storage[id] = entry
    }

    public static func unregister(_ id: String) {
        storage.removeValue(forKey: id)
    }

    public static func clear() {
        storage.removeAll()
    }
}
