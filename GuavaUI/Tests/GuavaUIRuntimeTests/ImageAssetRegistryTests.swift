import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Owned CPU image assets")
struct ImageAssetRegistryTests {
    @Test("concurrent registration publishes one immutable asset per key")
    func concurrentRegistration() throws {
        let registry = ImageAssetRegistry()
        let image = DecodedImage(pixels: [17, 99, 211, 255], width: 1, height: 1)
        let results = ImageAssetResults()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do { results.append(.success(try registry.register(key: "shared", decoded: image))) }
            catch { results.append(.failure(error)) }
        }
        let values = try results.values.map { try $0.get() }
        let asset = try #require(values.first)
        #expect(values.allSatisfy { $0 === asset })
        #expect(registry.cached("shared") === asset)
        #expect(asset.image.pixels == image.pixels)
        let foreign = try ImageAssetRegistry().register(key: "shared", decoded: image)
        #expect(foreign.textureID != asset.textureID)
        #expect(asset.textureID >= 0x1000_0000 && asset.textureID < 0x4000_0000)
    }

    @Test("invalid payloads never enter the cache and clear preserves retained snapshots")
    func validationAndOwnership() throws {
        let registry = ImageAssetRegistry()
        for image in [DecodedImage(pixels: [], width: 0, height: 1),
            .init(pixels: [], width: Int.max, height: 2), .init(pixels: [0], width: 1, height: 1)] {
            #expect(throws: ImageDecodeError.self) { try registry.register(key: "bad", decoded: image) }
            #expect(registry.cached("bad") == nil)
        }
        var asset: ImageAssetRegistry.Asset? = try registry.register(key: "pixel", decoded: .init(pixels: [1, 2, 3, 4], width: 1, height: 1))
        weak let retained = asset
        let list = DrawList(); list.retainResource(asset!); list.retainResource(asset!)
        var snapshot = DrawListSnapshot(vertices: [], indices: [], batches: [], logicalSize: SIMD2(1, 1), resources: list.resources)
        list.reset(); registry.clear(); asset = nil
        #expect(registry.revision == 1)
        #expect(snapshot.resources.count == 1 && retained != nil)
        var bytes: [UInt8] = []
        snapshot.resources.forEach(of: ImageAssetRegistry.Asset.self) { bytes = $0.image.pixels }
        #expect(bytes == [1, 2, 3, 4])
        snapshot.resources.reset()
        #expect(retained == nil)
    }
}

private final class ImageAssetResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<ImageAssetRegistry.Asset, any Error>] = []
    var values: [Result<ImageAssetRegistry.Asset, any Error>] { lock.withLock { storage } }
    func append(_ value: Result<ImageAssetRegistry.Asset, any Error>) { lock.withLock { storage.append(value) } }
}
