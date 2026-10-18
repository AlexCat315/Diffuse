/// Imperative navigation handle shared by a `WebView` and its surrounding
/// controls. It is deliberately not observable: navigation state belongs to
/// `WebViewState` on the caller's `@State`, so a handle can live in `@State`
/// without owning a second source of truth.
///
/// A handle binds to at most one surface. Creating a new `WebView` with the
/// same handle rebinds it, which makes swapping the composed page safe.
///
/// Navigation methods are synchronous and callable from a button action. They
/// assume the UI thread, like every other view action in GuavaUI.
public final class WebViewHandle: @unchecked Sendable {
    private weak var surface: (any WebViewSurface)?
    private var pending: WebViewCommand?

    public init() {}

    public func goBack() { onUIThread { perform(.back) } }
    public func goForward() { onUIThread { perform(.forward) } }
    public func reload() { onUIThread { perform(.reload) } }
    public func stopLoading() { onUIThread { perform(.stop) } }

    /// Replace the page without changing the composed request. The next
    /// `WebView` materialisation still wins if it carries a different request.
    public func load(_ request: WebViewRequest) {
        onUIThread { surface?.load(request) }
    }

    @MainActor func attach(_ surface: any WebViewSurface) {
        self.surface = surface
        if let pending {
            self.pending = nil
            surface.perform(pending)
        }
    }

    @MainActor func detach(_ surface: any WebViewSurface) {
        if self.surface === surface { self.surface = nil }
    }

    @MainActor private func perform(_ command: WebViewCommand) {
        guard let surface else {
            pending = command
            return
        }
        surface.perform(command)
    }

    private func onUIThread(_ body: @MainActor () -> Void) {
        MainActor.assumeIsolated(body)
    }
}
