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

    public init(pixels: [UInt8], regionX: UInt32, regionY: UInt32,
                regionWidth: UInt32, regionHeight: UInt32,
                textureWidth: UInt32, textureHeight: UInt32,
                textureID: TextureID) {
        self.pixels = pixels
        self.regionX = regionX
        self.regionY = regionY
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.textureID = textureID
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
    public var atlasDirty: DrawListAtlasDirty?

    public var isEmpty: Bool { batches.isEmpty }

    public init(vertices: [UIVertex], indices: [UInt32], batches: [DrawBatch],
                viewportWidth: UInt32, viewportHeight: UInt32,
                logicalWidth: Float, logicalHeight: Float,
                atlasDirty: DrawListAtlasDirty? = nil) {
        self.vertices = vertices
        self.indices = indices
        self.batches = batches
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.atlasDirty = atlasDirty
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
    private var atlas: DrawListAtlasDirty?
    private var atlasNeedsUpload = false

    public init() {}

    public func publish(_ snapshot: DrawListSnapshot) {
        lock.lock()
        if let dirty = snapshot.atlasDirty,
           dirty.textureWidth > 0, dirty.textureHeight > 0,
           dirty.textureWidth <= 16_384, dirty.textureHeight <= 16_384,
           UInt64(dirty.textureWidth) * UInt64(dirty.textureHeight) <= 64 * 1024 * 1024,
           UInt64(dirty.regionX) + UInt64(dirty.regionWidth) <= UInt64(dirty.textureWidth),
           UInt64(dirty.regionY) + UInt64(dirty.regionHeight) <= UInt64(dirty.textureHeight),
           dirty.pixels.count == Int(UInt64(dirty.regionWidth) * UInt64(dirty.regionHeight)) {
            // A render thread can miss several main-thread frames during GPU
            // startup. Preserve all atlas patches rather than overwriting the
            // only upload with a newer frame containing no dirty glyphs.
            if atlas?.textureID != dirty.textureID || atlas?.textureWidth != dirty.textureWidth || atlas?.textureHeight != dirty.textureHeight {
                atlas = DrawListAtlasDirty(pixels: [UInt8](repeating: 0, count: Int(dirty.textureWidth * dirty.textureHeight)),
                    regionX: 0, regionY: 0, regionWidth: dirty.textureWidth, regionHeight: dirty.textureHeight,
                    textureWidth: dirty.textureWidth, textureHeight: dirty.textureHeight, textureID: dirty.textureID)
            }
            if var merged = atlas {
                for row in 0..<Int(dirty.regionHeight) {
                    let src = row * Int(dirty.regionWidth)
                    let dst = (row + Int(dirty.regionY)) * Int(dirty.textureWidth) + Int(dirty.regionX)
                    merged.pixels.replaceSubrange(dst..<(dst + Int(dirty.regionWidth)), with: dirty.pixels[src..<(src + Int(dirty.regionWidth))])
                }
                atlas = merged
                atlasNeedsUpload = true
            }
        }
        latest = snapshot
        lock.unlock()
    }

    public func consume() -> DrawListSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard var snapshot = latest else { return nil }
        snapshot.atlasDirty = atlasNeedsUpload ? atlas : nil
        atlasNeedsUpload = false
        return snapshot
    }
}
