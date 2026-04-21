import Foundation

/// Logical texture identifier referenced from a draw batch.
///
/// `0` is reserved for "no texture" (solid color path in the shader).
/// Non-zero IDs map to textures registered with the renderer (e.g. font atlases).
public typealias TextureID = UInt32

public extension TextureID {
    /// Sentinel value used by solid-color quads.
    static let none: TextureID = 0
}

/// One contiguous draw call, all sharing the same texture and scissor rect.
public struct DrawBatch: Equatable {
    public var indexOffset: UInt32
    public var indexCount: UInt32
    public var textureID: TextureID
    /// `nil` means no scissor restriction (use the full viewport).
    public var scissor: UIRect?
}

/// CPU-side command buffer for the UI renderer.
///
/// The high-level API (`addRect`, `addRoundedRect`, `addText`, `pushClip`/`popClip`)
/// emits vertices and indices into shared arrays and merges adjacent draws when
/// they share the same texture and scissor.
public final class DrawList {

    public private(set) var vertices: [UIVertex] = []
    public private(set) var indices: [UInt32] = []
    public private(set) var batches: [DrawBatch] = []

    /// Stack of clip rectangles applied via `pushClip` / `popClip`.
    private var clipStack: [UIRect] = []

    public init() {}

    /// Reset all CPU buffers. Called at the start of each frame.
    public func reset() {
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        clipStack.removeAll(keepingCapacity: true)
    }

    // MARK: - Clipping

    /// Push a clip rectangle. Subsequent draws will be intersected with the
    /// current clip stack until `popClip()` is called.
    public func pushClip(_ rect: UIRect) {
        if let parent = clipStack.last {
            clipStack.append(intersect(parent, rect))
        } else {
            clipStack.append(rect)
        }
    }

    public func popClip() {
        guard !clipStack.isEmpty else { return }
        clipStack.removeLast()
    }

    public var currentClip: UIRect? { clipStack.last }

    // MARK: - Primitives

    /// Append a solid-color rectangle.
    public func addRect(_ rect: UIRect, color: Color) {
        let packed = color.rgba8
        // Sentinel uv (-1, 0) → solid color path in the shader.
        let v0 = UIVertex(posX: rect.minX, posY: rect.minY, u: -1, v: 0, color: packed)
        let v1 = UIVertex(posX: rect.maxX, posY: rect.minY, u: -1, v: 0, color: packed)
        let v2 = UIVertex(posX: rect.maxX, posY: rect.maxY, u: -1, v: 0, color: packed)
        let v3 = UIVertex(posX: rect.minX, posY: rect.maxY, u: -1, v: 0, color: packed)
        appendQuad(v0, v1, v2, v3, textureID: .none)
    }

    /// Append a rounded rectangle, decomposed into a centre quad, two edge quads
    /// and four corner triangle fans. Avoids any SDF work in the shader.
    public func addRoundedRect(_ rect: UIRect, radius: Float, color: Color) {
        let r = max(0, min(radius, min(rect.width, rect.height) * 0.5))
        guard r > 0 else {
            addRect(rect, color: color)
            return
        }
        emitRoundedRectGeometry(rect: rect, radius: r, color: color.rgba8)
    }

    /// Append a single textured quad from a font atlas glyph.
    public func addGlyphQuad(
        x: Float, y: Float, width: Float, height: Float,
        uvMinX: Float, uvMinY: Float, uvMaxX: Float, uvMaxY: Float,
        color: Color, textureID: TextureID
    ) {
        let packed = color.rgba8
        // Sentinel: u in [0, 1] means "sample alpha texture".
        let v0 = UIVertex(posX: x,         posY: y,          u: uvMinX, v: uvMinY, color: packed)
        let v1 = UIVertex(posX: x + width, posY: y,          u: uvMaxX, v: uvMinY, color: packed)
        let v2 = UIVertex(posX: x + width, posY: y + height, u: uvMaxX, v: uvMaxY, color: packed)
        let v3 = UIVertex(posX: x,         posY: y + height, u: uvMinX, v: uvMaxY, color: packed)
        appendQuad(v0, v1, v2, v3, textureID: textureID)
    }

