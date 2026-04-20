import Foundation
import os.log
import PlatformShell

/// `PlatformHost` backed by SDL3 via Engine's `PlatformShell`.
///
/// Opens a native window, polls SDL3 events, and drives `Recomposer` + `NodeTree`
/// every frame. GPU draw submission (DrawList → wgpu) is added in Phase 5.
@MainActor
public final class SDL3PlatformHost: PlatformHost {

    private let title: String
    private let recomposer: Recomposer
    private var shell: (any Shell)?
    private var _isRunning: Bool = false

    public var isRunning: Bool { _isRunning }

    /// - Parameters:
    ///   - title: Window title bar text.
    ///   - recomposer: The recomposer to drain each frame. Defaults to `Recomposer.shared`.
    public init(title: String = "GuavaUI", recomposer: Recomposer = .shared) {
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
            Logger.runtime.error("window open failed: \(error, privacy: .public)")
            return
        }
        shell = host
        _isRunning = true
        let _title = title
        Logger.runtime.info("running — \(_title, privacy: .public)")

        while host.isRunning && _isRunning {
            // 1. Execute pending state-driven recomposes.
            recomposer.commitAll()
            // 2. Flush dirty nodes (layout + draw callbacks in later phases).
            tree.flush()
            // 3. Poll platform events; event routing to hit-test added in Phase 6.
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
