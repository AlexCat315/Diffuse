import GuavaUIRuntime

public struct FocusRequestModifier: ViewModifier {
    public let requestID: AnyHashable?
    public func apply(node: Node) {
        guard let requestID, node.isFocusable, node.attachments["__focus.request"] as? AnyHashable != requestID else { return }
        node.attachments["__focus.request"] = requestID
        FocusChainHolder.current?.focus(node)
    }
}
public extension View {
    /// A changed, nonnil token requests keyboard focus on this control.
    func focusRequest(_ requestID: AnyHashable?) -> some View { modifier(FocusRequestModifier(requestID: requestID)) }
}
