internal import Foundation
internal import CoveUIRuntime

/// Thread-safe channel for passing a rendered `DrawListSnapshot` from the
/// main-thread ViewGraph pipeline to the render-thread `DrawListRenderer`.
///
/// The main thread calls `publish(_:)` after each tick; the render thread
/// calls `consume()` inside `recordInGameUI`. The render thread always sees
/// the most recent published snapshot (last-write-wins — no queuing needed
/// for an overlay that refreshes every frame).
final class InGameDrawListSource: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DrawListSnapshot?
    private var planes: [GlyphAtlasFormat: DrawListAtlasDirty] = [:]
    private var dirtyPlanes: Set<GlyphAtlasFormat> = []

    init() {}

    func publish(_ snapshot: DrawListSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        for update in snapshot.atlasUpdates { merge(update) }
        latest = snapshot
    }

    func consume() -> DrawListSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard var snapshot = latest else { return nil }
        snapshot.atlasUpdates = [GlyphAtlasFormat.alpha, .color].compactMap {
            dirtyPlanes.contains($0) ? planes[$0] : nil
        }
        dirtyPlanes.removeAll(keepingCapacity: true)
        return snapshot
    }

    /// Each plane retains the complete texture, including patches from
    /// frames skipped during GPU startup. Geometry still uses the latest frame.
    private func merge(_ update: DrawListAtlasDirty) {
        let stride = update.format.bytesPerPixel
        guard update.textureID != .none,
              update.textureWidth > 0, update.textureHeight > 0,
              update.textureWidth <= 16_384, update.textureHeight <= 16_384,
              UInt64(update.textureWidth) * UInt64(update.textureHeight) * UInt64(stride) <= 64 * 1024 * 1024,
              update.regionWidth > 0, update.regionHeight > 0,
              UInt64(update.regionX) + UInt64(update.regionWidth) <= UInt64(update.textureWidth),
              UInt64(update.regionY) + UInt64(update.regionHeight) <= UInt64(update.textureHeight),
              UInt64(update.pixels.count) == UInt64(update.regionWidth) * UInt64(update.regionHeight) * UInt64(stride)
        else { return }
        var merged = planes.removeValue(forKey: update.format)
        if merged?.textureID != update.textureID || merged?.textureWidth != update.textureWidth || merged?.textureHeight != update.textureHeight {
            merged = DrawListAtlasDirty(
                pixels: [UInt8](repeating: 0, count: Int(update.textureWidth) * Int(update.textureHeight) * stride),
                regionX: 0, regionY: 0, regionWidth: update.textureWidth, regionHeight: update.textureHeight,
                textureWidth: update.textureWidth, textureHeight: update.textureHeight,
                textureID: update.textureID, format: update.format)
        }
        guard var plane = merged else { return }
        let rowBytes = Int(update.regionWidth) * stride
        for row in 0..<Int(update.regionHeight) {
            let src = row * rowBytes
            let dst = ((row + Int(update.regionY)) * Int(update.textureWidth) + Int(update.regionX)) * stride
            plane.pixels.replaceSubrange(dst..<(dst + rowBytes), with: update.pixels[src..<(src + rowBytes)])
        }
        planes[update.format] = plane
        dirtyPlanes.insert(update.format)
    }
}
