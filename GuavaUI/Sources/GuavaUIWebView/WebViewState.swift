import Foundation

/// Content to display. A request is a value: comparing it is how `WebView`
/// decides whether the native surface needs another load.
public enum WebViewRequest: Equatable, Sendable {
    case url(URL)
    case html(String, baseURL: URL?)

    public static func html(_ html: String) -> WebViewRequest {
        .html(html, baseURL: nil)
    }
}

/// Observable-facing snapshot of one native web surface. Platform hosts own the
/// navigation state and publish immutable copies; callers keep it in `@State`
/// and re-render controls from it.
public struct WebViewState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed
    }

    public var phase: Phase = .idle
    public var url: URL?
    public var title: String?
    public var canGoBack = false
    public var canGoForward = false
    public var errorDescription: String?

    public init() {}

    public var isLoading: Bool { phase == .loading }
    public var hasFailed: Bool { phase == .failed }
    public var displayTitle: String { title ?? url?.absoluteString ?? "" }
}

/// Navigation command issued by composed controls. Loading new content is a
/// separate operation because it carries a request.
public enum WebViewCommand: Equatable, Sendable {
    case back
    case forward
    case reload
    case stop
}
