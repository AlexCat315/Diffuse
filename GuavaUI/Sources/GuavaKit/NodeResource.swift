/// An external registration owned by a node's lifetime.
///
/// This is GuavaKit's answer to the legacy portal leak. In the old stack a
/// Popover registered itself into a global registry and relied on a *modifier
/// side-effect* to unregister on close. If the subtree was torn down some other
/// way (panel relayout, conditional removal), that side-effect never ran and the
/// entry leaked — a phantom menu that swallowed clicks for every dropdown.
///
/// Here, whatever a node registers with the outside world is a `NodeResource`
/// attached to that node. `UIContext.detach` walks the subtree on removal and
/// calls `unmount` on every resource. Cleanup is part of the node's lifecycle,
/// not a thing some other code must remember to do.
public protocol NodeResource: AnyObject {
    /// Called when the owning node enters a live tree (gets a context).
    func mount(node: UINode, context: UIContext)
    /// Called when the owning node leaves the tree, for ANY reason. Must release
    /// everything `mount` acquired.
    func unmount(node: UINode, context: UIContext)
}
