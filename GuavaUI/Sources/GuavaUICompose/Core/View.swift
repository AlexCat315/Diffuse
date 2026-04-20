/// The fundamental view protocol — every UI element conforms to `View`.
///
/// A view describes part of the UI by composing other views in its `body`.
/// `body` is read by the `ViewGraph` to materialise nodes; never call it directly.
///
/// Example:
/// ```swift
/// struct Greeting: View {
///     let name: String
///     var body: some View {
///         Text("Hello, \(name)")
///     }
/// }
/// ```
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// `Never` conforms to `View` so primitive views can use it as their `Body`
/// (e.g. `Text` / `Image` whose body is meaningless).
extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }
}
