/// The presentation behavior actually selected for one native window.
/// A request to disable VSync can fall back to a synchronized mode when the
/// window system does not support immediate presentation.
public enum PresentationMode: String, Equatable, Sendable {
    /// Presents without waiting for the next display refresh; tearing is possible.
    case immediate
    /// Displays the latest pending image at refresh, replacing older pending images.
    case mailbox
    /// Presents queued images in order at display refresh.
    case fifo
    /// The window compositor controls cadence without an explicit refresh interval.
    case compositor

    /// Whether presentation remains controlled by display refresh or its compositor.
    public var synchronizesToDisplay: Bool { self != .immediate }
}
