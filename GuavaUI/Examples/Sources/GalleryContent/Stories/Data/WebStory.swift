#if os(macOS) && canImport(WebKit)
import AppKit
import Foundation
import GuavaUI
import GuavaUIWebView

/// A real WKWebView hosted above the composed surface. The composed side owns
/// the frame, clipping and navigation controls; WebKit owns the page.
struct WebStory: View {
    private enum Sample: String, CaseIterable, Hashable, Sendable {
        case local, example, repository

        var title: String {
            switch self {
            case .local: "Offline sample"
            case .example: "example.com"
            case .repository: "GuavaStudio on GitHub"
            }
        }
    }

    @State private var sample: Sample = .local
    @State private var host: AppleWebKitHost
    @State private var handle = WebViewHandle()
    @State private var state = WebViewState()

    init() {
        _host = State(wrappedValue: AppleWebKitHost { Self.mainWindow })
    }

    private var request: WebViewRequest {
        switch sample {
        case .local:
            .html(Self.localPage, baseURL: nil)
        case .example:
            .url(URL(string: "https://example.com")!)
        case .repository:
            .url(URL(string: "https://github.com/AlexCat315/GuavaStudio")!)
        }
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection(
                "Native web content",
                "WKWebView is attached above the composed surface. Back, forward, reload and stop operate the real browser; the frame follows layout and is clipped by the gallery scroll view."
            ) {
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 10) {
                    ButtonGroup(
                        Sample.allCases.map { ButtonGroupItem($0, $0.title) },
                        selection: Binding(get: { sample }, set: { if let value = $0 { sample = value } })
                    )
                    Button("Back", isEnabled: state.canGoBack) { handle.goBack() }
                        .buttonStyle(.secondary)
                    Button("Forward", isEnabled: state.canGoForward) { handle.goForward() }
                        .buttonStyle(.secondary)
                    Button("Reload") { handle.reload() }.buttonStyle(.secondary)
                    Button("Stop", isEnabled: state.isLoading) { handle.stopLoading() }
                        .buttonStyle(.ghost)
                }
                status
                Box {
                    WebView(request, host: host, handle: handle) { next in
                        if next != state { state = next }
                    }
                        .frame(height: 460)
                }
                .padding(1)
                .background(.border)
                Text("Native views cannot be blended by the renderer: a menu or sheet opened over this rectangle is covered by the page. Rounded ancestor corners, opacity and transforms are not applied.")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
        }
    }

    private var status: some View {
        Row(alignment: .center, spacing: 8) {
            if state.isLoading { Spinner(size: 14) }
            Text(statusText, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .frame(minHeight: 20)
    }

    private var statusText: String {
        if let error = state.errorDescription, state.hasFailed { return "Failed: \(error)" }
        switch state.phase {
        case .idle: return "Ready"
        case .loading:
            return state.displayTitle.isEmpty ? "Loading…" : "Loading \(state.displayTitle)"
        case .loaded: return state.displayTitle.isEmpty ? "Loaded" : state.displayTitle
        case .failed: return "Failed to load"
        }
    }

    @MainActor private static var mainWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    private static let localPage = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>GuavaUI WebView</title>
      <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          background: #f6f4f1;
          color: #24211d;
        }
        @media (prefers-color-scheme: dark) {
          body { background: #1d1b19; color: #f2eee7; }
          .card { background: #2a2724 !important; border-color: #3b3732 !important; }
          .muted { color: #b8b0a5 !important; }
          .accent { color: #9fd6a4 !important; }
        }
        main { max-width: 680px; margin: 0 auto; padding: 32px 28px 36px; }
        .eyebrow { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: #8b8174; }
        h1 { font-size: 30px; line-height: 1.15; margin: 8px 0 10px; letter-spacing: -.02em; }
        p { margin: 0 0 16px; }
        .muted { color: #6f675c; }
        .card {
          display: flex; align-items: center; justify-content: space-between; gap: 16px;
          padding: 16px 18px; margin: 18px 0; background: #fffdf9;
          border: 1px solid #e4ddd2; border-radius: 14px;
        }
        .accent { color: #2f6b38; font-weight: 600; }
        button {
          font: inherit; font-weight: 600; color: #173d1d; background: #b9e4bd;
          border: 0; border-radius: 9px; padding: 8px 14px; cursor: pointer;
        }
        button:active { transform: translateY(1px); }
        a { color: inherit; }
        footer { margin-top: 24px; font-size: 12px; color: #8b8174; }
      </style>
    </head>
    <body>
      <main>
        <div class="eyebrow">GuavaUI · WKWebView</div>
        <h1>Real HTML, inside a composed window.</h1>
        <p class="muted">
          This page is rendered by WebKit and clipped to the frame measured by GuavaUI.
          Scroll the gallery and the native view follows the node.
        </p>
        <div class="card">
          <div>
            <div class="accent">Local document</div>
            <div class="muted" style="font-size:13px">No network request; loaded with loadHTMLString.</div>
          </div>
          <button id="count" type="button">Tap me</button>
        </div>
        <p>
          Use the sample selector above to load a remote page. Back and Forward
          follow the browser's history between those top-level loads.
        </p>
        <footer>WKWebView is a native subview; it is deliberately not part of GuavaUI's DrawList.</footer>
      </main>
      <script>
        let taps = 0;
        const button = document.getElementById('count');
        button.addEventListener('click', () => {
          taps += 1;
          button.textContent = taps === 1 ? '1 tap' : `${taps} taps`;
        });
      </script>
    </body>
    </html>
    """
}
#else
import GuavaUI

struct WebStory: View {
    var body: some View {
        StorySection(
            "Native web content",
            "The reusable WebView API is available, but this demo only ships a macOS WKWebView host today."
        ) {
            Alert(
                "No web view backend on this platform",
                message: "Provide a WebViewHost backed by WebView2, WebKitGTK or Android WebView to render real pages.",
                tone: .info
            )
        }
    }
}
#endif
