import Foundation
import GuavaUIRuntime
import Logging

public enum ImageLoadFailureReason: Sendable {
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
    /// First call decodes and retains CPU pixels; GPU upload belongs to the
    /// consuming renderer. Subsequent calls hit the in-memory
    /// cache. Vector formats (SVG/PDF) are rasterised at the requested
    /// pixel dimensions so passing different sizes produces different
    /// crisp textures.
    ///
    /// A registry provides shared caching; decoding works without one.
    /// If decoding fails, the primitive degrades to
    /// `TextureID.none` (a tinted blank quad of the requested size).
    init(file path: String,
         width: Float,
         height: Float,
         tint: Color = .white,
         contentMode: ContentMode = .stretch,
         renderingMode: RenderingMode = .color) {
        let resolved = Self.resolve(path: path, width: width, height: height)
        self.init(source: resolved,
                  width: width,
                  height: height,
                  tint: tint,
                  contentMode: contentMode,
                  renderingMode: renderingMode)
        if ["svg", "pdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            vectorSourceURL = URL(fileURLWithPath: path)
        }
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

    static func resolve(path: String, width: Float, height: Float) -> Source {
        let url = URL(fileURLWithPath: path)
        // Vector formats need an explicit raster size; bitmap formats
        // pass `nil` so the natural resolution is preserved. SVG/PDF are
        // rasterized at physical-pixel resolution (logical * contentScale)
        // so they remain crisp on HiDPI displays.
        let ext = url.pathExtension.lowercased()
        let size: (Int, Int)?
        if ext == "svg" || ext == "pdf" {
            let density = ContentScaleHolder.current
            let scale = density.isFinite ? max(1, density) : 1
            let pxW = max(1, Int((width * scale).rounded()))
            let pxH = max(1, Int((height * scale).rounded()))
            size = (pxW, pxH)
        } else {
            size = nil
        }

        do {
            let asset: ImageAssetRegistry.Asset
            if let registry = ImageAssetRegistryHolder.current {
                asset = try registry.texture(url: url, size: size)
            } else {
                asset = try ImageAssetRegistry.Asset(image: ImageDecoder.decode(url: url, targetSize: size))
            }
            return .asset(asset)
        } catch {
            ImageLoadDiagnostics.emit(path: path,
                                      reason: .decodeFailed,
                                      details: "using TextureID.none; image decode failed: \(error)")
            return .texture(.none)
        }
    }
}
