import Foundation

public struct ViewportSurfaceState: Sendable, Equatable {
    /// Monotonically-increasing identifier published by the engine each
    /// time the underlying offscreen texture is replaced. Stable across
    /// snapshots and never reused, so consumers can tell new from stale.
    public var surfaceID: UInt64
    /// Raw `GPUTexture` opaque pointer kept alive by the engine for as
    /// long as `surfaceID` is the published one. Consumers reconstruct the
    /// texture via `Unmanaged<GPUTexture>.fromOpaque(...)`.
    public var handle: UInt64
    /// Rendered (used) extent in pixels. May be smaller than the backing
    /// texture: targets are allocated grow-only so panel resizes don't
    /// recreate the frame graph every frame.
    public var width: UInt32
    public var height: UInt32
    /// Backing texture extent in pixels. Consumers sampling the surface must
    /// crop to `width / textureWidth` × `height / textureHeight`.
    public var textureWidth: UInt32
    public var textureHeight: UInt32
    public var zeroCopy: Bool

    public init(
        surfaceID: UInt64 = 0,
        handle: UInt64 = 0,
        width: UInt32 = 0,
        height: UInt32 = 0,
        textureWidth: UInt32 = 0,
        textureHeight: UInt32 = 0,
        zeroCopy: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.handle = handle
        self.width = width
        self.height = height
        self.textureWidth = textureWidth == 0 ? width : textureWidth
        self.textureHeight = textureHeight == 0 ? height : textureHeight
        self.zeroCopy = zeroCopy
    }

    public var isValid: Bool {
        surfaceID != 0 && handle != 0 && width > 0 && height > 0
    }
}
