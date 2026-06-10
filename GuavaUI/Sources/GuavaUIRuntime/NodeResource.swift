/// An external registration owned by a node's lifetime.
///
/// In-place refactor 规则 2 (坏味 #4): anything a node registers with the
/// outside world — a portal/overlay entry today, pointer capture / input
/// handlers / focus later — is modelled as a `NodeResource` attached to that
/// node. When the node leaves the tree, for ANY reason (popover closed, parent
/// removed, panel swapped, a conditional dropping the subtree),
/// `Node.removeChild` walks the departing subtree and calls `unmount` on every
/// resource. Cleanup is part of the node's lifecycle, not a side-effect some
/// modifier has to remember to run — so leaking an entry is not expressible.
///
/// Mirrors GuavaKit's `NodeResource`. `mount` / `unmount` take only the node
/// for now; Phase 3 threads the per-window `UIScope` through so a resource
/// reaches a scoped registry rather than a process-global one.
public protocol NodeResource: AnyObject {
    /// Called when the resource is attached to a node (`Node.addResource`).
    func mount(node: Node)
    /// Called when the owning node leaves the tree, for ANY reason. Must
    /// release everything the resource acquired, and must be idempotent
    /// (teardown may legitimately reach it more than once).
    func unmount(node: Node)
}
