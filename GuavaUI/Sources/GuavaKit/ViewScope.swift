// A persistent home for one user view's `@State`, identified by its path in the
// view tree (the sequence of child indices from the root). Same path on the next
// recompose ⇒ same scope ⇒ state survives. When a subtree is removed, its scopes
// are dropped (see `ViewGraph.dropScopes`).

/// A view-tree path: child indices from the root. Stable across recomposes as
/// long as the structure at each level is stable.
public struct ScopePath: Hashable, Sendable {
    public let indices: [Int]
    init(_ indices: [Int]) { self.indices = indices }
    func appending(_ i: Int) -> ScopePath { ScopePath(indices + [i]) }
    /// Does this path start with `prefix` (i.e. live under that subtree)?
    func hasPrefix(_ prefix: ScopePath) -> Bool {
        guard indices.count >= prefix.indices.count else { return false }
        return Array(indices.prefix(prefix.indices.count)) == prefix.indices
    }
    static let root = ScopePath([])
}

final class ViewScope {
    let path: ScopePath
    weak var graph: ViewGraph?

    /// The current view value (replaced each recompose; relinked to the boxes).
    var view: any View

    private var boxes: [Any?] = []

    init(path: ScopePath, view: any View, graph: ViewGraph) {
        self.path = path
        self.view = view
        self.graph = graph
    }

    func stateBox(at index: Int) -> Any? {
        index < boxes.count ? boxes[index] : nil
    }
    func setStateBox(_ box: Any, at index: Int) {
        while boxes.count <= index { boxes.append(nil) }
        boxes[index] = box
    }

    /// A `@State` write happened — schedule a recompose.
    func invalidate() {
        graph?.scopeDidInvalidate(self)
    }
}
