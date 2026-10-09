/// Abstraction over the windowing system and per-frame event loop.
///
/// A `PlatformHost` implementation opens a native window, drives `Recomposer`
/// and `NodeTree` each frame, and (from Phase 5) submits GPU draw lists.
@MainActor
public protocol PlatformHost: AnyObject {
    /// Open the window and block until the window is closed or `stop()` is called.
    func run(tree: NodeTree)
    /// Signal the run loop to exit on the next frame.
    func stop()
    /// `true` while the run loop has not exited.
    var isRunning: Bool { get }
}
