#if os(Android)
import Android
#endif
import Foundation

/// Logical texture identifier referenced from a draw batch.
///
/// `0` is reserved for "no texture" (solid color path in the shader).
/// Non-zero IDs map to textures registered with the renderer (e.g. font atlases).
public typealias TextureID = UInt32

public extension TextureID {
    /// Sentinel value used by solid-color quads.
    static let none: TextureID = 0
    /// The high bit is reserved for a font atlas's color plane. Application
    /// image IDs and alpha atlas IDs must remain below this bit.
    var colorGlyphAtlasID: TextureID {
        precondition(self > 0 && self < 0x8000_0000)
        return self | 0x8000_0000
    }
}

/// A frosted backdrop: the renderer blurs whatever was already drawn inside
/// `rect` and composites the result underneath the batch this is attached to.
///
/// This is a *request*, not a guarantee. A renderer without an offscreen pass
/// (without a backdrop program) ignores it, so the fill above it must stay legible on its
/// own.
public struct UIBackdrop: Equatable, Sendable {
    /// Region to blur, in logical points. Usually the panel's own box.
    public var rect: UIRect
    /// Corner radius of the composite, matching the fill above it.
    public var cornerRadius: Float
    /// Gaussian radius in logical points.
    public var blurRadius: Float
    /// Composite strength, independent of the material fill's alpha.
    public var opacity: Float

    public init(rect: UIRect, cornerRadius: Float = 0, blurRadius: Float = 12, opacity: Float = 1) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.blurRadius = blurRadius
        self.opacity = opacity
    }
}

/// One contiguous draw call, all sharing the same texture and scissor rect.
public struct DrawBatch: Equatable, Sendable {
    public var indexOffset: UInt32
    public var indexCount: UInt32
    public var textureID: TextureID
    /// `nil` means no scissor restriction (use the full viewport).
    public var scissor: UIRect?
    /// Blur the frame behind this batch before drawing it. Attached to the
    /// first primitive of a frosted panel so the renderer can insert the
    /// offscreen pass exactly where the panel's fill starts.
    public var backdrop: UIBackdrop? = nil
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
    public private(set) var resources = DrawListResources()

    /// Physical pixels per logical point, set by the renderer from the viewport
    /// before anything is drawn.
    ///
    /// Edges are rounded to this grid. An edge landing *between* two pixels is
    /// rasterised as two half-covered pixels, and that is what makes a 1pt
    /// border read as a smudge instead of a line — worse on a 2x display, where
    /// a centred layout puts nearly every edge on a half pixel. Zero (the
    /// default, and what an offscreen test sees) leaves coordinates alone.
    public var pixelScale: Float = 0

    /// Stack of clip rectangles applied via `pushClip` / `popClip`.
    private var clipStack: [UIRect] = []
    /// Rounded content masks applied to geometry on the CPU (`pushMask`).
    private var masks: [UIRoundedRect] = []
    /// Outlines for `masks`, tessellated once per push.
    private var maskOutlines: [[(x: Float, y: Float)]] = []
    public private(set) var viewportBounds: UIRect?
    /// Backdrop awaiting the next emitted primitive. Consumed by
    /// `recordIndices`, which also starts a fresh batch for it.
    private var pendingBackdrop: UIBackdrop?
    /// Compositing request for the whole frame, or nil. Unlike a backdrop this
    /// is not geometry: it is read once by the renderer before anything is drawn.
    public private(set) var reveal: UIReveal?

    public init() {}

    /// Reset all CPU buffers. Called at the start of each frame.
    public func reset() {
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        resources.reset()
        clipStack.removeAll(keepingCapacity: true)
        masks.removeAll(keepingCapacity: true)
        maskOutlines.removeAll(keepingCapacity: true)
        pendingBackdrop = nil
        viewportBounds = nil
        reveal = nil
    }

    /// Retain the frame already on screen and show this one through a circle.
    /// The last request of a frame wins; two nodes asking at once would have to
    /// agree on a centre, which is exactly the case where neither is right.
    public func beginReveal(_ reveal: UIReveal) {
        self.reveal = reveal
    }

