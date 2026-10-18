import Foundation
import GuavaUICompose
@testable import GuavaUIWebView
import Testing

@MainActor
private final class RecordingSurface: WebViewSurface {
    var onStateChange: ((WebViewState) -> Void)?
    private(set) var loads: [WebViewRequest] = []
    private(set) var geometries: [WebViewGeometry] = []
    private(set) var commands: [WebViewCommand] = []
    private(set) var detachCount = 0

    func load(_ request: WebViewRequest) {
        loads.append(request)
        var state = WebViewState()
        state.phase = .loading
        onStateChange?(state)
    }

    func perform(_ command: WebViewCommand) {
        commands.append(command)
    }

    func updateGeometry(_ geometry: WebViewGeometry) {
        geometries.append(geometry)
    }

    func detach() {
        detachCount += 1
    }
}

@MainActor
private final class RecordingHost: WebViewHost {
    private(set) var surfaces: [RecordingSurface] = []

    var surface: RecordingSurface {
        guard let surface = surfaces.last else { fatalError("No surface was requested") }
        return surface
    }

    func makeSurface() -> any WebViewSurface {
        let surface = RecordingSurface()
        surfaces.append(surface)
        return surface
    }
}

@MainActor
struct WebViewLifecycleTests {
    @Test("Mounting loads once, layout reports geometry, and unmounting detaches")
    func lifecycle() {
        let host = RecordingHost()
        let handle = WebViewHandle()
        let request = WebViewRequest.url(URL(string: "https://example.com")!)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())

        graph.install(root: Box(direction: .column) {
            WebView(request, host: host, handle: handle)
                .frame(width: 600, height: 400)
        })
        graph.computeLayout(width: 600, height: 400)

        #expect(host.surfaces.count == 1)
        #expect(host.surface.loads == [request])
        let geometry = host.surface.geometries.last
        #expect(geometry?.isVisible == true)
        #expect(geometry?.frame.size == CGSize(width: 600, height: 400))
        #expect(geometry?.visibleFrame.size == CGSize(width: 600, height: 400))

        let first = host.surface
        graph.install(root: EmptyView())
        #expect(first.detachCount == 1)

        // A second install with the same host must create a fresh surface; a
        // detached surface is never silently reused.
        graph.install(root: Box(direction: .column) {
            WebView(request, host: host, handle: handle)
                .frame(width: 600, height: 400)
        })
        #expect(host.surfaces.count == 2)
        #expect(host.surface.loads == [request])
    }

    @Test("An unchanged request reuses the surface without a second load")
    func unchangedRequestDoesNotReload() {
        let host = RecordingHost()
        let request = WebViewRequest.html("<p>hello</p>")
        let resource = WebViewNodeResource()

        resource.configure(host: host, request: request, handle: nil, onStateChange: nil)
        resource.configure(host: host, request: request, handle: nil, onStateChange: nil)

        #expect(host.surfaces.count == 1)
        #expect(host.surface.loads == [request])
    }

    @Test("Changing the request loads the new content exactly once")
    func requestChangeReloads() {
        let host = RecordingHost()
        let first = WebViewRequest.url(URL(string: "https://example.com")!)
        let second = WebViewRequest.html("<p>next</p>")
        let resource = WebViewNodeResource()

        resource.configure(host: host, request: first, handle: nil, onStateChange: nil)
        resource.configure(host: host, request: second, handle: nil, onStateChange: nil)

        #expect(host.surfaces.count == 1)
        #expect(host.surface.loads == [first, second])
    }

    @Test("A navigation handle binds to the surface and detaches with it")
    func handleBinding() {
        let host = RecordingHost()
        let handle = WebViewHandle()
        let resource = WebViewNodeResource()

        resource.configure(host: host, request: .url(URL(string: "https://example.com")!),
                           handle: handle, onStateChange: nil)
        handle.reload()
        #expect(host.surface.commands == [.reload])

        resource.unmount(node: Node())
        handle.reload()
        #expect(host.surface.commands == [.reload])
    }
}
