import NativeRHI
import RHIWGPU

/// An owned scene output. Surface snapshots and UI geometry retain this lease;
/// replacing a renderer's target does not invalidate an older snapshot.
public final class ViewportImage: Sendable {
    // Both wrappers have immutable ownership. NativeRHI Device access is
    // locked; the WGPU native object is thread-safe. Transferring the lease
    // does not allow concurrent mutation of renderer/frame state.
    public enum Storage: @unchecked Sendable, Equatable {
        case native(TextureResource)
        case wgpu(GPUTexture)

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.native(let a), .native(let b)): a === b
            case (.wgpu(let a), .wgpu(let b)): a === b
            default: false
            }
        }
    }

    public let storage: Storage
    public init(storage: Storage) { self.storage = storage }
}

/// Render-thread publication state, separate from authored render settings.
struct ViewportSurfacePublication {
    private(set) var state = ViewportSurfaceState()
    private var nextID: UInt64 = 0

    mutating func publish(storage: ViewportImage.Storage, region: ViewportSamplingRegion) {
        if state.image?.storage == storage {
            state.region = region
        } else {
            nextID += 1
            state = ViewportSurfaceState(surfaceID: nextID, image: ViewportImage(storage: storage), region: region)
        }
    }

    mutating func clear() { state = ViewportSurfaceState() }
}