    /// Attach a frosted backdrop to the geometry emitted immediately next.
    ///
    /// The caller must emit that geometry right away: the request is consumed
    /// by the very next primitive, and it forces that primitive into its own
    /// batch so the renderer can insert the offscreen blur before it — and
    /// before nothing else.
    public func beginBackdrop(_ backdrop: UIBackdrop) {
        pendingBackdrop = backdrop
    }

    public func setViewportBounds(_ bounds: UIRect?) {
        viewportBounds = bounds
    }

    /// Fade a completed subtree. The UI shader consumes straight RGBA tints,
    /// so only alpha changes; RGB must retain its original brightness.
    public func multiplyOpacity(_ opacity: Float, fromVertex start: Int) {
        multiplyOpacity(fromVertexIndex: start, by: opacity)
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

    /// Push a container clip: its scissor and, when rounded, its content mask.
    public func pushClip(_ clip: UIClip) {
        pushClip(clip.rect)
        if let mask = clip.mask { pushMask(mask) }
    }

    public func popClip(_ clip: UIClip) {
        if clip.mask != nil { popMask() }
        popClip()
    }

    /// Cut subsequent geometry to a rounded rectangle. Scissors stay
    /// rectangular; triangles reaching outside the mask's straight interior
    /// are clipped against its outline, so rounded containers keep children
    /// inside their corners on every backend.
    public func pushMask(_ mask: UIRoundedRect) {
        guard mask.radius > 0 else { masks.append(mask); maskOutlines.append([]); return }
        masks.append(mask)
        maskOutlines.append(mask.outline(segments: cornerSegmentCount(for: mask.radius)))
    }

    public func popMask() {
        guard !masks.isEmpty else { return }
        masks.removeLast(); maskOutlines.removeLast()
    }

    public var currentMasks: [UIRoundedRect] { masks }

    /// Apply a container's alpha to descendant geometry, including cached
    /// child layers. Local painters already apply their own node's opacity.
    public func multiplyOpacity(fromVertexIndex start: Int, by opacity: Float) {
        let alpha = max(0, min(1, opacity))
        guard alpha < 1 else { return }
        for index in start..<vertices.count {
            let packed = vertices[index].color
            let next = UInt32((Float(packed >> 24) * alpha).rounded())
            vertices[index].color = (packed & 0x00FF_FFFF) | (next << 24)
        }
        // Frost is a separate composite pass, so fading only the panel's
        // vertices leaves a fully opaque glass plate behind its content.
        for index in batches.indices {
            guard var backdrop = batches[index].backdrop,
                  Int(indices[Int(batches[index].indexOffset)]) >= start else { continue }
            backdrop.opacity *= alpha
            batches[index].backdrop = backdrop
        }
    }

    /// Replace the color of vertices appended since `start`. The closure receives
    /// each position and its existing coverage (alpha), so anti-aliased fringes
    /// keep fading out under the new color.
    func recolor(from start: Int, _ color: (_ x: Float, _ y: Float, _ coverage: Float) -> Color) {
        for index in start..<vertices.count {
            let vertex = vertices[index]
            vertices[index].color = color(vertex.posX, vertex.posY, Float(vertex.color >> 24) / 255).rgba8
        }
    }

    /// Keep ownership with this geometry, including cached layer composites.
    public func retainResource(_ resource: any AnyObject & Sendable) { resources.retain(resource) }

    // MARK: - Snapshot restore

    /// Replace the draw list contents with pre-built data from a `DrawListSnapshot`.
    /// Used by the render thread to reconstruct a frame without re-walking the node tree.
    public func load(vertices: [UIVertex], indices: [UInt32], batches: [DrawBatch], resources: DrawListResources = .init()) {
        self.vertices = vertices
        self.indices = indices
        self.batches = batches
        self.resources = resources
        clipStack.removeAll(keepingCapacity: true)
        masks.removeAll(keepingCapacity: true)
        maskOutlines.removeAll(keepingCapacity: true)
        viewportBounds = nil
        reveal = nil
    }

    // MARK: - Composite (Phase 4b)

    /// Append every vertex/index/batch from `other` into this list, shifting
    /// vertex indices and batch index-offsets so the merged buffer stays
    /// internally consistent. The caller owns the responsibility for
    /// `other`'s coordinate system: `other.vertices` must already be in the
    /// same absolute space `self` expects.
    public func append(_ other: DrawList) {
        append(other, vertexTranslationX: 0, vertexTranslationY: 0)
    }

    /// Append cached geometry at a new absolute origin while preserving its
    /// existing scissor rectangles. This is used for unclipped leaf layers
    /// moving beneath an unchanged parent clip, such as text while scrolling.
    /// The caller must ensure every scissor comes from the stationary parent.
    public func append(_ other: DrawList,
                vertexTranslationX: Float,
                vertexTranslationY: Float) {
        let firstBatch = batches.count
        appendUnmasked(other, vertexTranslationX: vertexTranslationX, vertexTranslationY: vertexTranslationY)
        // Cached layers and scaled painters reach the frame through here, so
        // an enclosing rounded container still cuts their corners.
        if masks.contains(where: { $0.radius > 0 }) { maskBatches(from: firstBatch) }
    }

    /// Re-index appended batches after clipping them to the active masks.
    private func maskBatches(from first: Int) {
        guard first < batches.count else { return }
        let indexStart = Int(batches[first].indexOffset)
        let original = Array(indices[indexStart...])
        indices.removeSubrange(indexStart...)
        var offset = UInt32(indexStart)
        for batch in first..<batches.count {
            let local = Int(batches[batch].indexOffset) - indexStart
            let before = UInt32(indices.count)
            indices.append(contentsOf: original[local..<(local + Int(batches[batch].indexCount))])
            let count = applyMasks(from: before, count: batches[batch].indexCount)
            batches[batch].indexOffset = offset
            batches[batch].indexCount = count
            offset += count
        }
    }

    private func appendUnmasked(_ other: DrawList,
                                vertexTranslationX: Float,
                                vertexTranslationY: Float) {
        resources.append(other.resources)
        // A reveal describes the whole frame, so it travels with the geometry
        // into the frame list even when the node that raised it was recorded
        // into a layer cache. A layer replays its cached request for as long as
        // it stays clean, which is why the raise site must clear it the moment
        // the run ends rather than leaving a finished disc behind.
        if let reveal = other.reveal { self.reveal = reveal }
        if vertices.isEmpty,
           indices.isEmpty,
           batches.isEmpty,
           vertexTranslationX == 0,
           vertexTranslationY == 0 {
            // Swift arrays are copy-on-write. A stable root layer can lend its
            // buffers to the per-frame DrawList in O(1); appending a tooltip or
            // another overlay later detaches the destination automatically.
            vertices = other.vertices
            indices = other.indices
            batches = other.batches
            return
        }

        let baseVertex = UInt32(vertices.count)
        let baseIndex = UInt32(indices.count)
        if vertexTranslationX == 0, vertexTranslationY == 0 {
            vertices.append(contentsOf: other.vertices)
        } else {
            vertices.reserveCapacity(vertices.count + other.vertices.count)
            for var vertex in other.vertices {
                vertex.posX += vertexTranslationX
                vertex.posY += vertexTranslationY
                vertices.append(vertex)
            }
        }
        appendIndices(other.indices, adding: baseVertex)
        if baseIndex == 0 {
            batches.append(contentsOf: other.batches)
        } else {
            batches.reserveCapacity(batches.count + other.batches.count)
            for b in other.batches {
                batches.append(DrawBatch(
                    indexOffset: b.indexOffset + baseIndex,
                    indexCount: b.indexCount,
                    textureID: b.textureID,
                    scissor: b.scissor,
                    backdrop: b.backdrop
                ))
            }
        }
    }

    /// Bulk-copy cached indices, then offset them in SIMD-sized chunks. This
    /// preserves the renderer's proven flat-index contract while avoiding the
    /// per-element Array append loop that dominates Debug scrolling profiles.
    private func appendIndices(_ source: [UInt32], adding offset: UInt32) {
        guard !source.isEmpty else { return }
        let start = indices.count
        indices.append(contentsOf: source)
        guard offset != 0 else { return }

        let end = indices.count
        let lanes = 16
        let delta = SIMD16<UInt32>(repeating: offset)
        indices.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = start
            while index + lanes <= end {
                let pointer = base.advanced(by: index)
                let values = UnsafeRawPointer(pointer)
                    .loadUnaligned(as: SIMD16<UInt32>.self)
                UnsafeMutableRawPointer(pointer)
                    .storeBytes(of: values &+ delta, as: SIMD16<UInt32>.self)
                index += lanes
            }
            while index < end {
                buffer[index] &+= offset
                index += 1
            }
        }
    }