    /// Append a single quad sourced from an RGBA color texture, tinted by
    /// `color`. Uv values are normalised (0..1); they get a +10 bias on the
    /// `u` channel so the shader takes the RGBA path instead of the alpha
    /// path. See `UIShader.wgsl` for the sentinel encoding.
    public func addImageQuad(
        rect: UIRect,
        textureID: TextureID,
        tint: Color = .white,
        uvMin: (x: Float, y: Float) = (0, 0),
        uvMax: (x: Float, y: Float) = (1, 1)
    ) {
        let packed = tint.rgba8
        let u0 = uvMin.x + 10
        let u1 = uvMax.x + 10
        let v0 = UIVertex(posX: rect.minX, posY: rect.minY, u: u0, v: uvMin.y, color: packed)
        let v1 = UIVertex(posX: rect.maxX, posY: rect.minY, u: u1, v: uvMin.y, color: packed)
        let v2 = UIVertex(posX: rect.maxX, posY: rect.maxY, u: u1, v: uvMax.y, color: packed)
        let v3 = UIVertex(posX: rect.minX, posY: rect.maxY, u: u0, v: uvMax.y, color: packed)
        appendQuad(v0, v1, v2, v3, textureID: textureID)
    }

    /// Append a rounded image quad using the same CPU tessellation strategy as
    /// `addRoundedRect`, with UVs derived from the original image rect.
    public func addRoundedImageQuad(
        rect: UIRect,
        radius: Float,
        textureID: TextureID,
        tint: Color = .white,
        uvMin: (x: Float, y: Float) = (0, 0),
        uvMax: (x: Float, y: Float) = (1, 1)
    ) {
        let r = max(0, min(radius, min(rect.width, rect.height) * 0.5))
        guard r > 0 else {
            addImageQuad(rect: rect,
                         textureID: textureID,
                         tint: tint,
                         uvMin: uvMin,
                         uvMax: uvMax)
            return
        }

        emitRoundedImageGeometry(
            rect: rect,
            radius: r,
            textureID: textureID,
            packedTint: tint.rgba8,
            uvMin: uvMin,
            uvMax: uvMax
        )
    }

    /// Append a fully laid-out text result. The atlas texture must be registered
    /// with the renderer under `textureID`.
    public func addText(
        _ layout: TextLayoutResult,
        origin: (x: Float, y: Float),
        color: Color,
        textureID: TextureID
    ) {
        for line in layout.lines {
            for glyph in line.glyphs {
                guard let info = glyph.atlasInfo, info.width > 0, info.height > 0 else { continue }
                let dx = origin.x + glyph.x + Float(info.bearingX)
                let dy = origin.y + glyph.y - Float(info.bearingY)
                addGlyphQuad(
                    x: dx, y: dy,
                    width: Float(info.width), height: Float(info.height),
                    uvMinX: info.uvMinX, uvMinY: info.uvMinY,
                    uvMaxX: info.uvMaxX, uvMaxY: info.uvMaxY,
                    color: color, textureID: textureID
                )
            }
        }
    }
    // MARK: - Internal

    private func appendQuad(_ v0: UIVertex, _ v1: UIVertex, _ v2: UIVertex, _ v3: UIVertex, textureID: TextureID) {
        let baseVertex = UInt32(vertices.count)
        vertices.append(v0)
        vertices.append(v1)
        vertices.append(v2)
        vertices.append(v3)
        let baseIndex = UInt32(indices.count)
        indices.append(baseVertex + 0)
        indices.append(baseVertex + 1)
        indices.append(baseVertex + 2)
        indices.append(baseVertex + 0)
        indices.append(baseVertex + 2)
        indices.append(baseVertex + 3)
        recordIndices(at: baseIndex, count: 6, textureID: textureID)
    }

    /// Record `count` indices starting at `baseIndex`, merging with the previous
    /// batch when texture and scissor match.
    private func recordIndices(at baseIndex: UInt32, count: UInt32, textureID: TextureID) {
        let scissor = clipStack.last
        if var last = batches.last,
           last.textureID == textureID,
           last.scissor == scissor,
           last.indexOffset + last.indexCount == baseIndex {
            last.indexCount += count
            batches[batches.count - 1] = last
        } else {
            batches.append(DrawBatch(
                indexOffset: baseIndex,
                indexCount: count,
                textureID: textureID,
                scissor: scissor
            ))
        }
    }

