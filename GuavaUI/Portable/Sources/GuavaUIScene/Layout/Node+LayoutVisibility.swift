private let layoutVisibilityKey = "GuavaUI.layout.visible"

public extension Node {
    /// Current layout presentation, independent of authored opacity and input.
    var isLayoutVisible: Bool { attachments[layoutVisibilityKey] as? Bool ?? true }

    @_spi(CustomLayout) func setLayoutVisibility(_ visible: Bool) {
        guard visible != isLayoutVisible else { return }
        attachments[layoutVisibilityKey] = visible ? nil : false
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
