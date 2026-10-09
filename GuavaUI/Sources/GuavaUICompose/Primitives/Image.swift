#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

/// Bitmap image primitive backed by an owned CPU asset or a registered GPU texture.
///
/// File images retain their decoded asset with the draw list. Native and WGPU
/// renderers upload it on first use. Hosts can also supply a manually registered
/// `TextureID`. Layout uses the explicit logical `width` and `height`.
///
/// `tint` multiplies the sampled RGBA. Pass `.white` (default) for an
/// untouched bitmap, or any other color to recolour an opaque shape (acts as
/// a multiplicative tint, matching the shader's `color * texture` path).
public struct Image: _PrimitiveView {

    public enum ContentMode: Sendable, Equatable {
        case stretch
        case fit
        case fill
    }

    public enum RenderingMode: Sendable, Equatable {
        case color
        case alphaMask
    }

    public enum Source: Sendable, Equatable {
        case texture(TextureID, size: SIMD2<Float>? = nil)
        case asset(ImageAssetRegistry.Asset)

        var textureID: TextureID {
            switch self { case .texture(let id, _): id; case .asset(let asset): asset.textureID }
        }
        var sourcePixelSize: (width: Float, height: Float)? {
            switch self {
            case .texture(_, let size): size.map { ($0.x, $0.y) }
            case .asset(let asset): (Float(asset.image.width), Float(asset.image.height))
            }
        }
        func retain(in list: DrawList) {
            if case .asset(let asset) = self { list.retainResource(asset) }
        }
    }
    public let source: Source
    public let width: Float
    public let height: Float
    public let tint: Color
    public let contentMode: ContentMode
    public let renderingMode: RenderingMode
    var vectorSourceURL: URL? = nil

    private struct PaintIdentity: Equatable {
        let source: Source
        let width: Float
        let height: Float
        let tint: Color
        let contentMode: ContentMode
        let renderingMode: RenderingMode
        let vectorSourceURL: URL?
    }

    public init(textureID: TextureID,
                width: Float,
                height: Float,
                tint: Color = Color.white,
                sourcePixelSize: (width: Float, height: Float)? = nil,
                contentMode: ContentMode = .stretch,
                renderingMode: RenderingMode = .color) {
        self.init(source: .texture(textureID, size: sourcePixelSize.map { SIMD2($0.width, $0.height) }),
            width: width, height: height, tint: tint, contentMode: contentMode, renderingMode: renderingMode)
    }

    public init(source: Source, width: Float, height: Float, tint: Color = .white,
        contentMode: ContentMode = .stretch, renderingMode: RenderingMode = .color) {
        self.source = source; self.width = width; self.height = height
        self.tint = tint; self.contentMode = contentMode; self.renderingMode = renderingMode
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    public func _updateNode(_ node: Node) {
        let snap = self
        let vectorRaster = vectorSourceURL.map { VectorImageRaster(url: $0, initial: source, width: width, height: height) }
        node.updateDraw(identity: PaintIdentity(source: source,
                                                width: width,
                                                height: height,
                                                tint: tint,
                                                contentMode: contentMode,
                                                renderingMode: renderingMode,
                                                vectorSourceURL: vectorSourceURL)) { list, origin in
            let f = node.frame
            let drawWidth  = f.width  > 0 ? Float(f.width)  : snap.width
            let drawHeight = f.height > 0 ? Float(f.height) : snap.height
            let modifierTint = snap.renderingMode == .alphaMask
                ? (node.inheritedForegroundColor ?? node.theme.colors.onSurface)
                : (node.foregroundColor ?? .white)
            let baseTint = Color(
                r: snap.tint.r * modifierTint.r,
                g: snap.tint.g * modifierTint.g,
                b: snap.tint.b * modifierTint.b,
                a: snap.tint.a * modifierTint.a
            ).multipliedAlpha(node.opacity)
            let container = UIRect(x: Float(origin.x),
                                   y: Float(origin.y),
                                   width: drawWidth,
                                   height: drawHeight)
            let resolved = vectorRaster?.resolve(width: drawWidth, height: drawHeight) ?? snap.source
            resolved.retain(in: list)
            let texture = resolved.textureID
            let geometry = ImageGeometry(container: container, source: resolved.sourcePixelSize, mode: snap.contentMode)
            var rect = geometry.rect
            if snap.renderingMode == .alphaMask {
                let scale = ContentScaleHolder.current
                if vectorRaster != nil, scale.isFinite, scale > 0 {
                    rect = UIRect(x: (rect.x * scale).rounded() / scale, y: (rect.y * scale).rounded() / scale, width: rect.width, height: rect.height)
                }
                list.addImageMaskQuad(rect: rect,
                                      textureID: texture,
                                      tint: baseTint, uvMin: geometry.uvMin, uvMax: geometry.uvMax)
            } else if node.cornerRadius > 0 {
                list.addRoundedImageQuad(rect: rect,
                                         radius: node.cornerRadius,
                                         textureID: texture,
                                         tint: baseTint, uvMin: geometry.uvMin, uvMax: geometry.uvMax)
            } else {
                list.addImageQuad(rect: rect,
                                  textureID: texture,
                                  tint: baseTint, uvMin: geometry.uvMin, uvMax: geometry.uvMax)
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = width
        layout.height = height
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.width = width
        layout.height = height
    }

}
