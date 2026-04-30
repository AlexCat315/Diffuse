import EditorCore
import Foundation
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

    @Test("Selection primary modifier behavior decodes legacy command key")
    func primaryModifierBehaviorDecodesLegacyCommandKey() throws {
        let data = Data(#"{"cmdSelectBehavior":"toggle"}"#.utf8)

        let state = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(state.primarySelectBehavior == .toggle)
    }

    @Test("Selection primary modifier behavior encodes platform-neutral key")
    func primaryModifierBehaviorEncodesPlatformNeutralKey() throws {
        let state = EditorState(primarySelectBehavior: .toggle)

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""primarySelectBehavior":"toggle""#))
        #expect(!json.contains("cmdSelectBehavior"))
    }
}
