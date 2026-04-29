import GuavaUICompose

public struct StoreScope<Content: View>: View {
    public let store: EditorStore
    public let content: (EditorStore) -> Content

    public init(_ store: EditorStore,
                @ViewBuilder content: @escaping (EditorStore) -> Content) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        content(store)
    }
}
