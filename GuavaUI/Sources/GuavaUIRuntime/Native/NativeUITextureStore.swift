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

final class NativeUITextureStore {
    let device: Device
    let fallback: NativeUITextureSlot
    var textures: [TextureID: NativeUITextureSlot] = [:]

    init(device: Device) throws {
        self.device = device
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

    func synchronize(from source: NativeUITextureStore) throws {
        guard source.device === device else { throw RHIError.invalidArgument("UI texture synchronization requires the same device") }
        textures = source.textures
    }
}
