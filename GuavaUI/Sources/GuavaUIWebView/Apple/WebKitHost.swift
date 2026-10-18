#if os(macOS) && canImport(WebKit)
import AppKit

/// WKWebView-backed host for macOS.
///
/// The provider is supplied by the application so the same composed `WebView`
/// can follow the main window, an auxiliary window, or a window restored after
/// the surface was created. WebKit stays an implementation detail of this
/// target; callers only see `WebViewHost`.
public final class AppleWebKitHost: WebViewHost {
    private let windowProvider: @MainActor () -> NSWindow?

    public init(windowProvider: @escaping @MainActor () -> NSWindow?) {
        self.windowProvider = windowProvider
    }

    @MainActor
    public func makeSurface() -> any WebViewSurface {
        AppleWebKitSurface(windowProvider: windowProvider)
    }
}
#endif
