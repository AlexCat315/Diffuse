import NativeRHI

/// Rendered extent and allocated capacity. Grow-only scene targets are sampled
/// only inside the used region; padding must never appear in a viewport.
public struct ViewportSamplingRegion: Sendable, Equatable {
    public var size = RenderDrawableSize(width: 0, height: 0)
    public var capacity = RenderDrawableSize(width: 0, height: 0)

    public init() {}
    public init(size: RenderDrawableSize, capacity: RenderDrawableSize) {
        self.size = size
        self.capacity = capacity
    }
    public var isValid: Bool {
        size.width > 0 && size.height > 0 && size.width <= capacity.width && size.height <= capacity.height
    }
    public var uvMax: SIMD2<Float> {
        guard isValid else { return .zero }
        return SIMD2(Float(size.width) / Float(capacity.width), Float(size.height) / Float(capacity.height))
    }
}

public struct ViewportSurfaceState: Sendable, Equatable {
    /// Stable while the producer uses the same texture. IDs are local to a
    /// producer; consumers identify the owned image rather than this number.
    public var surfaceID: UInt64 = 0
    public var image: ViewportImage? = nil
    public var region = ViewportSamplingRegion()

    public init() {}
    public init(surfaceID: UInt64, image: ViewportImage? = nil, region: ViewportSamplingRegion) {
        self.surfaceID = surfaceID
        self.image = image
        self.region = region
    }
    public var isValid: Bool {
        guard surfaceID != 0, let image, region.isValid else { return false }
        if case .native(let resource) = image.storage {
            let descriptor = resource.descriptor
            return descriptor.dimension == .texture2D && descriptor.sampleCount == 1 && descriptor.usage.contains(.sampled)
                && descriptor.width == Int(region.capacity.width) && descriptor.height == Int(region.capacity.height)
        }
        return true
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.surfaceID == rhs.surfaceID && lhs.image === rhs.image && lhs.region == rhs.region
    }
}
