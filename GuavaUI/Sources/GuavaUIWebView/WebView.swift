public import GuavaUICompose

/// Native web content inside the composed tree.
///
/// The view owns layout, clipping and lifetime. The actual browser view comes
/// from a `WebViewHost`, so the same code runs in an SDL window, an app host or
/// a custom embedded surface. Geometry is reported in window points; clipping
/// is the intersection of the node with its painting ancestors.
///
/// ```swift
/// @State private var browser = WebViewHandle()
/// @State private var state = WebViewState()
/// // `host` is a long-lived @State/session object, never an inline literal.
/// @State private var host: AppleWebKitHost
///
/// WebView(.url(URL(string: "https://example.com")!), host: host, handle: browser) {
///     state = $0
/// }
/// ```
///
/// A native view cannot be blended by the GuavaUI renderer. It is rectangular,
/// ignores ancestor opacity/scale/rounded corners, and sits above composed
/// content. Keep overlays that must cover it out of its rectangle, or hide the
/// web view by unmounting it.
public struct WebView: View {
    let request: WebViewRequest
    let host: any WebViewHost
    let handle: WebViewHandle?
    let onStateChange: ((WebViewState) -> Void)?

    public init(_ request: WebViewRequest,
                host: any WebViewHost,
                handle: WebViewHandle? = nil,
                onStateChange: ((WebViewState) -> Void)? = nil) {
        self.request = request
        self.host = host
        self.handle = handle
        self.onStateChange = onStateChange
    }

    public var body: some View {
        WebViewPrimitive(request: request, host: host, handle: handle, onStateChange: onStateChange)
    }
}

// The primitive is materialised and updated on the scene thread. The node
// callbacks hop back to the main actor; `@unchecked` is limited to that owned
// UI graph rather than implying the host or its closure is thread-safe.
struct WebViewPrimitive: _PrimitiveView, @unchecked Sendable {
    let request: WebViewRequest
    let host: any WebViewHost
    let handle: WebViewHandle?
    let onStateChange: ((WebViewState) -> Void)?

    func _makeNode() -> Node {
        MainActor.assumeIsolated {
            let node = Node()
            node.isHitTestable = false
            node.addResource(WebViewNodeResource())
            return node
        }
    }

    func _updateNode(_ node: Node) {
        MainActor.assumeIsolated {
            guard let resource = node.firstResource(WebViewNodeResource.self) else { return }
            resource.configure(host: host, request: request, handle: handle, onStateChange: onStateChange)
            node.layoutDidUpdate = { node in
                MainActor.assumeIsolated {
                    resource.updateGeometry(for: node)
                }
            }
            node.updateDraw(identity: WebViewDrawIdentity(request: request, host: ObjectIdentifier(host))) { [weak node] _, _ in
                guard let node else { return }
                MainActor.assumeIsolated {
                    resource.updateGeometry(for: node)
                }
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        MainActor.assumeIsolated {
            let layout = LayoutNode()
            layout.flexDirection = .column
            layout.alignItems = .stretch
            layout.flexGrow = 1
            return layout
        }
    }
}

private struct WebViewDrawIdentity: Equatable {
    let request: WebViewRequest
    let host: ObjectIdentifier
}

/// Owns the platform surface for one node. The surface is created lazily so a
/// `WebView` can be built before its host window exists; the first geometry
/// update attaches it.
@MainActor
final class WebViewNodeResource: NodeResource {
    private var host: (any WebViewHost)?
    private var surface: (any WebViewSurface)?
    private var request: WebViewRequest?
    private var onStateChange: ((WebViewState) -> Void)?
    private weak var handle: WebViewHandle?

    nonisolated func mount(node: Node) {}

    nonisolated func unmount(node: Node) {
        MainActor.assumeIsolated {
            teardown()
        }
    }

    func configure(host: any WebViewHost,
                   request: WebViewRequest,
                   handle: WebViewHandle?,
                   onStateChange: ((WebViewState) -> Void)?) {
        let hostChanged = self.host.map { $0 !== host } ?? true
        let requestChanged = self.request != request

        if self.handle !== handle {
            if let surface { self.handle?.detach(surface) }
            self.handle = handle
        }

        self.host = host
        self.request = request
        self.onStateChange = onStateChange

        if hostChanged {
            surface?.detach()
            surface = nil
        }

        let surface = ensureSurface(host: host)
        surface.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        handle?.attach(surface)
        if hostChanged || requestChanged {
            surface.load(request)
        }
    }

    func updateGeometry(for node: Node) {
        surface?.updateGeometry(WebViewGeometryResolver.resolve(node))
    }

    private func ensureSurface(host: any WebViewHost) -> any WebViewSurface {
        if let surface { return surface }
        let created = host.makeSurface()
        surface = created
        return created
    }

    private func teardown() {
        if let surface {
            surface.detach()
            handle?.detach(surface)
        }
        surface = nil
        handle = nil
        host = nil
        request = nil
        onStateChange = nil
    }
}
