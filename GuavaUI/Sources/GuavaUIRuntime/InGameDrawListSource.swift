import Foundation

/// Atlas upload payload captured on the main thread and consumed by the render thread.
public struct DrawListAtlasDirty: Sendable {
    public var pixels: [UInt8]
    public var regionX: UInt32
    public var regionY: UInt32
    public var regionWidth: UInt32
    public var regionHeight: UInt32
    public var textureWidth: UInt32
    public var textureHeight: UInt32
    public var textureID: TextureID
    public var format: GlyphAtlasFormat = .alpha

    public init(pixels: [UInt8], regionX: UInt32, regionY: UInt32,
                regionWidth: UInt32, regionHeight: UInt32,
                textureWidth: UInt32, textureHeight: UInt32,
                textureID: TextureID, format: GlyphAtlasFormat = .alpha) {
        self.pixels = pixels
        self.regionX = regionX
        self.regionY = regionY
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.textureID = textureID
        self.format = format
    }
}

/// Immutable snapshot of one frame's in-game UI draw commands, safe to pass
/// across the main→render thread boundary.
public struct DrawListSnapshot: Sendable {
    public var vertices: [UIVertex]
    public var indices: [UInt32]
    public var batches: [DrawBatch]
    public var viewportWidth: UInt32
    public var viewportHeight: UInt32
    public var logicalWidth: Float
    public var logicalHeight: Float
    public var atlasUpdates: [DrawListAtlasDirty] = []
    public var resources = DrawListResources()

    public var isEmpty: Bool { batches.isEmpty }

    public init(vertices: [UIVertex], indices: [UInt32], batches: [DrawBatch],
                viewportWidth: UInt32, viewportHeight: UInt32,
                logicalWidth: Float, logicalHeight: Float,
                atlasUpdates: [DrawListAtlasDirty] = [], resources: DrawListResources = .init()) {
        self.vertices = vertices
        self.indices = indices
        self.batches = batches
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.atlasUpdates = atlasUpdates
        self.resources = resources
    }
}

/// Thread-safe channel for passing a rendered `DrawListSnapshot` from the
/// main-thread ViewGraph pipeline to the render-thread `DrawListRenderer`.
///
/// The main thread calls `publish(_:)` after each tick; the render thread
/// calls `consume()` inside `renderInGameUI`. The render thread always sees
/// the most recent published snapshot (last-write-wins — no queuing needed
/// for an overlay that refreshes every frame).
public final class InGameDrawListSource: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DrawListSnapshot?
    private var planes: [GlyphAtlasFormat: DrawListAtlasDirty] = [:]
    private var dirtyPlanes: Set<GlyphAtlasFormat> = []

    public init() {}

    public func publish(_ snapshot: DrawListSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        for update in snapshot.atlasUpdates { merge(update) }
        latest = snapshot
    }

    public func consume() -> DrawListSnapshot? {
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
