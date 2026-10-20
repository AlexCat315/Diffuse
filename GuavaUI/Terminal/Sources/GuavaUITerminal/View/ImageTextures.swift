internal import GuavaUIRuntime

/// GPU-ready assets for Kitty graphics images, rebuilt only when an image's
/// generation changes and dropped when no placement shows it any more.
final class ImageTextures {
    private var assets: [UInt32: (generation: UInt64, asset: ImageAssetRegistry.Asset)] = [:]

    /// Assets for the frame's placements, in draw order.
    func resolve(_ placements: [TerminalImagePlacement],
                 pixels: (UInt32) -> DecodedImage?) -> [(TerminalImagePlacement, ImageAssetRegistry.Asset)] {
        var live = Set<UInt32>()
        var result: [(TerminalImagePlacement, ImageAssetRegistry.Asset)] = []
        for placement in placements {
            live.insert(placement.imageID)
            if let cached = assets[placement.imageID], cached.generation == placement.generation {
                result.append((placement, cached.asset))
            } else if let image = pixels(placement.imageID), let asset = try? ImageAssetRegistry.Asset(image: image) {
                assets[placement.imageID] = (placement.generation, asset)
                result.append((placement, asset))
            }
        }
        assets = assets.filter { live.contains($0.key) }
        return result
    }

    func removeAll() { assets.removeAll() }
}
