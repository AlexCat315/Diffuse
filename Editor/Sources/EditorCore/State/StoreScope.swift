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

    public init(_ store: EditorStore,
                @ViewBuilder content: @escaping (EditorStore) -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        let _ = version
        let bind = $version
        EditorStoreSubscription.acquire(store: store, bind: bind)
        return content(store)
    }
}

/// 进程内订阅去重表。每个 `EditorStore` 在表里只保留最新的 binding，
/// 重复订阅会替换旧句柄而不是叠加，避免 `@State` 写入呈倍数放大。
///
/// `View.body` 在协议层是 nonisolated，但运行期始终位于主线程；和
/// `ControllerSubscription` 同样的契约：通过 `nonisolated(unsafe)`
/// 暴露存储，调用方必须保证只在主线程访问。
enum EditorStoreSubscription {
    nonisolated(unsafe) private static var tokens: [ObjectIdentifier: EditorStore.SubscriptionToken] = [:]

    static func acquire(store: EditorStore, bind: Binding<UInt64>) {
        let key = ObjectIdentifier(store)
        if let existing = tokens[key] {
            store.unsubscribe(existing)
        }
        let token = store.subscribe { s in
            if bind.wrappedValue != s.version {
                bind.wrappedValue = s.version
            }
        }
        tokens[key] = token
    }
}
