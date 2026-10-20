internal import GuavaUIRuntime

extension LayoutNode {
    /// The host of one list, tree or menu row. Content spans the row's width
    /// and sits on its vertical center; a bare column would pin content that
    /// is shorter than the row to the top edge.
    static func rowSlot(height: Float? = nil, minHeight: Float? = nil) -> LayoutNode {
        let layout = LayoutNode()
        layout.updateRowSlot(height: height, minHeight: minHeight)
        return layout
    }

    func updateRowSlot(height: Float? = nil, minHeight: Float? = nil) {
        flexDirection = .column
        alignItems = .stretch
        justifyContent = .center
        self.height = height
        self.minHeight = minHeight
    }
}
