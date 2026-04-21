import Foundation
import Logging
import PlatformShell
import EngineKernel

/// `PlatformHost` backed by SDL3 via Engine's `PlatformShell`.
///
/// Opens a native window, polls SDL3 events, and drives `Recomposer` + `NodeTree`
/// every frame. GPU draw submission (DrawList → wgpu) is added in Phase 5.
@MainActor
public final class SDL3PlatformHost: PlatformHost {

    private let title: String
    public let recomposer: Recomposer
    public let interactions: InteractionRegistry
    public let pointerCapture: PointerCapture
    public let focusChain: FocusChain
    private var shell: (any Shell)?
    private var _isRunning: Bool = false
    public private(set) var drawableSize: (width: UInt32, height: UInt32) = (1, 1)
    public private(set) var logicalSize: (width: UInt32, height: UInt32) = (1, 1)

    public var isRunning: Bool { _isRunning }
    public var contentScaleFactor: Float {
        let logicalWidth = max(logicalSize.width, 1)
        return Float(drawableSize.width) / Float(logicalWidth)
    }

    /// Called each frame with the native render surface. Set this to submit GPU work.
    public var onFrame: (@MainActor (NativeRenderSurface) -> Void)?

    /// Called once after the window is created, with the initial render surface
    /// and drawable size. Use this to build pipelines and upload static textures.
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?

    /// Called when the window's drawable size changes. Use this to reconfigure
    /// surface, depth buffer, etc.
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?

    /// Optional inspector hook for unhandled platform events (debugging, custom
    /// shortcuts). Called after `EventDispatcher` has run.
    public var onEvent: (@MainActor (InputEvent) -> Void)?

    /// - Parameters:
    ///   - title: Window title bar text.
    ///   - recomposer: The recomposer to drain each frame. A fresh instance per
    ///     host by default; pass an existing one only for cross-host coordination
    ///     (currently no use case — see blueprint §9.4).
    public init(title: String = "GuavaUI", recomposer: Recomposer = Recomposer()) {
        self.title = title
        self.recomposer = recomposer
        self.interactions = InteractionRegistry()
        self.pointerCapture = PointerCapture()
        self.focusChain = FocusChain()
    }

    /// Open the window and block until the user closes it or `stop()` is called.
    public func run(tree: NodeTree) {
        let host: any Shell
        do {
            host = try makeDefaultShell()
            try host.initializeWindow(title: title)
        } catch {
            Logger.runtime.error("window open failed: \(error)")
            return
        }
        shell = host
        updateMetrics(from: host)
        _isRunning = true
        let _title = title
        Logger.runtime.info("running — \(_title)")

        // Build the per-tree dispatcher.
        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: pointerCapture,
            focusChain: focusChain,
            windowID: .main
        )

        // Fire onInit once after the window is fully realised.
        if let surface = host.renderSurface {
            onInit?(surface, drawableSize.width, drawableSize.height)
        }
        var lastDrawableSize = drawableSize
        var lastLogicalSize = logicalSize
        var lastFrameTime = Date()

        while host.isRunning && _isRunning {
            // Compute frame deltaTime in seconds for the animator.
            let now = Date()
            let deltaTime = now.timeIntervalSince(lastFrameTime)
            lastFrameTime = now

            // 1. Execute pending state-driven recomposes (may register new
            //    animation controllers via modifier-apply paths).
            recomposer.commitAll()
            // 2. Advance any active animations and write interpolated values
            //    onto nodes before the dirty flush picks them up.
            AnimatorScheduler.current.tick(deltaTime: deltaTime)
            // 3. Flush dirty nodes (layout + draw callbacks in later phases).
            tree.flush()
            // 4. Detect resize and notify.
            let curDrawableSize = host.drawableSize
            let curLogicalSize = host.logicalSize
            if curDrawableSize != lastDrawableSize || curLogicalSize != lastLogicalSize {
                drawableSize = curDrawableSize
                logicalSize = curLogicalSize
                onResize?(curDrawableSize.width, curDrawableSize.height)
                lastDrawableSize = curDrawableSize
                lastLogicalSize = curLogicalSize
            }
            // 5. Render frame if callback is set.
            if let surface = host.renderSurface {
                onFrame?(surface)
            }
            // 6. Drain platform events through the dispatcher.
            for event in host.pollEvents() {
                dispatcher.dispatch(event)
                onEvent?(event)
            }
        }

        _isRunning = false
        host.shutdown()
        shell = nil
        Logger.runtime.info("stopped")
    }

    public func stop() {
        _isRunning = false
    }

    private func updateMetrics(from host: any Shell) {
        drawableSize = host.drawableSize
        logicalSize = host.logicalSize
    }
}
