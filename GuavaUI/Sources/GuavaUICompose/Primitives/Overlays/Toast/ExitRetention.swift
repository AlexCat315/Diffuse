import GuavaUIRuntime

/// Only the host retains exiting visuals. The controller's queue and expiry
/// remain immediately observable and independent of animation progress.
final class ToastPresentation {
    struct Entry {
        var notification: ToastNotification
        var isVisible: Bool
        var revision: Int
    }
    private var entries: [Entry] = []
    private var revision = 0
    private let registrar = ObservableStateRegistrar()

    func update(_ notifications: [ToastNotification], limit: Int) -> [Entry] {
        registrar.access("presentation")
        let active = Dictionary(uniqueKeysWithValues: notifications.map { ($0.id, $0) })
        let previousIDs = Set(entries.map { $0.notification.id })
        entries = entries.map { previous in
            var entry = previous
            if let notification = active[entry.notification.id] { entry.notification = notification }
            let visible = active[entry.notification.id] != nil
            if visible != entry.isVisible {
                revision &+= 1; entry.revision = revision; entry.isVisible = visible
            }
            return entry
        }
        for notification in notifications where !previousIDs.contains(notification.id) {
            revision &+= 1
            entries.append(Entry(notification: notification, isVisible: true, revision: revision))
        }
        // Rapid dismiss/post loops must not accumulate an unbounded exit tree.
        let exiting = Set(entries.filter { !$0.isVisible }.suffix(limit).map { $0.notification.id })
        entries.removeAll { !$0.isVisible && !exiting.contains($0.notification.id) }
        return entries
    }

    func remove(id: String, revision: Int) {
        guard entries.contains(where: { $0.notification.id == id && $0.revision == revision && !$0.isVisible }) else { return }
        entries.removeAll { $0.notification.id == id && $0.revision == revision }
        registrar.invalidate("presentation")
    }
}
