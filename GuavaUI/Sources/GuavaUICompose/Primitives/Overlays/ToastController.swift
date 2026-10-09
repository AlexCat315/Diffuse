import Foundation
import GuavaUIRuntime

public struct ToastNotification: Identifiable {
    public let id: String
    public let title: String
    public var message = ""
    public var tone: StatusTone = .info
    /// Nil keeps a notification visible until explicitly dismissed.
    public var duration: Double? = 5
    public var isDismissible = true
    public init(_ title: String, id: String = UUID().uuidString, configure: (inout Self) -> Void = { _ in }) {
        self.id = id; self.title = title; configure(&self)
        duration = duration.map { $0.isFinite ? max(0, $0) : 5 }
    }
}

private struct ToastSession {
    var notification: ToastNotification
    var remaining: Double?
    var isPaused = false
}

/// Window/application-owned queue with stable-ID replacement, bounded visibility and deterministic time.
public final class ToastController {
    public let maxVisible: Int
    private var sessions: [ToastSession] = []
    private let registrar = ObservableStateRegistrar()
    public init(maxVisible: Int = 3) { self.maxVisible = max(1, maxVisible) }
    public var notifications: [ToastNotification] {
        registrar.access("toasts"); return sessions.prefix(maxVisible).map(\.notification)
    }
    public var queuedCount: Int { registrar.access("toasts"); return max(0, sessions.count - maxVisible) }
    var needsClock: Bool { sessions.prefix(maxVisible).contains { !$0.isPaused && $0.remaining != nil } }
    public func post(_ notification: ToastNotification) {
        let session = ToastSession(notification: notification, remaining: notification.duration)
        if let index = sessions.firstIndex(where: { $0.notification.id == notification.id }) { sessions[index] = session }
        else { sessions.append(session) }
        registrar.invalidate("toasts")
    }
    public func dismiss(_ id: String) {
        guard sessions.contains(where: { $0.notification.id == id }) else { return }
        sessions.removeAll { $0.notification.id == id }; registrar.invalidate("toasts")
    }
    public func setPaused(_ paused: Bool, id: String) {
        guard let index = sessions.firstIndex(where: { $0.notification.id == id }), sessions[index].isPaused != paused else { return }
        sessions[index].isPaused = paused; registrar.invalidate("toasts")
    }
    public func advance(by seconds: Double) {
        guard seconds.isFinite && seconds >= 0 else { return }
        let visibleIDs = Set(sessions.prefix(maxVisible).map { $0.notification.id })
        for index in sessions.indices where visibleIDs.contains(sessions[index].notification.id) && !sessions[index].isPaused {
            if let remaining = sessions[index].remaining { sessions[index].remaining = max(0, remaining - seconds) }
        }
        let previousCount = sessions.count
        sessions.removeAll { $0.remaining == 0 && !$0.isPaused && visibleIDs.contains($0.notification.id) }
        if previousCount != sessions.count { registrar.invalidate("toasts") }
    }
    public func clear() { guard !sessions.isEmpty else { return }; sessions.removeAll(); registrar.invalidate("toasts") }
}
