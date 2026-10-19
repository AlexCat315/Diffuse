import GuavaUIRuntime

/// How a carousel shows position. `.automatic` uses dots up to eight pages
/// and a "3 / 12" count beyond, where dots stop being countable.
public enum CarouselIndicator: Sendable, Hashable {
    case automatic
    case dots
    case fraction
    case hidden

    func resolved(pageCount: Int) -> CarouselIndicator {
        guard pageCount > 1 else { return .hidden }
        guard self == .automatic else { return self }
        return pageCount <= 8 ? .dots : .fraction
    }
}

/// The active dot: an accent pill that fills with the autoplay interval, or
/// stays solid when nothing rotates.
struct CarouselProgressDot: _PrimitiveView {
    let session: CarouselAutoplaySession
    /// nil when not rotating; the pill is then solid.
    let interval: Double?

    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.width = 16; layout.height = 7; return layout
    }
    func _updateNode(_ node: Node) {
        session.progressNode = node
        let accent = node.theme.colors.accent, session = session, interval = interval
        node.updateDraw(identity: interval) { [weak node] list, origin in
            guard let node else { return }
            let rect = UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height))
            guard let interval else { list.addRoundedRect(rect, radius: rect.height / 2, color: accent); return }
            list.addRoundedRect(rect, radius: rect.height / 2, color: accent.multipliedAlpha(0.3))
            let filled = max(rect.height, rect.width * session.progress(interval: interval))
            list.addRoundedRect(UIRect(x: rect.x, y: rect.y, width: filled, height: rect.height),
                                radius: rect.height / 2, color: accent)
        }
    }
}
