import CoreGraphics
import Foundation

public struct PopoverOverlayEntry: Identifiable {
    public let id: UUID
    public var position: CGPoint
    public var width: Float?
    public var content: AnyView

    public init(id: UUID, position: CGPoint, width: Float?, content: AnyView) {
        self.id = id
        self.position = position
        self.width = width
        self.content = content
    }
}

public enum PopoverOverlayRegistry {
    nonisolated(unsafe) public static var entries: [PopoverOverlayEntry] = []

    public static func register(position: CGPoint,
                                width: Float?,
                                content: AnyView) -> UUID {
        let id = UUID()
        let entry = PopoverOverlayEntry(id: id,
                                        position: position,
                                        width: width,
                                        content: content)
        entries.removeAll(where: { $0.id == id })
        entries.append(entry)
        return id
    }

    public static func updatePosition(_ id: UUID, position: CGPoint) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].position = position
        }
    }

    public static func updateContent(_ id: UUID, content: AnyView) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].content = content
        }
    }

    public static func unregister(_ id: UUID) {
        entries.removeAll(where: { $0.id == id })
    }
}
