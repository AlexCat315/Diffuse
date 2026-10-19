# GuavaUI DevTools

Minimal standalone client for the in-process `GuavaUIDevTools` WebSocket server.

The server uses SwiftNIO on macOS, Linux and Windows. Protocol dispatch and
socket transport live in the independent [Portable package](../Portable/README.md).
The previous Network.framework-only server and non-Apple no-op were removed.

1. Start a GuavaUI app with DevTools enabled:

   ```bash
   ./guava run GuavaUI/Examples --devtools
   # Application project:
   ./guava run /path/to/MyApp --devtools
   ./guava run /path/to/MyApp --android --devtools --device DEVICE_SERIAL
   # Connect to an existing CLI-managed session:
   ./guava devtools /path/to/MyApp
   ```

The CLI opens this Inspector with the runtime's authenticated endpoint. Dynamic
ports and per-session tokens allow multiple apps/devices without a shared fixed port.
Use `--no-open` for headless runs and `--session ID` to select an existing session.
Android uses a CLI-owned ADB forwarding lifetime; Ctrl+C removes the forwarding.

For direct framework development, `GUAVA_DEVTOOLS=1 swift run --package-path
GuavaUI/Examples GuavaUIDemo` still enables the loopback service at the default
port 9229. Open Client/index.html and connect manually in that workflow. Ordinary apps
use the same runtime diagnostics service; no demo-specific API is required.

The client can inspect and filter the live node tree, select a node, request
configurable mirror frames, display timing/log/runtime inventory data, capture
and restore host checkpoints, and forward pointer, wheel, text, and common
keyboard input through the mirror. Selecting a node sends `select.node` with the
stable `elementID`, which the host uses to draw a runtime overlay.

Tree, log, timing, and mirror streams are opt-in per connection. Disconnecting
also releases pressed input and clears the runtime selection overlay.

Desktop tree snapshots are captured on the scene thread and encoded once on a
dedicated background worker. Full-tree updates are limited to at most 10 Hz;
bursts keep one pending notification and capture the latest tree after the active
update, including the last change before the app becomes idle. Unsubscribed
clients do not cause tree capture. Timing, state and input requests use the
separate server queue and do not wait for tree JSON encoding.

The loaded Editor has also passed connection acceptance with 1,036 nodes and
approximately 1.1 MB per snapshot: continuous temporary layout edits, final idle
update delivery, layout/draw/component timeline, mirror output, and three
disconnect/reconnect cycles. The connection regression previously spent about
2.3 seconds per frame parsing tree JSON on the main thread. In the same test
scene after the fix, 21 selection/style requests had a median response time of
23 ms and a maximum of 61 ms. These are local debug-build acceptance results,
not a display FPS guarantee.

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
must read effective node styles. See [inspection protocol](Protocol/Inspection.md)
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
[component analysis protocol](Protocol/Analysis.md). Editor jumps construct a
client-side `vscode://file`/`cursor://file` link; the runtime never reads a source
file or executes an editor command.

The [Wasm prototype](../Browser/README.md) embeds the same client and uses
`browser://guava` over a same-origin MessageChannel. This transport requires the
Inspector to be embedded in its browser host.

Application startup installs [GuavaLogging](../../Engine/Logging/README.md), independently of DevTools. The Inspector subscribes to bounded startup history and live records; it does not install or replace swift-log. The Logs panel supports level/module/text filters, structured metadata and source details, pause display, loss counts and JSONL export. See [log protocol](Protocol/Logs.md). Hosts with an existing swift-log backend select local installation in the application's logging configuration.

The default endpoint is loopback-only. Binding to `0.0.0.0` or `::` exposes
remote input and state restore to the local network; only do this on a trusted
development network.


## Shared Compose and reproducible input

The [Wasm host](../Browser/README.md) and desktop `GuavaUIDemo --shared-counter`
run one Compose source with real ViewGraph, Yoga and input dispatch. Their Inspector
supports Capture/Restore/Diff and Record/Stop/Replay. `state.diff` accepts the baseline
string dictionary and returns `{added, removed, changed: {key: {before, after}}}`.
The tree invalidation log attributes State writes to their Compose scope.

