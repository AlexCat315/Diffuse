# GuavaUI DevTools

Minimal standalone client for the in-process `GuavaUIDevTools` WebSocket server.

1. Start a GuavaUI app with DevTools enabled:

   ```bash
   GUAVA_DEVTOOLS=1 swift run GuavaUIDemo
   ```

2. Open `index.html` in a browser.
3. Connect to `ws://127.0.0.1:9229/`.

The client can inspect and filter the live node tree, select a node, request
configurable mirror frames, display timing/log/runtime inventory data, capture
and restore host checkpoints, and forward pointer, wheel, text, and common
keyboard input through the mirror. Selecting a node sends `select.node` with the
stable `elementID`, which the host uses to draw a runtime overlay.

Tree, log, timing, and mirror streams are opt-in per connection. Disconnecting
also releases pressed input and clears the runtime selection overlay.

By default DevTools installs the process-wide swift-log tap. If the host already
calls `LoggingSystem.bootstrap`, configure DevTools with
`autoInstallLogTap: false` and add `LogTap` to the host's multiplex handler.

The default endpoint is loopback-only. Binding to `0.0.0.0` or `::` exposes
remote input and state restore to the local network; only do this on a trusted
development network.
