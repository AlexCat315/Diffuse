import GuavaUICompose
import GuavaUIRuntime

/// 让任意 View 子树跟随 `EditorStore.version` 重组的小工具。
///
/// 使用方式：
///
/// ```swift
/// StoreScope(store) { store in
///     Text(store.state.connected ? "Connected" : "Disconnected")
/// }
/// ```
///
/// 内部通过 `@State` cell + 进程内去重表订阅 `store.subscribe(...)`，
/// 避免 panel 在每次重组里反复挂载 / 卸载订阅句柄。
public struct StoreScope<Content: View>: View {
    public let store: EditorStore
    public let content: (EditorStore) -> Content

    @State private var version: UInt64 = 0
    @State private var subscriptionID = EditorStoreSubscriptionID()

    public init(_ store: EditorStore,
                @ViewBuilder content: @escaping (EditorStore) -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        let _ = version
        let bind = $version
        EditorStoreSubscription.acquire(store: store,
                                        subscriptionID: subscriptionID,
                                        bind: bind)
        return content(store)
    }
}

private final class EditorStoreSubscriptionID: @unchecked Sendable {}

/// 进程内订阅去重表。每个 `StoreScope` 在表里保留自己的 binding；
/// 同一个 scope 重组时替换旧句柄，不会把其它面板的订阅覆盖掉。
///
/// `View.body` 在协议层是 nonisolated，但运行期始终位于主线程；和
/// `ControllerSubscription` 同样的契约：通过 `nonisolated(unsafe)`
/// 暴露存储，调用方必须保证只在主线程访问。
enum EditorStoreSubscription {
    nonisolated(unsafe) private static var tokens: [ObjectIdentifier: [ObjectIdentifier: EditorStore.SubscriptionToken]] = [:]

    fileprivate static func acquire(store: EditorStore,
                                    subscriptionID: EditorStoreSubscriptionID,
                                    bind: Binding<UInt64>) {
        let storeKey = ObjectIdentifier(store)
        let scopeKey = ObjectIdentifier(subscriptionID)
        if let existing = tokens[storeKey]?[scopeKey] {
            store.unsubscribe(existing)
        }
        let token = store.subscribe { s in
            if bind.wrappedValue != s.version {
                bind.wrappedValue = s.version
            }
        }
        var storeTokens = tokens[storeKey] ?? [:]
        storeTokens[scopeKey] = token
        tokens[storeKey] = storeTokens
    }
}
