public import Foundation
public import GuavaUICore

/// Custom painters use layout lengths. Resolve their geometry and local clips
/// into the same scaled space as the node's surface, without changing layout.
func paintScaled(_ painter: (DrawList, CGPoint) -> Void, into list: DrawList, origin: CGPoint, scale: Float) {
    guard scale != 1 else { painter(list, origin); return }
    guard scale > 0, scale.isFinite else { return }
    let x = Float(origin.x), y = Float(origin.y)
    func resolve(_ rect: UIRect, factor: Float) -> UIRect {
        UIRect(x: x + (rect.x - x) * factor, y: y + (rect.y - y) * factor,
               width: rect.width * factor, height: rect.height * factor)
    }
    let local = DrawList()
    local.pixelScale = list.pixelScale * scale
    local.setViewportBounds(list.viewportBounds.map { resolve($0, factor: 1 / scale) })
    if let clip = list.currentClip { local.pushClip(resolve(clip, factor: 1 / scale)) }
    painter(local, origin)
    let vertices = local.vertices.map { vertex in
        var result = vertex
        result.posX = x + (vertex.posX - x) * scale
        result.posY = y + (vertex.posY - y) * scale
        return result
    }
    let batches = local.batches.map { batch in
        var result = batch
        result.scissor = batch.scissor.map { resolve($0, factor: scale) }
        result.backdrop = batch.backdrop.map {
            UIBackdrop(rect: resolve($0.rect, factor: scale), cornerRadius: $0.cornerRadius * scale,
                       blurRadius: $0.blurRadius * scale, opacity: $0.opacity)
        }
        return result
    }
    local.load(vertices: vertices, indices: local.indices, batches: batches, resources: local.resources)
    list.append(local)
}
