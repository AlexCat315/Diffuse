import GuavaUIRuntime

extension TextField {
    /// Horizontal extent is learned from shaped rows; discovering a wide row
    /// never requires scanning the complete document. An edit or typography
    /// change invalidates the observed extent while preserving the position
    /// until the new visible window can clamp it.
    struct HorizontalScrollState {
        private var buffer: TextBuffer?
        private var geometry: TextLineGeometry?
        var offset: Float = 0
        var viewportWidth: Float = 0
        var contentWidth: Float = 0
        var leadingInset: Float = 0
        var maximum: Float { max(0, contentWidth - viewportWidth) }

        mutating func synchronize(buffer: TextBuffer, geometry: TextLineGeometry,
                                  viewportWidth: Float, measuredWidth: Float, revealCaret: Float?) {
            if self.buffer != buffer || self.geometry != geometry {
                contentWidth = 0; self.buffer = buffer; self.geometry = geometry
            }
            self.viewportWidth = max(1, viewportWidth)
            let margin = min(8, self.viewportWidth / 4)
            contentWidth = max(contentWidth, measuredWidth + margin)
            if let x = revealCaret {
                contentWidth = max(contentWidth, x + margin)
                if x < offset + margin { offset = max(0, x - margin) }
                else if x > offset + self.viewportWidth - margin { offset = x + margin - self.viewportWidth }
            }
            offset = clamp(offset, 0, maximum)
        }
    }
}
