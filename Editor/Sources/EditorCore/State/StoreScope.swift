import GuavaUICompose
import GuavaUIRuntime

public struct StoreScope<Content: View>: View {
    public let store: EditorStore
    public let content: (EditorStore) -> Content
    private let select: ((EditorState) -> AnyHashable)?

    public init(_ store: EditorStore,
                @ViewBuilder content: @escaping (EditorStore) -> Content) {
        self.store = store
        self.content = content
        self.select = nil
    }

    public init<V: Hashable>(_ store: EditorStore,
                              select: @escaping (EditorState) -> V,
                              @ViewBuilder content: @escaping (EditorStore) -> Content) {
        self.store = store
        self.content = content
        self.select = { AnyHashable(select($0)) }
    }

    @State private var version: UInt64 = 0
    @State private var subscriptionID = EditorStoreSubscriptionID()

    public var body: some View {
        let _ = version
        let bind = $version
        EditorStoreSubscription.acquire(store: store,
                                         subscriptionID: subscriptionID,
                                         bind: bind,
                                         select: select)
        return content(store)
    }
}

private final class EditorStoreSubscriptionID: @unchecked Sendable {}

enum EditorStoreSubscription {
    nonisolated(unsafe) private static var tokens: [ObjectIdentifier: [ObjectIdentifier: EditorStore.SubscriptionToken]] = [:]
    nonisolated(unsafe) private static var lastValues: [ObjectIdentifier: AnyHashable] = [:]

    fileprivate static func acquire(store: EditorStore,
                                     subscriptionID: EditorStoreSubscriptionID,
                                     bind: Binding<UInt64>,
                                     select: ((EditorState) -> AnyHashable)?) {
        let storeKey = ObjectIdentifier(store)
        let scopeKey = ObjectIdentifier(subscriptionID)
        let valueKey = scopeKey
        if let existing = tokens[storeKey]?[scopeKey] {
            store.unsubscribe(existing)
        }
        let token = store.subscribe { s in
            if let select {
                let newValue = select(s.state)
                let old = lastValues[valueKey]
                if old == newValue { return }
                lastValues[valueKey] = newValue
            }
            if bind.wrappedValue != s.version {
                bind.wrappedValue = s.version
            }
        }
        var storeTokens = tokens[storeKey] ?? [:]
        storeTokens[scopeKey] = token
        tokens[storeKey] = storeTokens
        if bind.wrappedValue != store.version {
            if let select {
                lastValues[valueKey] = select(store.state)
            }
            bind.wrappedValue = store.version
        }
    }
}
