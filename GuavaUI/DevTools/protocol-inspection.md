# Scene inspection and temporary styles

An additive extension to `guava-devtools/0.1`. Hosts advertise `inspect` for
visual picking and `style` for editable styles. Existing messages and optional
snapshot fields remain compatible with older clients.

| Request | Payload | Effect |
| --- | --- | --- |
| `inspect.pick.start` / `.stop` | none | Arm/cancel picking in the host's primary window |
| `inspect.hover` | `{x, y}` | Highlight the component under window-space logical coordinates |
| `inspect.pick` | `{x, y}` | Select that component and stop picking; useful in the mirror |
| `inspect.style.set` | `{id, properties}` | Atomically merge temporary properties for a live node |
| `inspect.style.undo` / `.redo` | none | Undo/redo the last style transaction |
| `inspect.style.clear` | `{id}` | Remove all overrides for one node; undoable |
| `inspect.style.clearAll` | none | Remove all overrides; undoable |

Prefer decimal `elementID` from the snapshot for `id`; legacy object identifiers
are also accepted. Unknown/stale nodes fail without changing history or styles.
Successful commands respond as `requestType.ok` with the request `id` and current
inspection state; failures use `requestType.err` and `{code, message}`. Replies do
not imply a frame has presented: tree/layout deltas follow the next layout pass.

```json
{
  "type": "inspect.style.set",
  "id": 42,
  "payload": {
    "id": "17",
    "properties": {
      "padding": {"top": 12, "right": 20, "bottom": 12, "left": 20},
      "backgroundColor": "#203040ff",
      "foregroundColor": "#ffffff"
    }
  }
}
```

Padding requires all four physical edges in logical points, finite and within
0…4096. Color syntax is ASCII `#RRGGBB` or `#RRGGBBAA`; transparent colors may use
alpha `00`. `null` removes that property's override. Omitted properties retain
their existing overrides. Unsupported properties/unknown keys fail atomically.
Composition anchors without a Yoga layout box reject non-null padding edits.

`tree.snapshot` and `tree.delta` include optional `inspection`:

```json
{"selectedID":"17","hoveredID":"18","picking":true,"canUndo":true,"canRedo":false,"overrideCount":1}
```

Node summaries include optional `layout` with Yoga-resolved padding/margin/border,
content width/height, flex direction/alignment/justification/grow/shrink, and
optional `style` with effective background/inherited foreground hex colors and
the names of overridden properties. Missing colors mean transparent or inherited
defaults; custom painters may choose additional colors independently.

Visual picking follows sibling z-order and tree paint order, absolute frames,
scroll offsets and ancestor clipping. It includes text, containers and disabled
controls, and excludes invisible subtrees. It uses axis-aligned layout boxes;
rounded corners, transparent pixels and custom paint shapes are not pixel hit
tests. Hover displays padding bands. Selection and hover overlays are independent
DrawList commands and never overwrite application borders or styles.

The shared input interceptor consumes picking motions, button/key/text input and
the selected gesture's release before app handlers or recording. Escape cancels.
The native Inspector can pick directly in the app window on all supported desktop
platforms; mirror picking requires the existing macOS ImageIO mirror capability.

Overrides live separately from authored node/Yoga styles. Recomposition and app
style writes keep updating the underlying values; clear/undo reveals the latest
app value, including authored percentage and logical/RTL padding. Removing a node
clears its overrides; history never recreates nodes. Custom native painters must
read effective node foreground and resolved padding to honor these edits.
Native `Text` and the shared browser/desktop demo do so.

History holds at most 128 transactions and overrides at most 256 live nodes.
Edits remain in memory and do not rewrite Swift sources. Native editing is owned
by one connection at a time; another editor receives `busy`. Disconnecting that
connection or stopping DevTools discards its styles, history and picking state.
A connection lease prevents delayed commands/cleanup from modifying a later
connection's scene. Browser `bye`, reconnect and page rebuilds also clear overrides.

Custom hosts wire `SceneInspector.editor.handle`, `.reset`, `.intercept` and
`.drawOverlay`, request redisplay on `.onChange`, compute layout before painting,
and publish a settled snapshot. `DevTools` plus AppRuntime/GuavaUIDemo install
these hooks; `PlatformWindowSession.inputInterceptor` runs before `inputObserver`.
