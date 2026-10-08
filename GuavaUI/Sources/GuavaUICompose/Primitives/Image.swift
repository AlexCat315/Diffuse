#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

/// Bitmap image primitive backed by a renderer-registered RGBA texture.
///
/// The host registers the texture once via
/// `DrawListRenderer.registerColorTexture(id:pixels:width:height:)` and then
/// passes the resulting `TextureID` to `Image`. The primitive emits a single
/// quad sized by the explicit `width` / `height`; layout treats those as
/// fixed dimensions (no intrinsic aspect ratio inference yet).
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

    public let textureID: TextureID
    public let width: Float
    public let height: Float
    public let tint: Color
    public let sourcePixelSize: (width: Float, height: Float)?
    public let contentMode: ContentMode
    public let renderingMode: RenderingMode
    var vectorSourceURL: URL? = nil

    private struct PaintIdentity: Equatable {
        let textureID: TextureID
        let width: Float
        let height: Float
        let tint: Color
        let sourceWidth: Float?
        let sourceHeight: Float?
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
        self.textureID = textureID
        self.width = width
        self.height = height
        self.tint = tint
        self.sourcePixelSize = sourcePixelSize
        self.contentMode = contentMode
        self.renderingMode = renderingMode
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    public func _updateNode(_ node: Node) {
        let snap = self
        let vectorRaster = vectorSourceURL.map { VectorImageRaster(url: $0, initial: Image.ResolvedTexture(textureID: textureID, sourcePixelSize: sourcePixelSize), width: width, height: height) }
        node.updateDraw(identity: PaintIdentity(textureID: textureID,
                                                width: width,
                                                height: height,
                                                tint: tint,
                                                sourceWidth: sourcePixelSize?.width,
                                                sourceHeight: sourcePixelSize?.height,
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
            let asset = vectorRaster?.resolve(width: drawWidth, height: drawHeight)
            let texture = asset?.textureID ?? snap.textureID
            let geometry = ImageGeometry(container: container, source: asset?.sourcePixelSize ?? snap.sourcePixelSize, mode: snap.contentMode)
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
