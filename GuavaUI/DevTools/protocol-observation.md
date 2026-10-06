# State observation and CPU timeline

Additive capabilities in `guava-devtools/0.1`: `state.observe` and `timeline`.
The checkpoint/restore capability `state` remains independent.

## Explicit state exposure

State values stay private by default. Compose registers only opted-in fields:

```swift
@State(expose: true) var count = 0
@State(expose: true, summary: { _ in "<redacted>" }) var token = "secret"
@State var password = "" // never registered
```

ViewGraph owns a `StateRegistry`. Fields have stable `scopeID:property` IDs across
parent reconciliation, including copying storage into replacement views. Scope
teardown unregisters them; a remounted scope gets a new ID. Summary callbacks
run on the scene thread only when that ID is watched. Binding writes use the
same storage. Observation is read-only and does not participate in restore.

Custom hosts can register model/observable/host summaries explicitly:

```swift
let token = graph.stateRegistry.register(name: "selection", valueType: "Selection") {
    model.selectionDescription
}
tools.stateRegistry = graph.stateRegistry // before tools.start()
// When the provider is no longer live:
if let token { graph.stateRegistry.unregister(token) }
```

AppRuntime and GuavaUIDemo attach their graph registry automatically. Other
hosts call `server.broadcastObservations()` on the scene thread after a state
change or frame; `DevTools.notifyTreeChanged()` / `notifyFrameFinished()` do this.

| Request | Payload | Reply |
| --- | --- | --- |
| `state.list` | none | `state.list.ok` with registry metadata and empty `values` |
| `state.subscribe` | `{ "ids": ["17:count"] }` | `state.subscribe.ok` with metadata and requested values |
| `state.unsubscribe` | none | `.ok`; clears this connection's watch list |

A subscription replaces the previous list. Subsequent `state.observation`
messages carry `{registered, values}`; unchanged snapshots are suppressed per
connection. `registered` items contain `id`, `name`, `valueType`, optional
`scopeID`. Values contain `id`, `summary`, `truncated`. Unknown/removed IDs yield
no value. The client prunes removed watch IDs and ignores superseded subscribe
replies. No values are embedded in tree snapshots or metadata-only responses.

Limits: 512 registered fields, 128 distinct watch IDs per connection, 256 UTF-8
bytes per ID, 160 characters per label/type, 1024 characters per value summary.
Invalid watch payloads use `bad_request`; missing providers use `unsupported`.
Large or sensitive values should use an explicit abbreviated/redacted summary.
Disconnect releases subscriptions; it does not alter application values.

## Performance timeline

`timeline.subscribe` / `timeline.unsubscribe` take no payload. The first active
subscriber starts a fresh recorder; additional subscribers join that capture.
Removing the last subscriber, disconnecting or stopping DevTools disables it.
Every connection receives each event once as incremental `timeline.events`.
The host reads only spans after the oldest active connection cursor; it does not
serialize the entire retained capture every frame.

```json
{
  "events": [{
    "sequence": 1, "phase": "component", "name": "MyApp.Counter",
    "scopeID": "17", "startMs": 0.25, "durationMs": 0.18,
    "reasons": [{"kind": "state", "detail": "count"}]
  }],
  "dropped": 0
}
```

All stages share the recorder's monotonic clock. `component` spans measure body
and reconciliation; `recomposition` spans cover committing pending scopes;
`layout` spans measure actual Yoga passes and writing frames back; `draw` spans
measure text/geometry/draw-list generation in the host. Clean skipped layout
passes create no event. Parent bodies and commits include child work, so their
spans overlap and must not be summed. GPU execution/presentation is not part of
these CPU spans. Native timing summaries remain unchanged; the browser also
reports optional `recompositionMs` and excludes it from `layoutMs`.

The recorder keeps the latest 2048 events in a constant-time circular buffer;
`dropped` counts events evicted during this capture. Sequence IDs increase across
captures. The Inspector retains at most 2048 events, renders the latest 120
matching the stage filter, navigates component spans to live scopes, and exports
Chrome trace-event JSON with microsecond timestamps/durations and numeric thread
IDs. Stop preserves the captured client events for inspection/export; disconnect
clears them. Drawing/layout subscriptions do not force extra application frames.
The client coalesces tree/timeline DOM updates to animation frames and keeps
unchanged state watch controls attached while frames arrive.

Native `timing.frame` now includes optional `presented`: true means the host
submitted/presented the swapchain frame, false means the surface was unavailable,
and absence means an older host. It does not measure GPU completion or display
visibility. Skipped frames still publish CPU work, State observations and timeline
events. The Inspector labels reciprocal CPU time `cpuThroughputFPS`, rather than
display FPS. Unavailable surfaces retry at display cadence while retaining dirty
work; the demo logs transitions instead of every retry.

## Source breakpoints

**Add breakpoint** uses the same validated VS Code/Cursor source path mapping as
**Open source**, then opens
`vscode://guava.guavaui-devtools/breakpoint?file=...&line=...&column=...` (or
`cursor://`). The matching GuavaUI-vscode extension registers an editor URI
handler and adds a `SourceBreakpoint` through `vscode.debug.addBreakpoints`.
Existing Swift/LLDB debug sessions own resolution, pause, stepping and removal;
no debugger command or source-file read is sent to the application host.

The extension validates absolute paths and positive integer coordinates, rejects
ambiguous query fields, checks local document bounds and avoids duplicate line
breakpoints. Source-bearing nodes also have **Add Source Breakpoint** in their
VS Code tree context menu. Build/reload the companion extension before using the
link. A breakpoint may stay pending until the existing debug adapter resolves it.
The editor registers a line breakpoint: exact Swift source columns may precede
all executable DWARF locations and otherwise remain unresolved in LLDB. Source
navigation still reveals the original column.

The companion extension's `npm run test:debug` verifies its source-node command
in a real VS Code Swift/LLDB DAP session: pending and runtime component breakpoints,
deduplication, pause, single step, call stacks and variable scopes. It launches a
diagnostic process only in the isolated test; the product does not launch/attach
a debugger or expose execution controls. Reuse the application's existing native
Swift debug configurations. The OS URI dispatch and Cursor session are not part
of this test. Browser Wasm source debugging still needs a separate tool integration
that understands Swift/Wasm debug information.
