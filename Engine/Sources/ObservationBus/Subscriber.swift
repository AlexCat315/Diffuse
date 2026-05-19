import Dispatch
import Foundation

/// RAII lifetime token. Unsubscribes from the bus when cancelled or deallocated.
public final class SubscriberToken: @unchecked Sendable {
    public let subscriptionID: String

    private let bus: ObservationBus
    private let lock = NSLock()
    private var _cancelled = false
    private var timerSource: DispatchSourceTimer?

    init(bus: ObservationBus, subscriptionID: String, timerSource: DispatchSourceTimer? = nil) {
        self.bus = bus
        self.subscriptionID = subscriptionID
        self.timerSource = timerSource
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        guard !_cancelled else { lock.unlock(); return }
        _cancelled = true
        let source = timerSource
        timerSource = nil
        lock.unlock()

        source?.cancel()
        bus.unsubscribe(subscriptionID)
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
}

extension ObservationBus {
    /// Push-based subscription. The handler is called on `queue` whenever new events arrive,
    /// polled at `interval`. Returns a `SubscriberToken`; cancel or release it to unsubscribe.
    @discardableResult
    public func sink(spec: SubscriptionSpec,
                     queue: DispatchQueue = .global(qos: .utility),
                     interval: DispatchTimeInterval = .milliseconds(16),
                     handler: @escaping @Sendable ([EventEnvelope]) -> Void) -> SubscriberToken {
        let subscription = subscribe(spec: spec)
        let source = DispatchSource.makeTimerSource(queue: queue)
        let token = SubscriberToken(bus: self, subscriptionID: subscription.id, timerSource: source)

        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak subscription] in
            guard let subscription else { return }
            let events = subscription.drain()
            if !events.isEmpty {
                handler(events)
            }
        }
        source.resume()
        return token
    }

    /// Returns an `AsyncStream` that yields events matching `spec`.
    /// The stream ends when the `SubscriberToken` held by the caller is cancelled or released.
    /// Pass a `continuation` handler to receive the token needed to stop the stream.
    public func events(spec: SubscriptionSpec,
                       bufferingPolicy: AsyncStream<EventEnvelope>.Continuation.BufferingPolicy = .bufferingNewest(64),
                       pollingInterval: DispatchTimeInterval = .milliseconds(16),
                       onToken: (@Sendable (SubscriberToken) -> Void)? = nil) -> AsyncStream<EventEnvelope> {
        let subscription = subscribe(spec: spec)
        var token: SubscriberToken?
        let stream = AsyncStream(EventEnvelope.self, bufferingPolicy: bufferingPolicy) { continuation in
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let t = SubscriberToken(bus: self, subscriptionID: subscription.id, timerSource: source)
            token = t

            source.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
            source.setEventHandler { [weak subscription] in
                guard let subscription else {
                    continuation.finish()
                    return
                }
                subscription.drain().forEach { continuation.yield($0) }
            }
            source.resume()

            continuation.onTermination = { @Sendable _ in t.cancel() }
        }
        if let token { onToken?(token) }
        return stream
    }
}
