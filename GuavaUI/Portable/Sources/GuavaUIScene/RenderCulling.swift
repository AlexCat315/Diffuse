import GuavaUICore

enum RenderCulling {
    static func isOutside(_ rect: UIRect, list: DrawList) -> Bool {
        if let clip = list.currentClip, !intersects(rect, clip) { return true }
        if let viewport = list.viewportBounds, !intersects(rect, viewport) { return true }
        return false
    }

    static func bounds(of list: DrawList) -> UIRect? {
        guard let first = list.vertices.first else { return nil }
        var minX = first.posX, maxX = first.posX
        var minY = first.posY, maxY = first.posY
        for vertex in list.vertices.dropFirst() {
            minX = min(minX, vertex.posX); maxX = max(maxX, vertex.posX)
            minY = min(minY, vertex.posY); maxY = max(maxY, vertex.posY)
        }
        return UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func intersects(_ a: UIRect, _ b: UIRect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY
    }
}
