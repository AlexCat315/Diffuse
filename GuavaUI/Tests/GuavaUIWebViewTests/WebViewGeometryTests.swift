import Foundation
import GuavaUICompose
@testable import GuavaUIWebView
import Testing

@MainActor
struct WebViewGeometryTests {
    @Test("A node without clipping ancestors reports its full window frame")
    func unclippedFrame() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let web = Node()
        web.frame = CGRect(x: 40, y: 60, width: 320, height: 240)
        root.addChild(web)

        let geometry = WebViewGeometryResolver.resolve(web)
        #expect(geometry.isVisible)
        #expect(geometry.frame == CGRect(x: 40, y: 60, width: 320, height: 240))
        #expect(geometry.visibleFrame == geometry.frame)
    }

    @Test("A clipping ancestor trims the visible rectangle but keeps the full frame")
    func clippedFrame() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scroll = Node()
        scroll.frame = CGRect(x: 0, y: 100, width: 400, height: 200)
        scroll.clipsToBounds = true
        root.addChild(scroll)
        let web = Node()
        web.frame = CGRect(x: 20, y: 150, width: 360, height: 400)
        scroll.addChild(web)

        let geometry = WebViewGeometryResolver.resolve(web)
        #expect(geometry.isVisible)
        #expect(geometry.frame == CGRect(x: 20, y: 250, width: 360, height: 400))
        #expect(geometry.visibleFrame == CGRect(x: 20, y: 250, width: 360, height: 50))
    }

    @Test("A scrolled-out node reports no visible rectangle")
    func scrolledOut() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scroll = Node()
        scroll.frame = CGRect(x: 0, y: 100, width: 400, height: 200)
        scroll.clipsToBounds = true
        root.addChild(scroll)
        let web = Node()
        web.frame = CGRect(x: 0, y: -300, width: 400, height: 200)
        scroll.addChild(web)

        let geometry = WebViewGeometryResolver.resolve(web)
        #expect(!geometry.isVisible)
        #expect(geometry == .hidden)
    }

    @Test("A hidden ancestor hides native content")
    func hiddenAncestor() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = Node()
        panel.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        root.addChild(panel)
        let web = Node()
        web.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        panel.addChild(web)

        panel.opacity = 0
        #expect(WebViewGeometryResolver.resolve(web) == .hidden)

        panel.opacity = 1
        panel.subtreeOpacity = 0
        #expect(WebViewGeometryResolver.resolve(web) == .hidden)
    }

    @Test("A zero-sized node has no visible rectangle")
    func zeroSized() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let web = Node()
        web.frame = CGRect(x: 20, y: 20, width: 0, height: 100)
        root.addChild(web)

        #expect(WebViewGeometryResolver.resolve(web) == .hidden)
    }

    @Test("Requests with the same content compare equal and drive one load")
    func requestEquality() {
        let url = URL(string: "https://example.com")!
        #expect(WebViewRequest.url(url) == .url(url))
        #expect(WebViewRequest.html("<p>Hi</p>") == .html("<p>Hi</p>", baseURL: nil))
        #expect(WebViewRequest.html("<p>Hi</p>") != .html("<p>Bye</p>", baseURL: nil))
        #expect(WebViewRequest.url(url) != .html("<p>Hi</p>", baseURL: nil))
    }

    @Test("State exposes navigation affordances without a second source of truth")
    func stateDerivation() {
        var state = WebViewState()
        #expect(!state.isLoading)
        #expect(!state.hasFailed)
        #expect(state.displayTitle == "")

        state.phase = .loading
        state.url = URL(string: "https://example.com/docs")!
        #expect(state.isLoading)
        #expect(state.displayTitle == "https://example.com/docs")

        state.title = "Docs"
        #expect(state.displayTitle == "Docs")

        state.phase = .failed
        state.errorDescription = "Offline"
        #expect(state.hasFailed)
    }
}