    // MARK: - Primitives

    /// Append a solid-color rectangle.
    public func addRect(_ rect: UIRect, color: Color) {
        let rect = snapped(rect)
        let packed = color.rgba8
        // Sentinel uv (-1, 0) → solid color path in the shader.
        let v0 = UIVertex(posX: rect.minX, posY: rect.minY, u: -1, v: 0, color: packed)
        let v1 = UIVertex(posX: rect.maxX, posY: rect.minY, u: -1, v: 0, color: packed)
        let v2 = UIVertex(posX: rect.maxX, posY: rect.maxY, u: -1, v: 0, color: packed)
        let v3 = UIVertex(posX: rect.minX, posY: rect.maxY, u: -1, v: 0, color: packed)
        appendQuad(v0, v1, v2, v3, textureID: .none)
    }

    /// Append a convex rounded fill with a one-physical-pixel coverage edge.
    /// The interior and fringe do not overlap, including for translucent fills.
    public func addRoundedRect(_ rect: UIRect, radius: Float, color: Color) {
        let rect = snapped(rect)
        let r = max(0, min(radius, min(rect.width, rect.height) * 0.5))
        guard r > 0 else {
            addRect(rect, color: color)
            return
        }
        emitRoundedRectGeometry(rect: rect, radius: r, color: color.rgba8)
    }

