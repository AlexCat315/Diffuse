#if os(macOS) && canImport(WebKit)
import AppKit
import Foundation
// WebKit never appears in the public API, but the WKNavigationDelegate
// witnesses name WKWebView, so the import stays module-scoped for this target.
import WebKit

/// A rectangular WKWebView clipped to the composed node's visible rectangle.
///
/// The native view cannot be composited by NativeRHI, so it lives above the
/// SDL content view. `WebViewGeometry` supplies both the full frame and the
/// part that survives ancestor clipping; a container view turns the latter
/// into AppKit's clip. Rounded corners, opacity and transforms are not
/// representable on a child NSView and are intentionally not faked.
@MainActor
final class AppleWebKitSurface: NSObject, WebViewSurface, WKNavigationDelegate {
    var onStateChange: ((WebViewState) -> Void)?

    private let windowProvider: @MainActor () -> NSWindow?
    private let webView: WKWebView
    private let container = NSView(frame: .zero)
    private weak var window: NSWindow?
    private var state = WebViewState()
    private var titleObservation: NSKeyValueObservation?
    private var navigationObservations: [NSKeyValueObservation] = []
    private var loadsHTML = false

    init(windowProvider: @escaping @MainActor () -> NSWindow?) {
        self.windowProvider = windowProvider
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.isHidden = true
        webView.frame = container.bounds
        webView.autoresizingMask = []
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        container.addSubview(webView)

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            // Extract the Sendable value before crossing onto the main actor.
            let title = change.newValue ?? nil
            MainActor.assumeIsolated {
                guard let self, let title, !title.isEmpty, self.state.title != title else { return }
                self.state.title = title
                self.publish()
            }
        }
        navigationObservations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    guard let self, self.state.canGoBack != value else { return }
                    self.state.canGoBack = value
                    self.publish()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    guard let self, self.state.canGoForward != value else { return }
                    self.state.canGoForward = value
                    self.publish()
                }
            },
        ]
    }

    func load(_ request: WebViewRequest) {
        state = WebViewState()
        state.phase = .loading
        switch request {
        case .url(let url):
            loadsHTML = false
            state.url = url
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        case .html(let html, let baseURL):
            loadsHTML = true
            state.url = baseURL
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        publish()
    }

    func perform(_ command: WebViewCommand) {
        switch command {
        case .back:
            guard webView.canGoBack else { return }
            webView.goBack()
        case .forward:
            guard webView.canGoForward else { return }
            webView.goForward()
        case .reload:
            state.phase = .loading
            state.errorDescription = nil
            webView.reload()
        case .stop:
            webView.stopLoading()
            state.phase = .loaded
        }
        publish()
    }

    func updateGeometry(_ geometry: WebViewGeometry) {
        let currentWindow = windowProvider()
        if currentWindow !== window {
            container.removeFromSuperview()
            window = currentWindow
        }

        guard geometry.isVisible,
              geometry.frame.width > 0, geometry.frame.height > 0,
              geometry.visibleFrame.width > 0, geometry.visibleFrame.height > 0,
              let contentView = window?.contentView
        else {
            container.isHidden = true
            return
        }

        if container.superview !== contentView {
            contentView.addSubview(container, positioned: .above, relativeTo: nil)
        }

        let full = geometry.frame
        let visible = geometry.visibleFrame
        let local = NSRect(
            x: visible.minX - contentView.bounds.minX,
            y: contentView.isFlipped
                ? visible.minY - contentView.bounds.minY
                : contentView.bounds.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
        // The web view keeps the full frame inside a smaller clipping container.
        // AppKit is bottom-left based unless the content view opted into flipping.
        let webY = contentView.isFlipped
            ? full.minY - visible.minY
            : visible.height - full.height - (full.minY - visible.minY)

        container.frame = local
        webView.frame = NSRect(x: full.minX - visible.minX, y: webY,
                               width: full.width, height: full.height)
        container.isHidden = false
    }

    func detach() {
        titleObservation?.invalidate()
        titleObservation = nil
        navigationObservations.forEach { $0.invalidate() }
        navigationObservations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        container.removeFromSuperview()
        window = nil
        onStateChange = nil
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        MainActor.assumeIsolated { navigationStarted() }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        MainActor.assumeIsolated { navigationStarted() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        MainActor.assumeIsolated { navigationFinished() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        MainActor.assumeIsolated { navigationFailed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        MainActor.assumeIsolated { navigationFailed(error) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            state.phase = .failed
            state.errorDescription = "Web content process terminated"
            publish()
        }
    }

    // MARK: - State

    private func navigationStarted() {
        state.phase = .loading
        state.errorDescription = nil
        // A link inside a local document leaves HTML mode. Keep reporting the
        // real URL from that point so Back/Forward and status text stay honest.
        if loadsHTML, let url = webView.url, url.absoluteString != "about:blank" {
            loadsHTML = false
            state.url = url
        }
        if !loadsHTML, state.url == nil { state.url = webView.url }
        publish()
    }

    private func navigationFinished() {
        state.phase = .loaded
        state.errorDescription = nil
        if !loadsHTML { state.url = webView.url ?? state.url }
        if let title = webView.title, !title.isEmpty { state.title = title }
        publish()
    }

    private func navigationFailed(_ error: Error) {
        // Superseded loads report cancellation; they are not a visible error.
        if (error as NSError).code == NSURLErrorCancelled { return }
        state.phase = .failed
        state.errorDescription = error.localizedDescription
        if !loadsHTML, state.url == nil { state.url = webView.url }
        publish()
    }

    private func publish() {
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        onStateChange?(state)
    }
}
#endif
