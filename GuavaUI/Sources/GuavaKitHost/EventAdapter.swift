import GuavaKit

/// Feeds platform-level pointer events into GuavaKit's event dispatch pipeline.
///
/// The adapter is intentionally thin — hit‑testing, capture, phase delivery
/// (capture / target / bubble), and hover enter/leave diffing all live inside
/// GuavaKit's `EventDispatcher`. This type only creates `PointerEvent` values
/// and calls the correct dispatch entry point.
///
/// Usage from a platform host (e.g. SDL3 run loop):
/// ```swift
/// let adapter = EventAdapter(context: uiContext)
/// // In the event loop:
/// for event in shell.pollWindowEvents() {
///     switch event {
///     case .mouseDown(let pos): adapter.pointerDown(at: Point(x: pos.x, y: pos.y))
///     case .mouseUp(let pos):   adapter.pointerUp(at: Point(x: pos.x, y: pos.y))
///     case .mouseMove(let pos): adapter.pointerMove(to: Point(x: pos.x, y: pos.y))
///     }
/// }
/// ```
public final class EventAdapter {
    private let dispatcher: EventDispatcher

    /// Creates an adapter that routes events into `context`'s tree.
    public init(context: UIContext) {
        self.dispatcher = EventDispatcher(context: context)
    }

    // MARK: - Pointer

    /// Hit-tests at `position` and delivers a down event through the phases.
    /// A handler may call `context.pointerCapture.acquire(node)` to start a drag.
    @discardableResult
    public func pointerDown(at position: Point, button: PointerButton = .primary) -> EventResult {
        dispatcher.pointerDown(PointerEvent(position: position, button: button, action: .down))
    }

    /// Delivers an up event. If a capture is active the event goes straight to
    /// the captured node (no hit-test); otherwise hit-tests. Hover state is
    /// refreshed afterwards.
    @discardableResult
    public func pointerUp(at position: Point, button: PointerButton = .primary) -> EventResult {
        dispatcher.pointerUp(PointerEvent(position: position, button: button, action: .up))
    }

    /// Delivers a move event. Capture takes priority; hover is always updated to
    /// the node currently under the cursor.
    @discardableResult
    public func pointerMove(to position: Point) -> EventResult {
        dispatcher.pointerMove(PointerEvent(position: position, action: .move))
    }

    // MARK: - Wheel

    /// Routes a scroll-wheel event to the deepest hit node. The first handler
    /// returning `.handled` consumes the event.
    @discardableResult
    public func wheelScroll(deltaX: Float = 0, deltaY: Float = 0,
                            at position: Point) -> EventResult {
        dispatcher.dispatchWheel(WheelEvent(deltaX: deltaX, deltaY: deltaY, position: position))
    }
}
