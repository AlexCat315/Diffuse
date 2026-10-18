import GuavaUIRuntime

public struct HitTestingModifier: ViewModifier {
    public let isEnabled: Bool
    public init(_ isEnabled: Bool) { self.isEnabled = isEnabled }
    public func apply(node: Node) {
        node.allowsHitTesting = isEnabled
        guard !isEnabled else { return }
        if PointerCaptureHolder.current?.target?.acceptsSubtreeInput == false {
            PointerCaptureHolder.current?.release()
        }
        if FocusChainHolder.current?.focused?.acceptsSubtreeInput == false { FocusChainHolder.current?.clear() }
    }
}

public extension View {
    /// Controls pointer and keyboard interaction for this subtree without altering its appearance.
    func allowsHitTesting(_ isEnabled: Bool) -> some View { modifier(HitTestingModifier(isEnabled)) }
}
