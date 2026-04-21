import Foundation
import GuavaUIRuntime

public extension Image {

    /// Convenience initializer that loads `path` through the registry in
    /// `ImageAssetRegistryHolder.current`, then renders the resulting
    /// `TextureID` at the requested size.
    ///
    /// First call decodes + uploads, subsequent calls hit the in-memory
    /// cache. Vector formats (SVG/PDF) are rasterised at the requested
    /// pixel dimensions so passing different sizes produces different
    /// crisp textures.
    ///
    /// If no registry is set or decoding fails, the primitive degrades to
    /// `TextureID.none` (a tinted blank quad of the requested size). The
    /// failure reason is logged through `Log.image` so hosts can debug
    /// missing assets without a hard crash.
    init(file path: String,
         width: Float,
         height: Float,
         tint: Color = .white) {
        let resolved = Self.resolve(path: path, width: width, height: height)
        self.init(textureID: resolved, width: width, height: height, tint: tint)
    }

    /// URL form of `init(file:width:height:tint:)`.
    init(url: URL,
         width: Float,
         height: Float,
         tint: Color = .white) {
        self.init(file: url.path, width: width, height: height, tint: tint)
    }

    private static func resolve(path: String, width: Float, height: Float) -> TextureID {
        guard let registry = ImageAssetRegistryHolder.current else {
            return .none
        }
        let url = URL(fileURLWithPath: path)
        // Vector formats need an explicit raster size; bitmap formats
        // pass `nil` so the natural resolution is preserved.
        let ext = url.pathExtension.lowercased()
        let size: (Int, Int)?
        if ext == "svg" || ext == "pdf" {
            size = (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
        } else {
            size = nil
        }
        do {
            return try registry.texture(url: url, size: size).textureID
        } catch {
            return .none
        }
    }
}
