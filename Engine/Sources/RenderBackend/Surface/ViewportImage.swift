import NativeRHI

/// An owned scene output. Surface snapshots and UI geometry retain this lease;
/// replacing a renderer's target does not invalidate an older snapshot.
public final class ViewportImage: @unchecked Sendable {
    // The resource is immutable; Device serializes access and destruction.
    public let resource: TextureResource
    public init(resource: TextureResource) { self.resource = resource }
}

/// Render-thread publication state, separate from authored render settings.
struct ViewportSurfacePublication {
    private(set) var state = ViewportSurfaceState()
    private var nextID: UInt64 = 0

    mutating func publish(resource: TextureResource, region: ViewportSamplingRegion) {
        if state.image?.resource === resource {
            state.region = region
        } else {
            nextID += 1
            state = ViewportSurfaceState(surfaceID: nextID, image: ViewportImage(resource: resource), region: region)
        }
    }

    mutating func clear() { state = ViewportSurfaceState() }
}
