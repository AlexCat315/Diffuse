# GuavaUI DevTools

Minimal standalone client for the in-process `GuavaUIDevTools` WebSocket server.

1. Start a GuavaUI app with DevTools enabled:

   ```bash
   GUAVA_DEVTOOLS=1 swift run GuavaUIDemo
   ```

2. Open `index.html` in a browser.
3. Connect to `ws://127.0.0.1:9229/`.

The client can inspect the live node tree, select a node, request mirror frames,
and display timing/log events. Selecting a node sends `select.node` with the
stable `elementID`, which the host uses to draw a runtime overlay.
