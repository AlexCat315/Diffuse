import Foundation
import Logging
import PlatformShell

/// `PlatformHost` backed by SDL3 via Engine's `PlatformShell`.
///
/// Opens a native window, polls SDL3 events, and drives `Recomposer` + `NodeTree`
/// every frame. GPU draw submission (DrawList → wgpu) is added in Phase 5.
@MainActor
public final class SDL3PlatformHost: PlatformHost {

    private let title: String
    public let recomposer: Recomposer
    private var shell: (any Shell)?
    private var _isRunning: Bool = false

    public var isRunning: Bool { _isRunning }

    /// Called each frame with the native render surface. Set this to submit GPU work.
    public var onFrame: (@MainActor (NativeRenderSurface) -> Void)?

    /// Called once after the window is created, with the initial render surface
    /// and drawable size. Use this to build pipelines and upload static textures.
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?

    /// Called when the window's drawable size changes. Use this to reconfigure
    /// surface, depth buffer, etc.
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?

    /// - Parameters:
    ///   - title: Window title bar text.
    ///   - recomposer: The recomposer to drain each frame. A fresh instance per
    ///     host by default; pass an existing one only for cross-host coordination
    ///     (currently no use case — see blueprint §9.4).
    public init(title: String = "GuavaUI", recomposer: Recomposer = Recomposer()) {
        self.title = title
        self.recomposer = recomposer
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
        _isRunning = true
        let _title = title
        Logger.runtime.info("running — \(_title)")

        // Fire onInit once after the window is fully realised.
        if let surface = host.renderSurface {
            let (w, h) = host.drawableSize
            onInit?(surface, w, h)
        }
        var lastSize = host.drawableSize

        while host.isRunning && _isRunning {
            // 1. Execute pending state-driven recomposes.
            recomposer.commitAll()
            // 2. Flush dirty nodes (layout + draw callbacks in later phases).
            tree.flush()
            // 3. Detect resize and notify.
            let cur = host.drawableSize
            if cur.0 != lastSize.0 || cur.1 != lastSize.1 {
                onResize?(cur.0, cur.1)
                lastSize = cur
            }
            // 4. Render frame if callback is set.
            if let surface = host.renderSurface {
                onFrame?(surface)
            }
            // 5. Poll platform events; event routing to hit-test added in Phase 6.
            _ = host.pollEvents()
        }

        _isRunning = false
        host.shutdown()
        shell = nil
        Logger.runtime.info("stopped")
    }

    public func stop() {
        _isRunning = false
    }
}
