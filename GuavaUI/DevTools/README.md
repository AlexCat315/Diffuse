# GuavaUI DevTools

Minimal standalone client for the in-process `GuavaUIDevTools` WebSocket server.

The server uses SwiftNIO on macOS, Linux and Windows. Protocol dispatch and
socket transport live in the independent [Portable package](../Portable/README.md).
The previous Network.framework-only server and non-Apple no-op were removed.

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

Frame mirroring currently requires the macOS ImageIO encoder. Linux/Windows
hosts advertise tree, selection, log, timing and configured state providers,
and omit the unavailable mirror capability.

For a headless connection test, run
`swift run --package-path GuavaUI/Portable GuavaUIDevToolsProbe` from the repository
root. It serves a real Node/Yoga diagnostic tree without GPU dependencies.

## Pick, inspect layout, edit styles

Click **Pick component**, then click a component in the actual application or
mirror. Picking includes noninteractive text and consumes the click before app
handlers. Escape cancels. The selection path lets you move to a parent container.
The layout panel shows margin, border, padding, content dimensions and flex rules.
Edit the four padding edges or background/foreground color fields to see a live
layout/repaint. Hex colors accept alpha; color swatches choose opaque colors.

**Undo / Redo**, **Clear selected**, **Clear all**, and per-property Reset control
temporary overrides. App recomposition preserves them; clearing restores current
app styles. Disconnect/stop discards overrides and history. Changes stay in memory.
Native `Text` and the shared demo honor foreground/padding; custom paint callbacks
must read effective node styles. See [inspection protocol](protocol-inspection.md)
for messages, lifecycle, limits and custom host integration.

The [Wasm prototype](../Browser/README.md) embeds the same client and uses
`browser://guava` over a same-origin MessageChannel. This transport requires the
Inspector to be embedded in its browser host.

By default DevTools installs the process-wide swift-log tap. If the host already
calls `LoggingSystem.bootstrap`, configure DevTools with
`autoInstallLogTap: false` and add `LogTap` to the host's multiplex handler.

The default endpoint is loopback-only. Binding to `0.0.0.0` or `::` exposes
remote input and state restore to the local network; only do this on a trusted
development network.


## Shared Compose and reproducible input

The [Wasm host](../Browser/README.md) and desktop `GuavaUIDemo --shared-counter`
run one Compose source with real ViewGraph, Yoga and input dispatch. Their Inspector
supports Capture/Restore/Diff and Record/Stop/Replay. `state.diff` accepts the baseline
string dictionary and returns `{added, removed, changed: {key: {before, after}}}`.
The tree invalidation log attributes State writes to their Compose scope.

Input recordings use version 1 with `initialState`, optional `focusTarget`, `events`
(`milliseconds`, Codable `event`) and `truncated`. Replay restores initial state and
focus, then dispatches events in order with composition/layout between events. It does
not reproduce wall-clock delays. The limits are 4096 events and 768 KiB. Native recording is owned by
one connection and is stopped on disconnect. Hosts provide `inputRecordingStart`,
`inputRecordingStop`, `inputReplay` callbacks and observe input with the window
session's `inputObserver`; controls are enabled only with capability `recording`.

Browser development reloads use `npm run dev`; successful complete builds restore
checkpoints, and compile failures keep the previous page usable with an error overlay.
