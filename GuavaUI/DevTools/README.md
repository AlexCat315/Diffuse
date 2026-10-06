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

## Source location and component recomposition

Select a component in the app/tree, then use **Source & recomposition → Open
source** to open the recorded Swift expression in VS Code or Cursor. For a
remote/CI build, expand **Editor path mapping** and enter the build-machine
repository prefix and your local repository prefix. POSIX and Windows absolute
paths, spaces and Unicode are supported. Preferences stay in this browser.
Your OS/browser must have the chosen editor's URI handler installed.

`ViewBuilder` automatically captures `#fileID`, `#filePath`, `#line` and `#column`
for view expressions. These wrappers add no scene nodes and preserve keyed
reconciliation. Bodies with an explicit `return`, manually assembled child lists,
and explicitly declared concrete `Body` types may bypass automatic capture;
use `.sourceLocation()` at the component's creation site when exact coordinates
matter (for example, `ConcreteBodyView().sourceLocation()`).
`graph.install(root:)` also records its call site as a root fallback. If a node
has no coordinates, the Inspector labels the nearest ancestor location explicitly.
Locations refer to the compiled source version; rebuild after moving code.

The selected node's **owning user component** shows recomposition count, last,
average, total and maximum time, plus a separate initial-mount time. Causes include
named `@State` writes, observable registrar keys, dynamic properties, parent scope
updates and changed CompositionLocal providers. Cause links select the originating
parent component. Same-scope queued writes coalesce and retain at most 16 distinct
causes; actual parent-driven body evaluations are also counted. Only property/key
names are recorded, not state values. Temporary style edits and viewport layout
changes do not count as body recomposition.

Expand **All components** to sort by count, total or last duration and select a
row. **Reset statistics** clears counters, update durations and causes for live
components, preserving initial-mount times, app state and style undo history.
Removed components disappear and new instances start fresh. Measurements use a
monotonic clock around body evaluation plus reconciliation; layout/GPU paint is
excluded, and parent durations include child work, so rows must not be summed as
frame time. Profiling is lightweight and enabled by default; custom hosts may set
`graph.tracksRecomposition = false` before installation.

Native and Wasm hosts publish identical additive snapshot fields. See
[component analysis protocol](protocol-analysis.md). Editor jumps construct a
client-side `vscode://file`/`cursor://file` link; the runtime never reads a source
file or executes an editor command.

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

## State observation, timeline and source breakpoints

Use `@State(expose: true)` to register a field for read-only observation; a
`summary:` callback can abbreviate or redact it. **Observed state** lists metadata
without reading values. Check individual fields to watch their current summaries,
or filter to the selected component. Custom hosts can register providers on
`graph.stateRegistry`. Registration follows component lifetime.

**Record timeline** captures actual component/commit, Yoga layout and draw-list
CPU spans. Filter stages, click a component span to inspect it, then stop and
**Export trace** for a Chrome/Perfetto-compatible JSON capture. Recording is opt-in
and bounded; parent and child durations overlap. GPU execution is excluded.

**Add breakpoint** forwards the mapped source coordinates to the companion
GuavaUI-vscode extension's existing VS Code/Cursor debugger API. Build and reload
that extension to enable its URI handler and node-tree context command. See
[observation protocol](protocol-observation.md) for registration APIs, lifecycle,
wire messages and bounds.

This implements source navigation and an editor breakpoint API handoff for native
Swift. A live VS Code/Cursor Swift/LLDB debug session has not been tested end to
end; launch/attach, pause, stepping, stacks and debugger variables remain with
the existing editor debugger. Wasm source debugging requires a separate tool
integration that supports Swift/Wasm debug information.

Run the native Inspector acceptance suite without a Wasm SDK or GPU:

```bash
swift build --package-path GuavaUI/Portable --product GuavaUIDevToolsProbe
python3 GuavaUI/Browser/verify.py --native-only
```

The Python runner needs Playwright and Chromium. It exercises real WebSocket
source/profile, picking/styles, selected state values, timeline start/stop/export,
breakpoint URLs and disconnect/reconnect cleanup.
