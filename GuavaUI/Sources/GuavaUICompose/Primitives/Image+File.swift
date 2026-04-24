import Foundation
import GuavaUIRuntime
import Logging

public enum ImageLoadFailureReason: Sendable {
    case missingRegistry
    case decodeFailed
    case resourceNotFound
}

public struct ImageLoadDiagnostic: Sendable {
    public let path: String
    public let reason: ImageLoadFailureReason
    public let details: String

    public init(path: String, reason: ImageLoadFailureReason, details: String) {
        self.path = path
        self.reason = reason
        self.details = details
    }
}

public enum ImageLoadDiagnostics {
    nonisolated(unsafe) public static var onEvent: ((ImageLoadDiagnostic) -> Void)?

    static func emit(path: String, reason: ImageLoadFailureReason, details: String) {
        let event = ImageLoadDiagnostic(path: path, reason: reason, details: details)
        Logger(label: "com.guava.ui.compose").warning("image load fallback [\(reason)]: \(path) — \(details)")
        onEvent?(event)
    }
}

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
    /// `TextureID.none` (a tinted blank quad of the requested size).
    init(file path: String,
         width: Float,
         height: Float,
         tint: Color = .white,
         contentMode: ContentMode = .stretch,
         renderingMode: RenderingMode = .color) {
        let resolved = Self.resolve(path: path, width: width, height: height)
        self.init(textureID: resolved.textureID,
                  width: width,
                  height: height,
                  tint: tint,
                  sourcePixelSize: resolved.sourcePixelSize,
                  contentMode: contentMode,
                  renderingMode: renderingMode)
    }

    /// Bundle-resource form of `init(file:width:height:tint:)`. This keeps
    /// SwiftPM bundle layout details out of view code.
    init(resource: BundleImageResource,
         width: Float,
         height: Float,
         tint: Color = .white,
         contentMode: ContentMode = .stretch,
         renderingMode: RenderingMode = .color) {
        guard let url = resource.url else {
            assertionFailure("Bundle image resource not found: \(resource)")
            ImageLoadDiagnostics.emit(path: String(describing: resource),
                                      reason: .resourceNotFound,
                                      details: "bundle resource URL is nil")
            self.init(textureID: .none,
                      width: width,
                      height: height,
                      tint: tint,
                      sourcePixelSize: nil,
                      contentMode: contentMode,
                      renderingMode: renderingMode)
            return
        }
        self.init(url: url,
                  width: width,
                  height: height,
                  tint: tint,
                  contentMode: contentMode,
                  renderingMode: renderingMode)
    }

    /// URL form of `init(file:width:height:tint:)`.
    init(url: URL,
         width: Float,
         height: Float,
         tint: Color = .white,
         contentMode: ContentMode = .stretch,
         renderingMode: RenderingMode = .color) {
        self.init(file: url.path,
                  width: width,
                  height: height,
                  tint: tint,
                  contentMode: contentMode,
                  renderingMode: renderingMode)
    }

    private struct ResolvedTexture {
        let textureID: TextureID
        let sourcePixelSize: (width: Float, height: Float)?
    }

    private static func resolve(path: String, width: Float, height: Float) -> ResolvedTexture {
        let url = URL(fileURLWithPath: path)
        // Vector formats need an explicit raster size; bitmap formats
        // pass `nil` so the natural resolution is preserved. SVG/PDF are
        // rasterized at physical-pixel resolution (logical * contentScale)
        // so they remain crisp on HiDPI displays.
        let ext = url.pathExtension.lowercased()
        let size: (Int, Int)?
        if ext == "svg" || ext == "pdf" {
            let scale = max(1, ContentScaleHolder.current)
            let pxW = max(1, Int((width * scale).rounded()))
            let pxH = max(1, Int((height * scale).rounded()))
            size = (pxW, pxH)
        } else {
            size = nil
        }

        guard let registry = ImageAssetRegistryHolder.current else {
            do {
                let decoded = try ImageDecoder.decode(url: url, targetSize: size)
                ImageLoadDiagnostics.emit(path: path,
                                          reason: .missingRegistry,
                                          details: "using TextureID.none; decoded metadata \(decoded.width)x\(decoded.height)")
                return ResolvedTexture(textureID: .none,
                                       sourcePixelSize: (Float(decoded.width), Float(decoded.height)))
            } catch {
                ImageLoadDiagnostics.emit(path: path,
                                          reason: .missingRegistry,
                                          details: "using TextureID.none; decode failed without registry: \(error)")
                return ResolvedTexture(textureID: .none, sourcePixelSize: nil)
            }
        }

        do {
            let asset = try registry.texture(url: url, size: size)
            return ResolvedTexture(
                textureID: asset.textureID,
                sourcePixelSize: (Float(asset.width), Float(asset.height))
            )
        } catch {
            ImageLoadDiagnostics.emit(path: path,
                                      reason: .decodeFailed,
                                      details: "using TextureID.none; registry decode/upload failed: \(error)")
            return ResolvedTexture(textureID: .none, sourcePixelSize: nil)
        }
    }
}
