# GuavaUI portable modules

This package builds without SDL, GPU drivers, Yoga or font libraries.

- `GuavaUICore`: the shared desktop/browser `State`, `Binding`, color, geometry,
  CPU draw-list builder and WGSL. Desktop font-to-glyph layout stays in Runtime.
- `GuavaUIDevToolsProtocol`: Codable wire types for `guava-devtools/0.1`.
- `GuavaUIDevToolsServer`: shared protocol dispatch with an injectable transport.
  The default SwiftNIO WebSocket transport supports macOS, Linux and Windows.
- `GuavaUIDevToolsProbe`: a headless diagnostic host with a synthetic tree and
  state provider, for testing the real server without starting a GPU window.

From the repository root:

```bash
swift test --package-path GuavaUI/Portable
swift run --package-path GuavaUI/Portable GuavaUIDevToolsProbe
```

Open `GuavaUI/DevTools/index.html` and connect to `ws://127.0.0.1:9229/`.
Pass a port as the probe's first argument to change it. Port zero binds an
available port; `DevServer.boundPort` reports the result.

The desktop `GuavaUIDevTools` module re-exports the server and wire API. Existing
hosts continue to use `DevToolsConfig` and `DevTools` through the same imports.
Likewise Runtime keeps type aliases to the shared core. The socket transport is
never compiled into the [browser prototype](../Browser/README.md).

The WebSocket transport limits inbound messages to 1 MiB, supports fragmented
text and ping/pong, and disconnects stalled writers. Streams remain opt-in per
connection. Disconnecting the last mirror subscriber stops capture; disconnecting
the client that owns a selection clears that selection. Callbacks use the host's
UI-thread scheduler, including hosts with a synchronous SDL event loop.
