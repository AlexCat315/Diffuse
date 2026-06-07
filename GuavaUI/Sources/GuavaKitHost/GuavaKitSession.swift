import GuavaKit
import GuavaUIRuntime

/// Assembles the GuavaKit v2 runtime into a single entry point suitable for a
/// platform host's frame loop.
///
/// Each `GuavaKitSession` represents one window (or one UI tree). The platform
/// host (e.g. SDL3, a future wgpu shell) feeds it events and calls `tick` once
/// per frame; the session runs recompose → layout → paint → render and returns
/// a `DrawList` ready for GPU submission.
///
/// Usage:
/// ```swift
/// let session = GuavaKitSession()
/// session.textMeasurer = FontBridgeMeasurer(bridge: fontBridge)
/// session.renderer = DisplayListRenderer(fontBridge: fontBridge, atlasTextureID: texID)
/// session.install(root: MyApp())
///
/// // In the event loop:
/// session.eventAdapter.pointerDown(at: pos)
/// // ...
/// if let drawList = session.tick(available: windowSize) {
///     submitToGPU(drawList)
/// }
/// ```
public final class GuavaKitSession {
    public let context = UIContext()
    public let eventAdapter: EventAdapter

    /// The root view installed via `install(root:)`.
    public var viewGraph: ViewGraph { _viewGraph }
    private let _viewGraph: ViewGraph

    /// Layout engine used by `tick`. Defaults to `StackLayoutEngine`.
    public var layoutEngine: LayoutEngine = StackLayoutEngine()

    /// Painter used to produce the `DisplayList`.
    public var painter = Painter()

    /// Renders the `DisplayList` into a legacy `DrawList`. Set this before the
    /// first frame (or leave `nil`; `tick` will skip rendering and return `nil`).
    public var renderer: DisplayListRenderer?

    /// Convenience: swaps in a real text measurer backed by the host's font
    /// bridge. Call after creating a `FontBridge`.
    public var textMeasurer: TextMeasuring {
        get { context.textMeasurer }
        set { context.textMeasurer = newValue }
    }

    public init() {
        _viewGraph = ViewGraph(context: context)
        eventAdapter = EventAdapter(context: context)
    }

    // MARK: - Install

    /// Installs a root view and reconciles the initial tree.
    public func install(root view: any View) {
        viewGraph.install(root: view)
    }

    // MARK: - Frame tick

    /// Runs one frame: recompose → layout → paint → render.
    ///
    /// - Parameter available: The available size for the root (typically the
    ///   window's logical size in points).
    /// - Returns: A `DrawList` ready for GPU submission, or `nil` when nothing
    ///   needs repainting (no dirty state and no renderer configured).
    @discardableResult
    public func tick(available: Size) -> DrawList? {
        let didRecompose = viewGraph.commitIfNeeded()
        let didLayout = context.layoutIfNeeded(engine: layoutEngine, available: available)
        guard didRecompose || didLayout || context.pendingDirty.contains(.paint) else {
            // Frame is clean — nothing to repaint.
            return nil
        }
        guard let renderer, let dl = context.renderIfNeeded(painter: painter) else {
            // No renderer configured yet; still drain dirty so the next frame
            // doesn't see stale flags.
            _ = context.takeDirty()
            return nil
        }
        let draw = DrawList()
        renderer.render(dl, into: draw)
        // Geometry dirty flags from setFrame are absorbed by paint/layout passes
        // above; anything left (e.g. a portal store change triggering a recompose
        // that didn't change geometry) is harmless but drained so it doesn't
        // cause a redundant next-frame tick.
        _ = context.takeDirty()
        return draw
    }
}