Input recordings use version 2 with `initialState`, optional `focusTarget`, `events`
(`milliseconds`, Codable `event`) and `truncated`. Wheel events preserve the typed
`scroll` group: points/lines/pages, stream precision, finger phase, independent
momentum phase and monotonic timestamp. The browser mirror maps DOM `deltaMode`
and direction into this protocol; native point input is not multiplied by a line
step or display density. Version 1 recordings are not decoded. Replay restores initial state and
focus, then dispatches events in order with composition/layout between events. It does
not reproduce wall-clock delays. The limits are 4096 events and 768 KiB. Native recording is owned by
one connection and is stopped on disconnect. Hosts provide `recording.start`,
`recording.stop`, `recording.replay` callbacks and observe input with the window
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
[observation protocol](Protocol/Observation.md) for registration APIs, lifecycle,
wire messages and bounds.

The extension adds line breakpoints and reveals the original source column.
Its source-node command has been verified in a real VS Code Swift/LLDB DAP
session, including pending/live breakpoint hits, pause, step, stacks and variable
scopes. Cursor and OS URI dispatch still need separate acceptance. Launch/attach
and execution control remain with the editor debugger. Wasm source debugging
requires a separate tool integration that supports Swift/Wasm debug information.

Native timing distinguishes submitted and skipped swapchain frames. A locked or
occluded window can skip presentation while State observations, CPU timeline and
offscreen mirror continue. Failed frames retain dirty work and retry at display
cadence. `cpuThroughputFPS` is a CPU work estimate, not measured display FPS.
The macOS SDL loop flushes pending Core Animation transactions before drawable
acquisition. Unlocked native window display, State/layout updates, CPU timeline,
Metal mirror and pointer input have passed
`npm run verify:native-demo -- --require-presented`; the check requires submitted frames
after each update.
Native window zoom and restore have also passed visual acceptance; the demo now
reallocates its MSAA target when the drawable dimensions change.

Run the native Inspector acceptance suite without a Wasm SDK or GPU:

```bash
swift build --package-path GuavaUI/Portable --product GuavaUIDevToolsProbe
swift run --package-path Tools/Developer guava-dev browser verify --native-only
```

The runner needs Chromium. It exercises real WebSocket
source/profile, picking/styles, selected state values, timeline start/stop/export,
breakpoint URLs and disconnect/reconnect cleanup.

## Profile and platform adapters

`guava run --profile` uses Swift Release optimization with GUAVA_PROFILE and
keeps an opt-in diagnostics service. Streams are still subscription-driven;
CPU instrumentation and picture mirroring have measurement overhead and should
be enabled only for the investigation. CLI --release rejects --devtools, and
fromEnvironment does not enable a production Release runtime.

Android now connects the same scene protocol to its UI-thread Handler, including
while the surface is paused. It advertises tree/selection/styles/source/component
analysis/state observation/CPU timeline/timing. It does not advertise picture
mirroring or arbitrary checkpoint/recording providers that its host has not
installed. Its timing presentMs covers host work after draw-list preparation,
including GPU command submission/waiting; it is not GPU execution duration.

Run against an existing CLI-managed session:

```sh
guava-dev devtools session /path/to/MyApp mac
guava-dev devtools session /path/to/MyApp android
```

## AI-driven component acceptance

No OS automation is needed. Start the Gallery through the Guava CLI, query its
live AI diagnostics, inject input through DevTools and inspect the renderer mirror.
Arguments after `--` go to the Gallery, so a page, width and input mode are
selected at launch. `guava devtools` actions resolve the project's single live
session (add `--session ID` when several run):

```sh
./guava run GuavaUI/Examples --mac --devtools --no-open -- --component list --width 390 --input touch
./guava devtools GuavaUI/Examples list                     # available AI tools
./guava devtools GuavaUI/Examples query '{"text":"Document 5","visible_only":true,"compact":true}'
./guava devtools GuavaUI/Examples click NODE_ID
./guava devtools GuavaUI/Examples input @events.json
./guava devtools GuavaUI/Examples capture /tmp/gallery.jpg --settle-ms 400
```

