import CoreGraphics
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

    public let textureID: TextureID
    public let width: Float
    public let height: Float
    public let tint: Color

    public init(textureID: TextureID,
                width: Float,
                height: Float,
                tint: Color = Color.white) {
        self.textureID = textureID
        self.width = width
        self.height = height
        self.tint = tint
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    public func _updateNode(_ node: Node) {
        let snap = self
        node.draw = { list, origin in
            let f = node.frame
            let drawWidth  = f.width  > 0 ? Float(f.width)  : snap.width
            let drawHeight = f.height > 0 ? Float(f.height) : snap.height
            let modifierTint = node.foregroundColor ?? .white
            let baseTint = Color(
                r: snap.tint.r * modifierTint.r,
                g: snap.tint.g * modifierTint.g,
                b: snap.tint.b * modifierTint.b,
                a: snap.tint.a * modifierTint.a
            ).multipliedAlpha(node.opacity)
            let rect = UIRect(x: Float(origin.x),
                              y: Float(origin.y),
                              width: drawWidth,
                              height: drawHeight)
            if node.cornerRadius > 0 {
                list.addRoundedImageQuad(rect: rect,
                                         radius: node.cornerRadius,
                                         textureID: snap.textureID,
                                         tint: baseTint)
            } else {
                list.addImageQuad(rect: rect,
                                  textureID: snap.textureID,
                                  tint: baseTint)
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
