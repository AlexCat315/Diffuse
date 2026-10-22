public extension Node {
    /// Hiding drops the pointer capture and focus this subtree holds; showing
    /// does not restore them. `isLayoutVisible` itself is stored on the node —
    /// see the note there for why this is not an attachment lookup.
    @_spi(CustomLayout) func setLayoutVisibility(_ visible: Bool) {
        guard visible != isLayoutVisible else { return }
        isLayoutVisible = visible
        markRenderDirty(reason: .layoutChange)
        guard !visible else { return }
        func contains(_ target: Node?) -> Bool {
            var ancestor = target
            while let current = ancestor {
                if current === self { return true }
                ancestor = current.parent
            }
            return false
        }
        if contains(PointerCaptureHolder.current?.target) { PointerCaptureHolder.current?.release() }
        if contains(FocusChainHolder.current?.focused) { FocusChainHolder.current?.clear() }
    }
}
