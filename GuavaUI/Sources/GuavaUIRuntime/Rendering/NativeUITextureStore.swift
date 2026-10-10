import Foundation
import NativeRHI

struct NativeUITexturePatch {
    let sequence: UInt64
    let region: TextureUploadRegion
    let pixels: Data
}

final class NativeUITextureSlot {
    var acceptsUploads = true
    let resource: TextureResource
    /// Cached (texture, sampler) binding set for this slot's resource. The slot
    /// owns one texture for its lifetime, so the set is stable until the slot is
    /// replaced with a new resource. Populated lazily by the renderer.
    var cachedBindingSet: BindingSet?
    private let lock = NSLock()
    private var patches: [NativeUITexturePatch] = []
    private var sequence: UInt64 = 0

    init(resource: TextureResource) { self.resource = resource }

    func stage(pixels: Data, region: TextureUploadRegion) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        patches.append(NativeUITexturePatch(sequence: sequence, region: region, pixels: pixels))
    }
    func snapshot() -> [NativeUITexturePatch] {
        lock.lock(); defer { lock.unlock() }
        return patches
    }
    func commit(through sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        patches.removeAll { $0.sequence <= sequence }
    }
}

/// Inner (image) pixel rectangle inside an atlas. The atlas allocation reserves
/// a 1px duplicated-edge border around it so linear sampling at the image edge
/// reproduces standalone-texture clamp-to-edge behaviour exactly.
private struct NativeUIImageAtlasPlacement {
    let atlasIndex: Int
    let x: Int, y: Int, w: Int, h: Int
}

private struct NativeUIImageAtlas {
    let texture: TextureResource
    var bindingSet: BindingSet?
    let size: Int
    var cursorX = 0
    var cursorY = 0
    var shelfHeight = 0
    /// Exact-size placements freed by `unregister`, available for reuse.
    var freePlacements: [NativeUIImageAtlasPlacement] = []
}

/// One packed image awaiting its one-time atlas upload. Entries stay queued
/// until the recording that carried them was submitted, exactly like per-asset
/// slot patches, so failed or abandoned recordings retry instead of leaving the
/// atlas sub-rect uninitialised.
private struct NativeUIAtlasPendingUpload {
    let sequence: UInt64
    let pixels: Data
    let region: TextureUploadRegion
    /// Size of the source asset without padding, used for upload accounting.
    let logicalBytes: Int
    let atlasIndex: Int
}

final class NativeUITextureStore {
    /// Side length of each atlas texture in pixels.
    static let atlasSize = 2048
    /// Images larger than this on either axis stay as standalone textures.
    static let maxAtlasDimension = 512

    let device: Device
    let shaders: NativeUIShaderResources
    let fallback: NativeUITextureSlot
    var textures: [TextureID: NativeUITextureSlot] = [:]
    private var assetResidency = UIAssetResidency()

    private var atlases: [NativeUIImageAtlas] = []
    private var placements: [TextureID: NativeUIImageAtlasPlacement] = [:]
    private var pendingAtlasUploads: [NativeUIAtlasPendingUpload] = []
    private var atlasUploadSequence: UInt64 = 0

    init(device: Device, shaders: NativeUIShaderResources) throws {
        self.device = device; self.shaders = shaders
        let resource = try TextureResource(device: device, descriptor: TextureDescriptor(width: 1, height: 1,
            format: .rgba8Unorm, usage: [.sampled, .transferDestination], label: "native-ui-white"))
        fallback = NativeUITextureSlot(resource: resource)
        fallback.stage(pixels: Data(repeating: 255, count: 4), region: .init(width: 1, height: 1))
    }

