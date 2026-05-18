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

    public init() {}

    public func publish(_ snapshot: DrawListSnapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }

    public func consume() -> DrawListSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