    /// An inset stroke whose center stays transparent. Drawing a filled shape
    /// underneath the background is incorrect for translucent/clear controls.
    public func addRoundedRectStroke(_ rect: UIRect, radius: Float, width: Float, color: Color) {
        guard rect.width > 0, rect.height > 0, width > 0, color.a > 0 else { return }
        let rect = snapped(rect)
        let stroke = min(width, min(rect.width, rect.height) * 0.5)
        let outerRadius = max(0, min(radius, min(rect.width, rect.height) * 0.5))
        let inner = UIRect(x: rect.minX + stroke, y: rect.minY + stroke,
                           width: rect.width - stroke * 2, height: rect.height - stroke * 2)
        guard inner.width > 0, inner.height > 0 else {
            addRoundedRect(rect, radius: outerRadius, color: color)
            return
        }
        let innerRadius = max(0, outerRadius - stroke)
        let segments = outerRadius > 0 ? cornerSegmentCount(for: outerRadius) : 1
        let packed = color.rgba8
        let baseVertex = UInt32(vertices.count)
        let baseIndex = UInt32(indices.count)
        // Clockwise corners, each with matching outer/inner arc samples.
        for corner in 0..<4 {
            let right = corner == 1 || corner == 2
            let bottom = corner >= 2
            let outerX = right ? rect.maxX - outerRadius : rect.minX + outerRadius
            let outerY = bottom ? rect.maxY - outerRadius : rect.minY + outerRadius
            let innerX = right ? inner.maxX - innerRadius : inner.minX + innerRadius
            let innerY = bottom ? inner.maxY - innerRadius : inner.minY + innerRadius
            let start = Float(corner) * .pi / 2 + .pi
            for step in 0...segments {
                let angle = start + Float(step) / Float(segments) * .pi / 2
                vertices.append(UIVertex(posX: outerX + cos(angle) * outerRadius,
                                         posY: outerY + sin(angle) * outerRadius,
                                         u: -1, v: 0, color: packed))
                vertices.append(UIVertex(posX: innerX + cos(angle) * innerRadius,
                                         posY: innerY + sin(angle) * innerRadius,
                                         u: -1, v: 0, color: packed))
            }
        }
        let pairs = UInt32(4 * (segments + 1))
        for pair in 0..<pairs {
            let a = baseVertex + pair * 2
            let b = baseVertex + ((pair + 1) % pairs) * 2
            indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
        }
        recordIndices(at: baseIndex, count: pairs * 6, textureID: .none)
    }

