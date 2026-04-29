import EditorCore
import Testing

@Suite("EditorStore")
struct EditorStoreTests {
    @Test("No-op actions do not notify subscribers")
    func noOpActionsDoNotNotifySubscribers() {
        let store = EditorStore(state: EditorState(connected: true))
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.setConnected(true))

        #expect(store.version == 0)
        #expect(notifications == 0)
    }

    @Test("Changed actions increment version and notify subscribers")
    func changedActionsNotifySubscribers() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.setConnected(true))

        #expect(store.version == 1)
        #expect(notifications == 1)
        #expect(store.connected)
    }

    @Test("Console changes notify subscribers")
    func consoleChangesNotifySubscribers() {
        let store = EditorStore()
        var notifications = 0
        _ = store.subscribe { _ in notifications += 1 }

        store.dispatch(.appendConsoleMessage("Built project"))

        #expect(store.version == 1)
        #expect(notifications == 1)
        #expect(store.latestConsoleEntry?.message == "Built project")
    }
}
