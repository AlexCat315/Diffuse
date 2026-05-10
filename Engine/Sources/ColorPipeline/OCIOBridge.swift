import Foundation

/// Stub OCIO bridge. The native OpenColorIO library is no longer linked into the
/// engine — color space transforms fall back to the gamma path in `ViewTransform`.
/// Public API is preserved so callers don't need to change.
public final class OCIOBridge: @unchecked Sendable {
    public init?(configPath: String) { return nil }

    public var isAvailable: Bool { false }

    public var colorSpaceNames: [String] { [] }

    public func applyTransform(
        inputColorSpace: String,
        outputColorSpace: String,
        viewTransform: String? = nil,
        display: String? = nil,
        exposure: Float = 0,
        gamma: Float = 1,
        to pixels: inout [Float],
        width: Int32,
        height: Int32
    ) -> Bool {
        false
    }
}