    /// Append a single textured quad from a font atlas glyph.
    public func addAtlasGlyph(_ info: GlyphAtlasInfo, x: Float, y: Float, color: Color, textureID: TextureID) {
        if info.format == .color {
            addImageQuad(rect: UIRect(x: x, y: y, width: info.width, height: info.height),
                textureID: textureID.colorGlyphAtlasID, tint: Color(r: 1, g: 1, b: 1, a: color.a),
                uvMin: (info.uvMinX, info.uvMinY), uvMax: (info.uvMaxX, info.uvMaxY))
        } else {
            addGlyphQuad(x: x, y: y, width: info.width, height: info.height,
                uvMinX: info.uvMinX, uvMinY: info.uvMinY, uvMaxX: info.uvMaxX, uvMaxY: info.uvMaxY,
                color: color, textureID: textureID)
        }
    }

    /// Append a single textured quad from an alpha font atlas glyph.
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

    /// Clamp linear sampling to a cropped image's texel centers. Nine adjoining
    /// quads preserve the original mapping in the interior and hold UVs at the
    /// edges, preventing unused texture padding from bleeding into an upscale.
    /// The quads merge into one batch and retain the ordinary packed vertex ABI.
    public func addClampedImageQuad(
        rect: UIRect, textureID: TextureID, texelSize: (x: Float, y: Float),
        tint: Color = .white, uvMin: (x: Float, y: Float) = (0, 0), uvMax: (x: Float, y: Float) = (1, 1)
    ) {
        guard rect.width > 0, rect.height > 0,
              uvMax.x > uvMin.x, uvMax.y > uvMin.y,
              texelSize.x > 0, texelSize.y > 0 else { return }
        let insetX = min(texelSize.x / 2, (uvMax.x - uvMin.x) / 2)
        let insetY = min(texelSize.y / 2, (uvMax.y - uvMin.y) / 2)
        let edgeX = rect.width * insetX / (uvMax.x - uvMin.x)
        let edgeY = rect.height * insetY / (uvMax.y - uvMin.y)
        let xs = [rect.minX, rect.minX + edgeX, rect.maxX - edgeX, rect.maxX]
        let ys = [rect.minY, rect.minY + edgeY, rect.maxY - edgeY, rect.maxY]
        let us = [uvMin.x + insetX, uvMin.x + insetX, uvMax.x - insetX, uvMax.x - insetX]
        let vs = [uvMin.y + insetY, uvMin.y + insetY, uvMax.y - insetY, uvMax.y - insetY]
        for y in 0..<3 { for x in 0..<3 {
            guard xs[x + 1] > xs[x], ys[y + 1] > ys[y] else { continue }
            addImageQuad(rect: UIRect(x: xs[x], y: ys[y], width: xs[x + 1] - xs[x], height: ys[y + 1] - ys[y]),
                textureID: textureID, tint: tint, uvMin: (us[x], vs[y]), uvMax: (us[x + 1], vs[y + 1]))
        } }
    }

