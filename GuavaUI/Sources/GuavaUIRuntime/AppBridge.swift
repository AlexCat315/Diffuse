import EngineKernel
import RenderBackend

public final class PlatformEventBridge: @unchecked Sendable {
    public struct SubscriptionToken: Hashable, Sendable {
        let raw: UInt64
    }

    private var subscribers: [SubscriptionToken: (InputEvent) -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping (InputEvent) -> Void) -> SubscriptionToken {
        nextSubscriberID &+= 1
        let token = SubscriptionToken(raw: nextSubscriberID)
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        subscribers.removeValue(forKey: token)
    }

    public func publish(_ event: InputEvent) {
        for handler in subscribers.values {
            handler(event)
        }
    }
}

public protocol ViewportTextureBridge: AnyObject {
    /// Resolve a published viewport surface to a `TextureID` the renderer
    /// can sample. Geometry must retain `surface.image` for as long as it uses
    /// the returned ID, including cached layers and render-thread snapshots.
    func textureID(for surface: ViewportSurfaceState) -> TextureID?
}

public enum ViewportTextureBridgeHolder {
    nonisolated(unsafe) public static var current: ViewportTextureBridge?
}
