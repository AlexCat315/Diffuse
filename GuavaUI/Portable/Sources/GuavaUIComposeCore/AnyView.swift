/// Type-eraser for `View`. Stores an arbitrary view value; `ViewGraph`
/// recognises `AnyView` and recurses into `storage` directly, so user code can
/// hand around heterogeneous view trees without fighting the type system.
public struct AnyView: View {
    public let storage: any View

    public init<V: View>(_ view: V) {
        if let already = view as? AnyView {
            self.storage = already.storage
        } else {
            self.storage = view
        }
    }

    public init(_erased view: any View) {
        if let already = view as? AnyView {
            self.storage = already.storage
        } else {
            self.storage = view
        }
    }

    public var body: Never {
        fatalError("AnyView is materialised through ViewGraph, not body")
    }
}
