import Foundation
internal import GuavaUICompose

/// One platform-owned web surface. The surface is created by a `WebViewHost`;
/// `WebView` only decides where it goes and when it leaves.
///
/// A surface owns the native browser view (WKWebView, WebView2, WebKitGTK or
/// Android WebView). It must attach lazily on the first non-empty geometry so
/// a view created before its host window is ready still works.
public protocol WebViewSurface: AnyObject {
    /// Receives every published navigation state. Called on the main actor.
    @MainActor var onStateChange: ((WebViewState) -> Void)? { get set }

    @MainActor func load(_ request: WebViewRequest)
    @MainActor func perform(_ command: WebViewCommand)

    /// Window-space geometry of the composed node. `visibleFrame` is already
    /// intersected with every clipping ancestor; the host clips the native
    /// view to that rectangle and hides it when nothing remains.
    @MainActor func updateGeometry(_ geometry: WebViewGeometry)

    /// Remove the native view and release browser resources. Must be
    /// idempotent because node teardown can reach it more than once.
    @MainActor func detach()
}

/// Platform factory passed by the application. Keeping the window binding in
/// the application (instead of a global) is what lets the same composed view
/// run in a main window, an auxiliary window, or an embedded host.
public protocol WebViewHost: AnyObject {
    @MainActor func makeSurface() -> any WebViewSurface
}

/// Rectangle reported to a native surface.
///
/// `frame` is the node's window-space rect and `visibleFrame` is the part that
/// survives clipping ancestors. Both use the composed top-left coordinate
/// space; a platform host converts to its own view coordinates.
public struct WebViewGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var isVisible: Bool

    public init(frame: CGRect, visibleFrame: CGRect, isVisible: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isVisible = isVisible
    }

    public static let hidden = WebViewGeometry(frame: .zero, visibleFrame: .zero, isVisible: false)
}

enum WebViewGeometryResolver {
    /// Resolve a node against the clipping ancestors that are actually
    /// painted. A hidden ancestor hides the native view as well; a native view
    /// is never allowed to outlive the composed subtree that owns it.
    static func resolve(_ node: Node) -> WebViewGeometry {
        guard node.isLayoutVisible, node.opacity > 0, node.subtreeOpacity > 0 else { return .hidden }
        let frame = node.absoluteFrame
        guard frame.width > 0, frame.height > 0 else { return .hidden }

        var visible = frame
        var ancestor = node.parent
        while let current = ancestor {
            guard current.isLayoutVisible, current.opacity > 0, current.subtreeOpacity > 0 else {
                return .hidden
            }
            if current.clipsToBounds {
                visible = visible.intersection(current.absoluteFrame)
                if visible.isNull || visible.width <= 0 || visible.height <= 0 { return .hidden }
            }
            ancestor = current.parent
        }

        return WebViewGeometry(frame: frame, visibleFrame: visible, isVisible: true)
    }
}