    /// Append a textured quad treating the source image's alpha channel as
    /// coverage and the supplied tint as the final color. This is intended
    /// for SVG/icon assets that must follow theme foreground tokens instead
    /// of preserving hard-coded source colors.
    public func addImageMaskQuad(
        rect: UIRect,
        textureID: TextureID,
        tint: Color = .white,
        uvMin: (x: Float, y: Float) = (0, 0),
        uvMax: (x: Float, y: Float) = (1, 1)
    ) {
        let packed = tint.rgba8
        let u0 = uvMin.x + 20
        let u1 = uvMax.x + 20
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

    /// Append a thin solid line between two screen-space points.
    ///
    /// Uses an opaque core, a one-physical-pixel alpha fringe and rounded caps,
    /// matching the coverage convention of `addRoundedRect`. A plain rotated
    /// quad has hard stair-stepped sides; that is very visible on checkmarks,
    /// spinner ticks and chart strokes at 1x.
    public func addLine(fromX x0: Float, fromY y0: Float,
                        toX x1: Float, toY y1: Float,
                        thickness: Float, color: Color) {
        let dx = x1 - x0
        let dy = y1 - y0
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-3 else { return }
        let invLen = 1 / length
        let nx = -dy * invLen
        let ny = dx * invLen
        let half = max(thickness, 0.5) * 0.5
        let feather = min(0.5 / max(1, pixelScale), half * 0.5)
        let innerHalf = max(0, half - feather)
        let outerHalf = half + feather
        let opaque = color.rgba8
        let clear = opaque & 0x00FF_FFFF
        let baseIndex = UInt32(indices.count)

        func vertex(_ x: Float, _ y: Float, _ packed: UInt32) -> UIVertex {
            UIVertex(posX: x, posY: y, u: -1, v: 0, color: packed)
        }
        func append(_ a: UIVertex, _ b: UIVertex, _ c: UIVertex, _ d: UIVertex) {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [a, b, c, d])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        if innerHalf > 0 {
            append(vertex(x0 + nx * innerHalf, y0 + ny * innerHalf, opaque),
                   vertex(x1 + nx * innerHalf, y1 + ny * innerHalf, opaque),
                   vertex(x1 - nx * innerHalf, y1 - ny * innerHalf, opaque),
                   vertex(x0 - nx * innerHalf, y0 - ny * innerHalf, opaque))
        }
        append(vertex(x0 + nx * innerHalf, y0 + ny * innerHalf, opaque),
               vertex(x1 + nx * innerHalf, y1 + ny * innerHalf, opaque),
               vertex(x1 + nx * outerHalf, y1 + ny * outerHalf, clear),
               vertex(x0 + nx * outerHalf, y0 + ny * outerHalf, clear))
        append(vertex(x0 - nx * innerHalf, y0 - ny * innerHalf, opaque),
               vertex(x1 - nx * innerHalf, y1 - ny * innerHalf, opaque),
               vertex(x1 - nx * outerHalf, y1 - ny * outerHalf, clear),
               vertex(x0 - nx * outerHalf, y0 - ny * outerHalf, clear))

        let capSegments = 8
        for (cx, cy) in [(x0, y0), (x1, y1)] {
            let center = UInt32(vertices.count)
            vertices.append(vertex(cx, cy, opaque))
            let ring = UInt32(vertices.count)
            for step in 0...capSegments {
                let angle = Float(step) / Float(capSegments) * 2 * .pi
                let ox = cos(angle), oy = sin(angle)
                vertices.append(vertex(cx + ox * innerHalf, cy + oy * innerHalf, opaque))
                vertices.append(vertex(cx + ox * outerHalf, cy + oy * outerHalf, clear))
            }
            for step in 0..<capSegments {
                let innerA = ring + UInt32(step) * 2
                let outerA = innerA + 1
                let innerB = ring + UInt32(step + 1) * 2
                let outerB = innerB + 1
                indices.append(contentsOf: [center, innerA, innerB])
                indices.append(contentsOf: [innerA, outerA, outerB,
                                            innerA, outerB, innerB])
            }
        }
        let count = UInt32(indices.count) - baseIndex
        if count > 0 { recordIndices(at: baseIndex, count: count, textureID: .none) }
    }

    /// Append a solid-color triangle. Used by CPU-projected geometry such as the
    /// asset-browser mesh thumbnail rasterizer; winding is not enforced (the
    /// caller is responsible for any back-face culling it wants).
    public func addTriangle(_ ax: Float, _ ay: Float,
                            _ bx: Float, _ by: Float,
                            _ cx: Float, _ cy: Float,
                            color: Color) {
        let packed = color.rgba8
        let baseVertex = UInt32(vertices.count)
        // Sentinel uv (-1, 0) → solid color path in the shader.
        vertices.append(UIVertex(posX: ax, posY: ay, u: -1, v: 0, color: packed))
        vertices.append(UIVertex(posX: bx, posY: by, u: -1, v: 0, color: packed))
        vertices.append(UIVertex(posX: cx, posY: cy, u: -1, v: 0, color: packed))
        let baseIndex = UInt32(indices.count)
        indices.append(baseVertex)
        indices.append(baseVertex + 1)
        indices.append(baseVertex + 2)
        recordIndices(at: baseIndex, count: 3, textureID: .none)
    }

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
    ///
    /// A pending backdrop never merges: the renderer can only insert an
    /// offscreen pass between whole batches, so the frosted fill has to start
    /// one rather than ride along with the shadow or container behind it.
    private func recordIndices(at baseIndex: UInt32, count: UInt32, textureID: TextureID) {
        let count = masks.contains(where: { $0.radius > 0 }) ? applyMasks(from: baseIndex, count: count) : count
        guard count > 0 else { pendingBackdrop = nil; return }
        let scissor = clipStack.last
        let backdrop = pendingBackdrop
        pendingBackdrop = nil
        if backdrop == nil,
           var last = batches.last,
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
                scissor: scissor,
                backdrop: backdrop
            ))
        }
    }

    /// Clip the triangles just emitted (`baseIndex..<baseIndex+count`) to the
    /// active rounded masks and return the new index count. Triangles inside
    /// every mask's straight interior are kept untouched, so only geometry
    /// near a rounded edge pays for clipping.
    private func applyMasks(from baseIndex: UInt32, count: UInt32) -> UInt32 {
        let start = Int(baseIndex), end = start + Int(count)
        let active = masks.indices.filter { masks[$0].radius > 0 }
        var minX = Float.infinity, minY = Float.infinity
        var maxX = -Float.infinity, maxY = -Float.infinity
        for index in indices[start..<end] {
            let vertex = vertices[Int(index)]
            minX = min(minX, vertex.posX)
            minY = min(minY, vertex.posY)
            maxX = max(maxX, vertex.posX)
            maxY = max(maxY, vertex.posY)
        }
        let bounds = UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if active.allSatisfy({ masks[$0].contains(bounds) }) { return count }
        let emitted = Array(indices[start..<end])
        var kept: [UInt32] = []
        kept.reserveCapacity(emitted.count)
        var changed = false
        for triangle in stride(from: 0, to: emitted.count - 2, by: 3) {
            let a = vertices[Int(emitted[triangle])]
            let b = vertices[Int(emitted[triangle + 1])]
            let c = vertices[Int(emitted[triangle + 2])]
            let minX = min(a.posX, min(b.posX, c.posX)), minY = min(a.posY, min(b.posY, c.posY))
            let maxX = max(a.posX, max(b.posX, c.posX)), maxY = max(a.posY, max(b.posY, c.posY))
            let bounds = UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let intersecting = active.filter { !masks[$0].contains(bounds) }
            if intersecting.isEmpty {
                kept.append(contentsOf: emitted[triangle..<(triangle + 3)])
                continue
            }
            changed = true
            let polygon = RoundedClipper.clip([a, b, c], against: intersecting.map { maskOutlines[$0] })
            guard polygon.count >= 3 else { continue }
            let first = UInt32(vertices.count)
            vertices.append(contentsOf: polygon)
            for fan in 1..<(polygon.count - 1) {
                kept.append(contentsOf: [first, first + UInt32(fan), first + UInt32(fan + 1)])
            }
        }
        guard changed else { return count }
        indices.removeSubrange(start..<end)
        indices.append(contentsOf: kept)
        return UInt32(kept.count)
    }

    private func emitRoundedRectGeometry(rect: UIRect, radius r: Float, color packed: UInt32) {
        // Alpha interpolates across a single physical pixel centred on the
        // requested boundary. Expanded translucent fills accumulate opacity
        // over the whole shape and produce a glow rather than antialiasing.
        let halfPixel = min(0.5 / max(1, pixelScale), min(rect.width, rect.height) * 0.5)
        let inner = UIRect(x: rect.minX + halfPixel, y: rect.minY + halfPixel,
                           width: rect.width - 2 * halfPixel, height: rect.height - 2 * halfPixel)
        let outer = UIRect(x: rect.minX - halfPixel, y: rect.minY - halfPixel,
                           width: rect.width + 2 * halfPixel, height: rect.height + 2 * halfPixel)
        let innerRadius = max(0, r - halfPixel), outerRadius = r + halfPixel
        let segments = cornerSegmentCount(for: outerRadius)
        let transparent = packed & 0x00FF_FFFF
        let baseVertex = UInt32(vertices.count), baseIndex = UInt32(indices.count)
        vertices.append(UIVertex(posX: rect.minX + rect.width * 0.5,
                                 posY: rect.minY + rect.height * 0.5, u: -1, v: 0, color: packed))
        for corner in 0..<4 {
            let right = corner == 1 || corner == 2, bottom = corner >= 2
            let innerX = right ? inner.maxX - innerRadius : inner.minX + innerRadius
            let innerY = bottom ? inner.maxY - innerRadius : inner.minY + innerRadius
            let outerX = right ? outer.maxX - outerRadius : outer.minX + outerRadius
            let outerY = bottom ? outer.maxY - outerRadius : outer.minY + outerRadius
            let start = Float(corner) * .pi / 2 + .pi
            for step in 0...segments {
                let angle = start + Float(step) / Float(segments) * .pi / 2
                vertices.append(UIVertex(posX: innerX + cos(angle) * innerRadius,
                                         posY: innerY + sin(angle) * innerRadius, u: -1, v: 0, color: packed))
                vertices.append(UIVertex(posX: outerX + cos(angle) * outerRadius,
                                         posY: outerY + sin(angle) * outerRadius, u: -1, v: 0, color: transparent))
            }
        }
        let pairs = UInt32(4 * (segments + 1))
        for pair in 0..<pairs {
            let a = baseVertex + 1 + pair * 2
            let b = baseVertex + 1 + ((pair + 1) % pairs) * 2
            indices.append(contentsOf: [baseVertex, a, b, a, a + 1, b, b, a + 1, b + 1])
        }
        recordIndices(at: baseIndex, count: pairs * 9, textureID: .none)
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

    private func emitTexturedCornerFan(centerX: Float,
                                       centerY: Float,
                                       radius r: Float,
                                       startAngle: Float,
                                       sourceRect: UIRect,
                                       packedTint: UInt32,
                                       textureID: TextureID,
                                       uvMin: (x: Float, y: Float),
                                       uvMax: (x: Float, y: Float)) {
        let segmentCount = cornerSegmentCount(for: r)
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

    private func cornerSegmentCount(for radius: Float) -> Int {
        // The chord is measured in *physical* pixels. A fixed 0.8 *logical*
        // points is 1.6 physical pixels on a 2x display, and a corner whose
        // facets are wider than a pixel reads as a polygon rather than an arc —
        // which is most of why small radii (a 4pt checkbox corner) look soft.
        let chord = 0.8 / max(1, pixelScale)
        let clampedRadius = max(0, radius)
        guard clampedRadius > 0 else { return 10 }
        let quarterArc = (.pi / 2) * clampedRadius
        let estimated = Int(ceil(quarterArc / chord))
        return max(10, min(96, estimated))
    }

    /// Round a logical coordinate onto the physical pixel grid.
    private func snapped(_ value: Float) -> Float {
        guard pixelScale > 0 else { return value }
        return (value * pixelScale).rounded() / pixelScale
    }

    /// Snap a rectangle by rounding both of its edges rather than its origin and
    /// size: rounding the size is what would round a hairline's width away.
    private func snapped(_ rect: UIRect) -> UIRect {
        guard pixelScale > 0 else { return rect }
        let minX = snapped(rect.minX)
        let minY = snapped(rect.minY)
        let maxX = snapped(rect.maxX)
        let maxY = snapped(rect.maxY)
        return UIRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
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