A bare JSON object runs `query_ui_nodes`; `query TOOL JSON` runs any other tool.
`compact: true` returns one short record per node (id, role, label, value,
non-default state, clipped frame, `File.swift:line`) instead of the full
layout/style/view-type payload. The same actions are available as
`guava-dev devtools query-ui|input-ui|capture-ui|record-timings`, which
accept a port or an `@session.json` / `@runtime.json` file. Managed sessions retain their authentication
token and device-forwarded port inside the connection; copying a token into shell
commands is unnecessary. Select a component through the Gallery search, then
inspect the narrow/wide/touch previews and change scale or appearance in the UI.
Build/test changes with `./guava test GuavaUI --no-parallel --filter TEST`.

Gallery flags: `--input touch|mixed|pointer`, `--dark`, `--text-scale 2`,
`--rtl`, `--reduce-motion`. Width and height still follow the real window after
resize. These overrides are transient and never change authored configuration.
The host may clamp window height to the available display; use the mirror's
logical dimensions and queried visible frames as the actual acceptance size.

`input-ui PORT --click-node ID` resolves a live, visible, enabled hit region.
`input-ui PORT --input @events.json` accepts pointer, wheel, keyboard and text
events, plus `{"kind":"wait","milliseconds":100}` between events. Each wait is
at most 2 seconds and the sequence's total wait budget is 10 seconds. One
connection stays open throughout the sequence, preserving capture while the
host produces intermediate frames. Start a drag with a small move inside the
target before moving outside its bounds. Input acknowledgements confirm delivery;
always query the resulting value and inspect a fresh mirror image to verify it.

Input fields keep their values lazy. Ordinary node discovery does not read them.
Keyboard events use browser `KeyboardEvent.code`, for example
`{"kind":"keyDown","key":"KeyA","modifiers":["cmd"]}`. Numeric USB-HID
`scancode` is also accepted by the CLI, including letters and digits. Unsupported
or missing key codes fail before delivery instead of reporting a successful
sequence whose shortcut was ignored.

For modal and menu entrance animations, use
`capture-ui PORT OUTPUT.jpg --settle-ms 400`. The optional delay is bounded to
0–2000 ms and recorded in the capture's JSON sidecar. It lets the host advance
its animations before the mirror starts; it is a sampling delay, not an assertion
that an async operation has completed. Query the expected state as well.

After locating the actual `textField` node (rather than a debug-name wrapper),
explicitly request its current draft/value through the same AI query:

```sh
guava-dev devtools query-ui 9231 query_ui_nodes \
  '{"node_id":"177","include_value":true}'
```

The response puts the value in `semantics.value` and reports `valueTruncated`.
Output is capped at 4096 Unicode characters; `include_value` requires one
`node_id`, and unmounted IDs fail. Secure fields return `<redacted>` without
evaluating their value provider. No private `@State` is exposed by this read.

Touch surfaces use GuavaUI's unified pointer dispatcher, including real touch
scroll/refresh/swipe recognition and 44pt hit regions. They test component
behavior; platform IME and physical device adapters still need device acceptance.
The mirror replays the application's draw list and excludes OS compositor chrome.
Its native render target is sampleable and supplies the renderer's backdrop
source, so frosted menus and other backdrop effects match the application's
rendering. `MirrorBackdropTests` verifies actual Metal pixels before and after
capture resize.
Native display links paused by hidden/occluded windows report themselves
unavailable, so the host's deadline clock still advances animations. This keeps
an AI-opened modal from remaining transparent when another test window covers
it; the mirror remains useful without foregrounding or OS automation.


## Ownership and directory structure

- `Client/Connection` owns WebSocket and embedded browser transports and message dispatch.
- `Client/Inspector` owns the tree, runtime inventory and temporary layout/style edits.
- `Client/Analysis`, `Client/State`, `Client/Diagnostics`, and `Client/Mirror` own their respective panels.
- `Client/Session` owns grouped session state and common controls; `Application.js` only composes factories and startup events. Factories receive explicit session/elements/peer operations.
- `Protocol` documents the shared protocol. Swift message models remain canonical in Portable, separate from HTML rendering.
- Portable server `Session`, `Transport`, `Tree` and `Requests` separate lifecycle, sockets, tree encoding and request domains. Typed host adapters group scene, checkpoints, recordings, observations and mirror callbacks.

CLI discovery files, connection tokens, ADB forwarding and temporary edits are session data, never application manifest or authored checkpoint fields.
