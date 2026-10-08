import AssetPipeline
import Foundation
import Logging
import NativeRHI

/// GPU residency is renderer-owned. Catalog revisions replace resources as a
/// transaction, and Device retirement protects frames still using old handles.
final class NativeMeshStore {
    let device: Device
    let sampler: Sampler
    private(set) var fallbacks: [Texture] = []
    private var builtins: [Int: NativeMesh] = [:]
    private var imported: [Int: NativeMesh] = [:]
    private(set) var revision: UInt64?
    private let registry: AssetRegistry
    var residentCount: Int { Set(builtins.keys).union(imported.keys).count }

    init(device: Device, registry: AssetRegistry) throws {
        self.device = device; self.registry = registry
        sampler = try device.makeSampler(SamplerDescriptor(addressModeU: .clampToEdge, addressModeV: .clampToEdge))
        do {
            for pixel: [UInt8] in [[255,255,255,255], [128,128,255,255], [255,255,0,255]] {
                fallbacks.append(try Self.texture(device: device,
                    image: DecodedTextureAsset(pixels: pixel, width: 1, height: 1)))
            }
            let cube = BuiltinMesh.cube(color: SIMD3(repeating: 1))
            builtins[0] = try NativeMesh.make(device: device, asset: cube, sourceDirectory: nil)
            var fixture = cube
            if let url = RenderBackendResourceBundle.bundle.url(forResource: "FinalBaseMesh", withExtension: "obj") {
                fixture = try OBJLoader.load(path: url.path)
                fixture.normalizeToUnitBounds(targetSize: 2)
            }
            builtins[1] = try NativeMesh.make(device: device, asset: fixture, sourceDirectory: nil)
        } catch {
            builtins.values.forEach { $0.destroy(device: device) }
            fallbacks.forEach { device.destroy($0) }; device.destroy(sampler)
            throw error
        }
    }
    deinit {
        builtins.values.forEach { $0.destroy(device: device) }
        imported.values.forEach { $0.destroy(device: device) }
        fallbacks.forEach { device.destroy($0) }; device.destroy(sampler)
    }
    subscript(index: Int) -> NativeMesh? { imported[index] ?? builtins[index] }

    func synchronize() throws {
        guard let catalog = registry.meshCatalog(since: revision) else { return }
        var replacements: [Int: NativeMesh] = [:]
        do {
            for entry in catalog.meshes {
                replacements[entry.meshIndex] = try NativeMesh.make(device: device,
                    asset: entry.mesh, sourceDirectory: entry.sourceDirectory)
            }
        } catch { replacements.values.forEach { $0.destroy(device: device) }; throw error }
        imported.values.forEach { $0.destroy(device: device) }
        imported = replacements; revision = catalog.revision
    }
    static func texture(device: Device, image: DecodedTextureAsset) throws -> Texture {
        let texture = try device.makeTexture(TextureDescriptor(width: image.width, height: image.height,
            format: .rgba8Unorm, usage: [.sampled, .transferDestination]))
        do {
            try device.uploadTextureData(texture, data: Data(image.pixels), width: image.width,
                height: image.height, bytesPerRow: image.width * 4)
            return texture
        } catch { device.destroy(texture); throw error }
    }
}

struct NativeMeshGeometry {
    let vertices: Buffer
    let indices: Buffer
    let vertexCapacity: Int
    let indexCapacity: Int
    let submeshes: [MeshSubmesh]
    let bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    func destroy(device: Device) { device.destroy(vertices); device.destroy(indices) }
}

struct NativeMesh {
    let geometry: NativeMeshGeometry
    let materials: [MeshMaterial]
    let textures: [Int: Texture]

    static func make(device: Device, asset: MeshAsset, sourceDirectory: String?) throws -> NativeMesh {
        guard asset.vertexCount > 0, asset.vertices.count.isMultiple(of: MeshAsset.vertexFloatCount),
              !asset.indices.isEmpty, asset.indices.count.isMultiple(of: 3),
              asset.vertices.allSatisfy(\.isFinite), asset.indices.allSatisfy({ Int($0) < asset.vertexCount }) else {
            throw RHIError.invalidArgument("invalid mesh geometry: \(asset.name)")
        }
        guard asset.materials.allSatisfy({ material in
            (0..<4).allSatisfy { material.baseColorFactor[$0].isFinite } && material.alphaCutoff.isFinite
        }) else { throw RHIError.invalidArgument("non-finite imported material: \(asset.name)") }
        let parts = asset.submeshes.isEmpty
            ? [MeshSubmesh(indexStart: 0, indexCount: asset.indexCount, materialIndex: 0)] : asset.submeshes
        guard parts.allSatisfy({ Int($0.indexStart) <= asset.indices.count
            && Int($0.indexCount) <= asset.indices.count - Int($0.indexStart)
            && $0.indexCount.isMultiple(of: 3) && asset.materials.indices.contains($0.materialIndex) }) else {
            throw RHIError.invalidArgument("invalid submesh range/material: \(asset.name)")
        }
        let vertices = try device.makeBuffer(BufferDescriptor(size: asset.vertexBufferSize, usage: [.vertex, .transferDestination]))
        var indices: Buffer?
        var textures: [Int: Texture] = [:]
        do {
            let indexBuffer = try device.makeBuffer(BufferDescriptor(size: asset.indexBufferSize, usage: [.index, .transferDestination]))
            indices = indexBuffer
            try device.uploadBufferData(vertices, data: asset.vertices.withUnsafeBytes { Data($0) })
            try device.uploadBufferData(indexBuffer, data: asset.indices.withUnsafeBytes { Data($0) })
            for (index, texture) in asset.textures.enumerated() {
                let decoded: DecodedTextureAsset
                do { decoded = try MeshTextureResolver.decode(texture, sourceDirectory: sourceDirectory).texture }
                catch { Logger.renderer.warning("native mesh texture \(asset.name)[\(index)] uses fallback: \(error)"); continue }
                textures[index] = try NativeMeshStore.texture(device: device, image: decoded)
            }
            return NativeMesh(geometry: NativeMeshGeometry(vertices: vertices, indices: indexBuffer,
                vertexCapacity: asset.vertexBufferSize, indexCapacity: asset.indexBufferSize,
                submeshes: parts, bounds: asset.localBounds), materials: asset.materials, textures: textures)
        } catch {
            device.destroy(vertices); if let indices { device.destroy(indices) }
            textures.values.forEach { device.destroy($0) }; throw error
        }
    }
    func destroy(device: Device) {
        geometry.destroy(device: device); textures.values.forEach { device.destroy($0) }
    }
}
