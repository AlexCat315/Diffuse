import Foundation
import GuavaUIRuntime

/// A vector image follows its actual draw size and the current drawable density.
/// The registry keeps each raster size, so moving between screens needs no recompose.
final class VectorImageRaster {
    private struct Key: Equatable {
        let width: Float
        let height: Float
        let density: Float
        let registry: ObjectIdentifier?

        init(width: Float, height: Float) {
            self.width = width
            self.height = height
            let scale = ContentScaleHolder.current
            density = scale.isFinite ? max(1, scale) : 1
            registry = ImageAssetRegistryHolder.current.map(ObjectIdentifier.init)
        }
    }

    private let url: URL
    private var key: Key
    private var asset: Image.ResolvedTexture

    init(url: URL, initial: Image.ResolvedTexture, width: Float, height: Float) {
        self.url = url
        key = Key(width: width, height: height)
        asset = initial
    }

    func resolve(width: Float, height: Float) -> Image.ResolvedTexture {
        let next = Key(width: width, height: height)
        if next != key {
            asset = Image.resolve(path: url.path, width: width, height: height)
            key = next
        }
        return asset
    }
}