    /// Emit a rounded rectangle as a centre quad, four edge quads, and four
    /// triangle fans for the corners. Avoids needing an SDF in the shader.
    private func emitRoundedRectGeometry(rect: UIRect, radius r: Float, color packed: UInt32) {
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        // Centre rectangle (full vertical span, horizontally inset by r).
        emitSolidQuadRaw(x: x0 + r, y: y0, width: rect.width - 2 * r, height: rect.height, color: packed)
        // Left and right edge rectangles (inset vertically by r).
        emitSolidQuadRaw(x: x0,       y: y0 + r, width: r, height: rect.height - 2 * r, color: packed)
        emitSolidQuadRaw(x: x1 - r,   y: y0 + r, width: r, height: rect.height - 2 * r, color: packed)
        // Four corners as triangle fans.
        emitCornerFan(centerX: x0 + r, centerY: y0 + r, radius: r, startAngle: .pi,             color: packed)
        emitCornerFan(centerX: x1 - r, centerY: y0 + r, radius: r, startAngle: -.pi / 2,        color: packed)
        emitCornerFan(centerX: x1 - r, centerY: y1 - r, radius: r, startAngle: 0,               color: packed)
        emitCornerFan(centerX: x0 + r, centerY: y1 - r, radius: r, startAngle: .pi / 2,         color: packed)
    }

