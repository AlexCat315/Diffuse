import GuavaUI
import GuavaUIRuntime
@_spi(CustomLayout) import GuavaUIScene

/// Keep a rating's intrinsic hit lanes, with the score and commands below it.
/// Wide star counts scroll inside the card instead of pushing out other content.
struct RatingSample<Details: View>: View {
    let rating: Rating
    let details: Details
    @State private var direction: Direction = .ltr

    init(_ rating: Rating, @ViewBuilder details: () -> Details) {
        self.rating = rating; self.details = details()
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            RatingStrip(rating: rating, direction: $direction)
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) { details }
        }.frame(minWidth: 0)
    }
}

private struct RatingStrip: _PrimitiveView {
    let rating: Rating
    let direction: Binding<Direction>
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.flexDirection = .column; layout.alignItems = .stretch
        layout.minWidth = 0; layout.flexShrink = 1
        return layout
    }
    func _updateNode(_ node: Node) {
        // Layout direction modifiers may be applied after the first build.
        // Publish only changes, so idle layouts do not recompose this sample.
        node.layoutDidUpdate = { node in
            let next = node.layoutNode?.customLayoutDirection ?? .ltr
            if direction.wrappedValue != next { direction.wrappedValue = next }
        }
    }
    func _children(for node: Node) -> [any View] {
        // Scroll offsets use physical left-to-right coordinates; preserve the
        // rating's logical direction explicitly inside that coordinate space.
        return [ScrollView(.horizontal, scrollbarGutter: .stable) {
            rating.layoutDirection(direction.wrappedValue)
        }.layoutDirection(.ltr).flex(0, shrink: 1).debugName("rating-strip-\(rating.label)")]
    }
}
