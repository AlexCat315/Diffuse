import CoreGraphics

public enum TooltipOverlayRegistry {
    nonisolated(unsafe) private static var draws: [(ObjectIdentifier, (DrawList) -> Void)] = []

    public static func register(_ node: Node, draw: @escaping (DrawList) -> Void) {
        let id = ObjectIdentifier(node)
        draws.removeAll(where: { $0.0 == id })
        draws.append((id, draw))
    }

    public static func unregister(_ node: Node) {
        let id = ObjectIdentifier(node)
        draws.removeAll(where: { $0.0 == id })
    }

    public static func contains(_ node: Node) -> Bool {
        let id = ObjectIdentifier(node)
        return draws.contains(where: { $0.0 == id })
    }

    public static func unregisterAll() {
        draws.removeAll()
    }

    public static func drawAll(into list: DrawList) {
        for (_, draw) in draws {
            draw(list)
        }
    }
}
