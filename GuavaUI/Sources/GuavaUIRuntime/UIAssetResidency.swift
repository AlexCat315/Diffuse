/// Render-thread bookkeeping for GPU assets. CPU owners are weak here so cache
/// clear/unmount can reclaim residency; already recorded frames own GPU slots.
struct UIAssetResidency {
    private final class Owner {
        weak var asset: ImageAssetRegistry.Asset?
        init(_ asset: ImageAssetRegistry.Asset) { self.asset = asset }
    }
    private var owners: [TextureID: Owner] = [:]

    mutating func prepare(_ resources: DrawListResources,
        register: (ImageAssetRegistry.Asset) throws -> Void, unregister: (TextureID) -> Void) throws {
        for id in owners.keys.filter({ owners[$0]?.asset == nil }) {
            unregister(id); owners.removeValue(forKey: id)
        }
        try resources.forEach(of: ImageAssetRegistry.Asset.self) { asset in
            guard owners[asset.textureID]?.asset !== asset else { return }
            try register(asset)
            owners[asset.textureID] = Owner(asset)
        }
    }
    mutating func forget(_ id: TextureID) { owners.removeValue(forKey: id) }
}
