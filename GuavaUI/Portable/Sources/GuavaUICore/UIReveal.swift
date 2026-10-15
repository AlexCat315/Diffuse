/// Show the frame being rendered *through* the frame that was already on
/// screen, inside a circle.
///
/// The renderer keeps the previous frame in a texture it owns, so it can put
/// that frame back over the current one and mask it to a disc. Inside the disc
/// the new frame shows through; outside it, the old frame stays. A wholesale
/// repaint — a theme swap above all — therefore reads as something spreading
/// out of a point instead of a single hard cut.
///
/// Like `UIBackdrop` this is a *request*, not a guarantee. A renderer that
/// cannot sample the frame it just drew (no backdrop program, or a frame
/// rendered straight into a swapchain image) ignores it, and the new frame is
/// simply shown immediately.
public struct UIReveal: Equatable, Sendable {
    /// Identifies one reveal run.
    ///
    /// The renderer retains the frame once per sequence and keeps compositing
    /// that one for the rest of the run. Without it, frame two would retain the
    /// half-revealed frame one and the disc would freeze on screen.
    public var sequence: UInt64
    /// Circle centre in logical points, window space, top-left origin.
    public var centerX: Float
    public var centerY: Float
    /// Circle radius in logical points.
    public var radius: Float
    /// Width of the soft band straddling the edge, in logical points. A hard
    /// edge crawls as the radius grows; a band about one physical pixel wide
    /// reads as a clean boundary that does not shimmer.
    public var feather: Float

    public init(sequence: UInt64, centerX: Float, centerY: Float,
                radius: Float, feather: Float = 1) {
        self.sequence = sequence
        self.centerX = centerX
        self.centerY = centerY
        self.radius = max(0, radius)
        self.feather = max(0, feather)
    }

    /// Whether any of the new frame is visible. A zero-radius request still
    /// retains and displays the previous frame; nil ends the presentation.
    public var isVisible: Bool { radius > 0 }
}
