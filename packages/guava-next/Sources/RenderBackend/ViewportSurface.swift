import Foundation

public struct ViewportSurfaceState: Sendable, Equatable {
    public var surfaceID: UInt64
    public var width: UInt32
    public var height: UInt32
    public var zeroCopy: Bool

    public init(
        surfaceID: UInt64 = 0,
        width: UInt32 = 0,
        height: UInt32 = 0,
        zeroCopy: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.zeroCopy = zeroCopy
    }

    public var isValid: Bool {
        surfaceID != 0 && width > 0 && height > 0
    }
}
