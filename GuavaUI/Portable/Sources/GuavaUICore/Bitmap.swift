/// Raw RGBA8 bitmap with straight (non-premultiplied) alpha. Width/height
/// are in pixels; `pixels.count == width * height * 4`. The byte order is
/// `[R, G, B, A]`, top-left origin, which matches what
/// `DrawListRenderer.registerColorTexture(...)` expects.
public struct DecodedImage: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// CPU texture ownership consumed by a GPU renderer, independent of decoding.
public protocol UITextureAsset: AnyObject, Sendable {
    var textureID: TextureID { get }
    var image: DecodedImage { get }
}