    private func emitRoundedImageGeometry(rect: UIRect,
                                          radius r: Float,
                                          textureID: TextureID,
                                          packedTint: UInt32,
                                          uvMin: (x: Float, y: Float),
                                          uvMax: (x: Float, y: Float)) {
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        emitTexturedQuadRaw(
            x: x0 + r,
            y: y0,
            width: rect.width - 2 * r,
            height: rect.height,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedQuadRaw(
            x: x0,
            y: y0 + r,
            width: r,
            height: rect.height - 2 * r,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedQuadRaw(
            x: x1 - r,
            y: y0 + r,
            width: r,
            height: rect.height - 2 * r,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedCornerFan(
            centerX: x0 + r,
            centerY: y0 + r,
            radius: r,
            startAngle: .pi,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedCornerFan(
            centerX: x1 - r,
            centerY: y0 + r,
            radius: r,
            startAngle: -.pi / 2,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedCornerFan(
            centerX: x1 - r,
            centerY: y1 - r,
            radius: r,
            startAngle: 0,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
        emitTexturedCornerFan(
            centerX: x0 + r,
            centerY: y1 - r,
            radius: r,
            startAngle: .pi / 2,
            sourceRect: rect,
            packedTint: packedTint,
            textureID: textureID,
            uvMin: uvMin,
            uvMax: uvMax
        )
    }

    private func emitSolidQuadRaw(x: Float, y: Float, width: Float, height: Float, color packed: UInt32) {
        guard width > 0, height > 0 else { return }
        let v0 = UIVertex(posX: x,         posY: y,          u: -1, v: 0, color: packed)
        let v1 = UIVertex(posX: x + width, posY: y,          u: -1, v: 0, color: packed)
        let v2 = UIVertex(posX: x + width, posY: y + height, u: -1, v: 0, color: packed)
        let v3 = UIVertex(posX: x,         posY: y + height, u: -1, v: 0, color: packed)
        appendQuad(v0, v1, v2, v3, textureID: .none)
    }

    private func emitTexturedQuadRaw(x: Float,
                                     y: Float,
                                     width: Float,
                                     height: Float,
                                     sourceRect: UIRect,
                                     packedTint: UInt32,
                                     textureID: TextureID,
                                     uvMin: (x: Float, y: Float),
                                     uvMax: (x: Float, y: Float)) {
        guard width > 0, height > 0 else { return }
        let v0 = makeImageVertex(x: x,         y: y,          sourceRect: sourceRect, packedTint: packedTint, uvMin: uvMin, uvMax: uvMax)
        let v1 = makeImageVertex(x: x + width, y: y,          sourceRect: sourceRect, packedTint: packedTint, uvMin: uvMin, uvMax: uvMax)
        let v2 = makeImageVertex(x: x + width, y: y + height, sourceRect: sourceRect, packedTint: packedTint, uvMin: uvMin, uvMax: uvMax)
        let v3 = makeImageVertex(x: x,         y: y + height, sourceRect: sourceRect, packedTint: packedTint, uvMin: uvMin, uvMax: uvMax)
        appendQuad(v0, v1, v2, v3, textureID: textureID)
    }

    private func emitCornerFan(centerX: Float, centerY: Float, radius r: Float,
                               startAngle: Float, color packed: UInt32) {
        let segmentCount = 8
        let baseVertex = UInt32(vertices.count)
        let baseIndex = UInt32(indices.count)
        // Centre vertex.
        vertices.append(UIVertex(posX: centerX, posY: centerY, u: -1, v: 0, color: packed))
        // Arc vertices.
        for i in 0...segmentCount {
            let t = Float(i) / Float(segmentCount)
            let angle = startAngle + t * (.pi / 2)
            let vx = centerX + cos(angle) * r
            let vy = centerY + sin(angle) * r
            vertices.append(UIVertex(posX: vx, posY: vy, u: -1, v: 0, color: packed))
        }
        // Triangle indices: (centre, i, i+1).
        for i in 0..<UInt32(segmentCount) {
            indices.append(baseVertex)
            indices.append(baseVertex + 1 + i)
            indices.append(baseVertex + 2 + i)
        }
        recordIndices(at: baseIndex, count: UInt32(segmentCount) * 3, textureID: .none)
    }

    private func emitTexturedCornerFan(centerX: Float,
                                       centerY: Float,
                                       radius r: Float,
                                       startAngle: Float,
                                       sourceRect: UIRect,
                                       packedTint: UInt32,
                                       textureID: TextureID,
                                       uvMin: (x: Float, y: Float),
                                       uvMax: (x: Float, y: Float)) {
        let segmentCount = 8
        let baseVertex = UInt32(vertices.count)
        let baseIndex = UInt32(indices.count)

        vertices.append(makeImageVertex(
            x: centerX,
            y: centerY,
            sourceRect: sourceRect,
            packedTint: packedTint,
            uvMin: uvMin,
            uvMax: uvMax
        ))

        for i in 0...segmentCount {
            let t = Float(i) / Float(segmentCount)
            let angle = startAngle + t * (.pi / 2)
            let vx = centerX + cos(angle) * r
            let vy = centerY + sin(angle) * r
            vertices.append(makeImageVertex(
                x: vx,
                y: vy,
                sourceRect: sourceRect,
                packedTint: packedTint,
                uvMin: uvMin,
                uvMax: uvMax
            ))
        }

        for i in 0..<UInt32(segmentCount) {
            indices.append(baseVertex)
            indices.append(baseVertex + 1 + i)
            indices.append(baseVertex + 2 + i)
        }
        recordIndices(at: baseIndex, count: UInt32(segmentCount) * 3, textureID: textureID)
    }

    private func makeImageVertex(x: Float,
                                 y: Float,
                                 sourceRect: UIRect,
                                 packedTint: UInt32,
                                 uvMin: (x: Float, y: Float),
                                 uvMax: (x: Float, y: Float)) -> UIVertex {
        let uScale = sourceRect.width > 0 ? (x - sourceRect.minX) / sourceRect.width : 0
        let vScale = sourceRect.height > 0 ? (y - sourceRect.minY) / sourceRect.height : 0
        let u = uvMin.x + (uvMax.x - uvMin.x) * uScale + 10
        let v = uvMin.y + (uvMax.y - uvMin.y) * vScale
        return UIVertex(posX: x, posY: y, u: u, v: v, color: packedTint)
    }
}

// MARK: - Helpers

private func intersect(_ a: UIRect, _ b: UIRect) -> UIRect {
    let minX = max(a.minX, b.minX)
    let minY = max(a.minY, b.minY)
    let maxX = min(a.maxX, b.maxX)
    let maxY = min(a.maxY, b.maxY)
    return UIRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
}
