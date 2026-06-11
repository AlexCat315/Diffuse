import GuavaUIRuntime

/// Observe pointer hover over this view's subtree. The handler fires with
/// `true` on enter and `false` on leave; hovering a descendant (e.g. a button
/// inside the container) keeps the container hovered, because hover is
/// derived from the root→target hit path.
public struct _OnHoverModifier: ViewModifier {
    let onChange: (Bool) -> Void

    public func apply(node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let onChange = onChange
        registry.setHover(node) { phase in
            onChange(phase == .enter)
        }
    }
}

public extension View {
    /// Fires `onChange(true)` when the pointer enters this view's subtree and
    /// `onChange(false)` when it leaves. Guard `@State` writes with an
    /// equality check — hover callbacks repeat along path changes.
    func onHover(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(_OnHoverModifier(onChange: onChange))
    }
}
