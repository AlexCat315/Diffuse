import GuavaUIRuntime

/// Automatic advance for a `Carousel`. Rotation pauses while the pointer is
/// over the carousel or keyboard focus is inside it, restarts its interval
/// after any manual page change, and always offers a pause control. With
/// reduced motion it starts paused.
public struct CarouselAutoplay: Sendable, Equatable {
    /// Seconds each page stays before advancing, 2–60.
    public var interval: Double

    public init(interval: Double = 5) {
        self.interval = interval.isFinite ? min(60, max(2, interval)) : 5
    }
}

/// Transient rotation state, owned by the mounted carousel and never part of
/// its configuration.
final class CarouselAutoplaySession {
    private let registrar = ObservableStateRegistrar()
    private var userPaused: Bool?
    var elapsed: Double = 0
    var isHovered = false
    var pageIndex: Int?
    weak var progressNode: Node?

    /// Before the viewer chooses, reduced motion means paused.
    func isPaused(reducedMotion: Bool) -> Bool {
        registrar.access("paused")
        return userPaused ?? reducedMotion
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused; elapsed = 0
        registrar.invalidate("paused")
        progressNode?.markRenderDirty(reason: .styleSet(field: "carouselProgress"))
    }

    func progress(interval: Double) -> Float { Float(min(1, max(0, elapsed / interval))) }

    /// A page change from any source restarts the interval.
    func observe(page: Int) {
        guard pageIndex != page else { return }
        if pageIndex != nil { elapsed = 0 }
        pageIndex = page
        progressNode?.markRenderDirty(reason: .styleSet(field: "carouselProgress"))
    }
}

/// Hosts the clock for one carousel; adds no layout of its own.
struct CarouselAutoplayHost<Content: View>: _PrimitiveView {
    let session: CarouselAutoplaySession
    /// nil stops the clock: no autoplay, paused, disabled or nothing to advance.
    let interval: Double?
    let advance: () -> Void
    /// Reads the live page, so a change from any source restarts the interval
    /// even when it does not recompose the carousel.
    let page: () -> Int
    let content: Content

    init(session: CarouselAutoplaySession, interval: Double?, advance: @escaping () -> Void,
         page: @escaping () -> Int, @ViewBuilder content: () -> Content) {
        self.session = session; self.interval = interval; self.advance = advance; self.page = page; self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false
        node.addResource(CarouselClock())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.firstResource(CarouselClock.self)?.configure(session: session, interval: interval, advance: advance, page: page)
    }
    var _children: [any View] { [content] }
}

private final class CarouselClock: NodeResource, AnyAnimationController {
    private weak var node: Node?
    private var session: CarouselAutoplaySession?
    private var interval: Double = 5
    private var advance: () -> Void = {}
    private var page: () -> Int = { 0 }
    var isFinished = true

    func mount(node: Node) { self.node = node }
    func unmount(node: Node) { stop(); self.node = nil }

    func configure(session: CarouselAutoplaySession, interval: Double?, advance: @escaping () -> Void, page: @escaping () -> Int) {
        self.session = session; self.advance = advance; self.page = page
        guard let interval else { stop(); return }
        self.interval = interval
        if isFinished { isFinished = false; AnimatorScheduler.current.register(self) }
    }

    func tick(deltaTime: Double) {
        guard !isFinished, let node, let session else { return }
        session.observe(page: page())
        guard !session.isHovered, !containsFocus(node) else { return }
        session.elapsed += deltaTime
        if session.elapsed >= interval { session.elapsed = 0; advance() }
        session.progressNode?.markRenderDirty(reason: .styleSet(field: "carouselProgress"))
    }

    private func containsFocus(_ node: Node) -> Bool {
        var current = FocusChainHolder.current?.focused
        while let candidate = current {
            if candidate === node { return true }
            current = candidate.parent
        }
        return false
    }

    private func stop() {
        guard !isFinished else { return }
        isFinished = true
        AnimatorScheduler.current.unregister(self)
    }
    func finishImmediately() { stop() }
    func cancel() { stop() }
}

/// Reads the reduced-motion preference without adding a layout node.
struct ReducedMotionReader<Content: View>: _PrimitiveView {
    let content: (Bool) -> Content
    init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _updateNode(_ node: Node) {}
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _children(for node: Node) -> [any View] { [content(node.prefersReducedMotion)] }
}