    func stage(id: TextureID, pixels: Data, size: SIMD2<Int>, region: TextureUploadRegion, format: TextureFormat) throws {
        guard id != .none && size.x > 0 && size.y > 0 && [.r8Unorm, .rgba8Unorm].contains(format) else {
            throw RHIError.invalidArgument("invalid UI texture ID, dimensions or format")
        }
        let channels = format == .r8Unorm ? 1 : 4
        let (rowBytes, overflow) = region.width.multipliedReportingOverflow(by: channels)
        let (byteCount, totalOverflow) = rowBytes.multipliedReportingOverflow(by: region.height)
        guard !overflow && !totalOverflow && region.origin.x >= 0 && region.origin.y >= 0
            && region.origin.x <= size.x && region.origin.y <= size.y && region.width > 0 && region.height > 0
            && region.width <= size.x - region.origin.x && region.height <= size.y - region.origin.y
            && pixels.count == byteCount else { throw RHIError.invalidArgument("invalid UI texture patch") }
        let slot: NativeUITextureSlot
        if let existing = textures[id], existing.acceptsUploads, existing.resource.descriptor.width == size.x,
           existing.resource.descriptor.height == size.y, existing.resource.descriptor.format == format {
            slot = existing
        } else {
            let resource = try TextureResource(device: device, descriptor: TextureDescriptor(width: size.x, height: size.y,
                format: format, usage: [.sampled, .transferDestination, .transferSource], label: "native-ui-\(id)"))
            slot = NativeUITextureSlot(resource: resource)
            if region.origin != .zero || region.width != size.x || region.height != size.y {
                let (pixels, areaOverflow) = size.x.multipliedReportingOverflow(by: size.y)
                let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: channels)
                guard !areaOverflow && !bytesOverflow else { throw RHIError.invalidArgument("UI texture dimensions overflow") }
                slot.stage(pixels: Data(count: bytes), region: .init(width: size.x, height: size.y))
            }
        }
        slot.stage(pixels: pixels, region: region)
        textures[id] = slot
    }

    func register(id: TextureID, resource: TextureResource) throws {
        let descriptor = resource.descriptor
        guard id != .none && resource.device === device && descriptor.dimension == .texture2D
            && descriptor.sampleCount == 1 && descriptor.usage.contains(.sampled)
            && [.rgba8Unorm, .bgra8Unorm].contains(descriptor.format) else {
            throw RHIError.invalidArgument("external UI textures require encoded RGBA/BGRA on the same device")
        }
        if textures[id]?.resource === resource { return }
        let slot = NativeUITextureSlot(resource: resource); slot.acceptsUploads = false
        textures[id] = slot
    }

    func prepareAssets(_ resources: DrawListResources) throws {
        try assetResidency.prepare(resources, register: { asset in
            let image = asset.image
            let w = image.width, h = image.height
            if w > 0, h > 0, w <= Self.maxAtlasDimension, h <= Self.maxAtlasDimension,
               placements[asset.textureID] == nil {
                if let placement = try placeInAtlas(id: asset.textureID, width: w, height: h, pixels: Data(image.pixels)) {
                    placements[asset.textureID] = placement
                    return
                }
            }
            try stage(id: asset.textureID, pixels: Data(image.pixels), size: SIMD2(w, h),
                region: .init(width: w, height: h), format: .rgba8Unorm)
        }, unregister: { id in
            if let placement = placements.removeValue(forKey: id),
               atlases.indices.contains(placement.atlasIndex) {
                atlases[placement.atlasIndex].freePlacements.append(placement)
            }
            textures.removeValue(forKey: id)
        })
    }

    func unregister(_ id: TextureID) {
        if let placement = placements.removeValue(forKey: id),
           atlases.indices.contains(placement.atlasIndex) {
            atlases[placement.atlasIndex].freePlacements.append(placement)
        }
        textures.removeValue(forKey: id); assetResidency.forget(id)
    }

    // MARK: - Atlas

    private func placeInAtlas(id: TextureID, width: Int, height: Int, pixels: Data) throws -> NativeUIImageAtlasPlacement? {
        let padded = Self.paddedEdgePixels(pixels: pixels, width: width, height: height)
        let pw = width + 2, ph = height + 2
        func region(at x: Int, _ y: Int) -> TextureUploadRegion {
            var region = TextureUploadRegion(width: pw, height: ph)
            region.origin = SIMD2(x, y)
            return region
        }
        func enqueue(_ x: Int, _ y: Int, _ atlasIndex: Int) {
            atlasUploadSequence += 1
            // Report the asset's own size; the duplicated-edge border is an atlas
            // implementation detail, not extra image data.
            pendingAtlasUploads.append(NativeUIAtlasPendingUpload(sequence: atlasUploadSequence, pixels: padded,
                region: region(at: x, y), logicalBytes: width * height * 4, atlasIndex: atlasIndex))
        }
        // Reuse a freed placement of the exact same size, if available.
        for atlasIndex in atlases.indices {
            if let idx = atlases[atlasIndex].freePlacements.firstIndex(where: { $0.w == width && $0.h == height }) {
                let placement = atlases[atlasIndex].freePlacements.remove(at: idx)
                enqueue(placement.x, placement.y, atlasIndex)
                return placement
            }
        }
        // Allocate within an existing atlas.
        for atlasIndex in atlases.indices {
            if let rect = allocate(in: &atlases[atlasIndex], width: width, height: height) {
                let placement = NativeUIImageAtlasPlacement(atlasIndex: atlasIndex, x: rect.x, y: rect.y, w: width, h: height)
                enqueue(rect.x, rect.y, atlasIndex)
                return placement
            }
        }
        // Otherwise create a new atlas texture.
        let texture = try TextureResource(device: device, descriptor: TextureDescriptor(width: Self.atlasSize, height: Self.atlasSize,
            format: .rgba8Unorm, usage: [.sampled, .transferDestination, .transferSource],
            label: "native-ui-atlas-\(atlases.count)"))
        var atlas = NativeUIImageAtlas(texture: texture, bindingSet: nil, size: Self.atlasSize)
        guard let rect = allocate(in: &atlas, width: width, height: height) else { return nil }
        atlases.append(atlas)
        let placement = NativeUIImageAtlasPlacement(atlasIndex: atlases.count - 1, x: rect.x, y: rect.y, w: width, h: height)
        enqueue(rect.x, rect.y, atlases.count - 1)
        return placement
    }

    private func allocate(in atlas: inout NativeUIImageAtlas, width: Int, height: Int) -> (x: Int, y: Int)? {
        let pw = width + 2, ph = height + 2
        if atlas.cursorX + pw > atlas.size {
            atlas.cursorX = 0
            atlas.cursorY += atlas.shelfHeight
            atlas.shelfHeight = 0
        }
        if atlas.cursorY + ph > atlas.size { return nil }
        let x = atlas.cursorX, y = atlas.cursorY
        atlas.cursorX += pw
        atlas.shelfHeight = max(atlas.shelfHeight, ph)
        return (x, y)
    }

    /// Returns the atlas sub-rectangle (inner image rect) and atlas size needed
    /// to remap a batch's UVs, or `nil` when the texture is not atlased.
    func atlasRemap(for textureID: TextureID) -> (x: Int, y: Int, w: Int, h: Int, size: Int)? {
        guard let placement = placements[textureID] else { return nil }
        return (placement.x, placement.y, placement.w, placement.h, atlases[placement.atlasIndex].size)
    }

    /// Whether any image asset has been packed into an atlas this session. When
    /// false the renderer uploads the original vertex buffer untouched.
    var hasAtlasedPlacements: Bool { !placements.isEmpty }

    /// Rewrites UV coordinates for atlased image batches so they sample the
    /// correct atlas sub-rectangle. Non-atlased batches (and solid `-1` UVs) are
    /// left untouched. Returns a copy of the vertex array.
    func remapAtlasUVs(list: DrawList) -> [UIVertex] {
        var vertices = list.vertices
        for batch in list.batches {
            guard let remap = atlasRemap(for: batch.textureID), batch.indexCount > 0 else { continue }
            let size = Float(remap.size)
            let x0 = Float(remap.x + 1), y0 = Float(remap.y + 1)
            let w = Float(remap.w), h = Float(remap.h)
            let start = Int(batch.indexOffset)
            let end = start + Int(batch.indexCount)
            for i in start..<end {
                let vi = Int(list.indices[i])
                // Read the original vertex: a shared vertex (fan centre, strip
                // seam) appears many times in one index range, and remapping the
                // already-remapped copy would compound the mapping.
                var v = list.vertices[vi]
                // `u` carries a mode sentinel ahead of the real UV: +10 for color
                // images, +20 for alpha masks, -1 for untextured shapes. Only the
                // sub-integer part addresses the texture, so remap that and keep
                // the sentinel the shader decodes.
                guard let base = Self.texturedModeBase(v.u) else { continue }
                v.u = base + (x0 + (v.u - base) * w) / size
                v.v = (y0 + v.v * h) / size
                vertices[vi] = v
            }
        }
        return vertices
    }

    /// Returns the encoded mode offset of a textured vertex's `u`, or `nil` for
    /// untextured geometry that must not be remapped.
    ///
    /// The bands are deliberately wider than the nominal `[base, base + 1]` UV
    /// range: tessellated rounded corners can overshoot by a float epsilon, and
    /// rejecting those vertices would leave them sampling outside the image.
    private static func texturedModeBase(_ u: Float) -> Float? {
        if u >= 15 { return 20 }
        if u >= 5 { return 10 }
        return nil
    }

    /// Builds transient-buffer uploads for any pending atlas placements. Called
    /// once per recorded frame; pending work is consumed so steady-state frames
    /// upload nothing.
    /// Builds transient-buffer uploads for queued atlas placements. The queue is
    /// left intact; `commitAtlasUploads(through:)` clears it only after the
    /// recording that carried these uploads was submitted successfully.
    func buildAtlasUploads() throws -> (uploads: [TextureBufferUpload], bytes: Int, sequence: UInt64) {
        guard !pendingAtlasUploads.isEmpty else { return ([], 0, 0) }
        var result: [TextureBufferUpload] = [], bytes = 0, sequence: UInt64 = 0
        for upload in pendingAtlasUploads {
            let location = try device.uploadTransient(upload.pixels)
            var uploadCommand = TextureBufferUpload(buffer: location.buffer, bytesPerRow: upload.region.width * 4,
                texture: atlases[upload.atlasIndex].texture.texture, region: upload.region)
            uploadCommand.offset = location.offset
            result.append(uploadCommand)
            bytes += upload.logicalBytes
            sequence = upload.sequence
        }
        return (result, bytes, sequence)
    }

    /// Releases queued atlas uploads after their recording was submitted.
    func commitAtlasUploads(through sequence: UInt64) {
        guard sequence > 0 else { return }
        pendingAtlasUploads.removeAll { $0.sequence <= sequence }
    }

    /// Resolves the binding set used to sample `textureID`: an atlas binding set
    /// for packed image assets, the per-asset set, or the solid-color fallback.
    func bindingSet(for textureID: TextureID) -> BindingSet {
        if let placement = placements[textureID] {
            let index = placement.atlasIndex
            if let existing = atlases[index].bindingSet { return existing }
            let set = try! device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 1, resource: .texture(atlases[index].texture.texture)),
                BindingSetEntry(slot: 2, resource: .sampler(shaders.sampler))
            ]))
            atlases[index].bindingSet = set
            return set
        }
        if let slot = textures[textureID] {
            if let existing = slot.cachedBindingSet { return existing }
            let set = try! device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 1, resource: .texture(slot.resource.texture)),
                BindingSetEntry(slot: 2, resource: .sampler(shaders.sampler))
            ]))
            slot.cachedBindingSet = set
            return set
        }
        if let existing = fallback.cachedBindingSet { return existing }
        let set = try! device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 1, resource: .texture(fallback.resource.texture)),
            BindingSetEntry(slot: 2, resource: .sampler(shaders.sampler))
        ]))
        fallback.cachedBindingSet = set
        return set
    }

    func synchronize(from source: NativeUITextureStore) throws {
        guard source.device === device else { throw RHIError.invalidArgument("UI texture synchronization requires the same device") }
        textures = source.textures
        assetResidency = source.assetResidency
        atlases = source.atlases
        placements = source.placements
    }

    /// Copies `pixels` into a `(width+2)×(height+2)` buffer, duplicating the
    /// 1px edge border so the atlas padding ring matches the image edge and thus
    /// reproduces clamp-to-edge sampling of a standalone texture.
    private static func paddedEdgePixels(pixels: Data, width: Int, height: Int) -> Data {
        let outWidth = width + 2, outHeight = height + 2
        var out = Data(count: outWidth * outHeight * 4)
        out.withUnsafeMutableBytes { destination in
            let dst = destination.bindMemory(to: UInt8.self)
            pixels.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                for yy in 0..<outHeight {
                    let sy = min(max(yy - 1, 0), height - 1)
                    for xx in 0..<outWidth {
                        let sx = min(max(xx - 1, 0), width - 1)
                        let di = (yy * outWidth + xx) * 4
                        let si = (sy * width + sx) * 4
                        dst[di] = src[si]; dst[di + 1] = src[si + 1]
                        dst[di + 2] = src[si + 2]; dst[di + 3] = src[si + 3]
                    }
                }
            }
        }
        return out
    }
}
