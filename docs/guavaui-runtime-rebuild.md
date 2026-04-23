# GuavaUI Runtime Kernel Rebuild

The current GuavaUI runtime conflates element identity, layout, paint, input,
state, and CompositionLocal storage onto a single `Node` reference type. The
frame loop is full-tree every paint, the reconciler reuses by `(viewTag, index)`
prefix, and diagnostics expose only `frame` plus a handful of flags. This
document defines the target architecture and the phased migration that gets
there without leaving the editor and demos broken between phases.

## Target subsystems

### 1. ElementTree + Reconciler

- `ElementID`: opaque, monotonically allocated `UInt64` minted by an
  `IdentityAllocator`. Stable across recompose; reused only after explicit
  teardown.
- `ElementKey`: optional user-provided key (from `.id(_:)` modifier) plus the
  view's static type. Reconciler matches by `(parent, key)` first, then by
  `(parent, type, sibling slot)`.
- `ElementNode`: thin record (id, key, type tag, parent id, children ids,
  scope link). No layout/paint/input fields.
- `ElementTree`: id → ElementNode store plus parent/child arrays.
- `Reconciler`: builds a new child id list from the new view list, matching
  against the prior id list. Survivors keep their state, layout, render, and
  input bindings. Misses are torn down; new ids are minted.

### 2. StateStore

- Side table keyed by `ElementID` storing:
  - `attachments: [AttachmentKey: Any]` (replaces `Node.attachments`).
  - `compositionValues: [CompositionKey: Any]` (replaces
    `Node.compositionValues`).
  - `scope: ViewScope?` for user-view bodies.
- Compositional lookups walk the parent id chain via `ElementTree`.
- Lifetime tied to `ElementID`. Teardown emits a single `release(id)` call.

### 3. LayoutTree

- `LayoutObject`: Yoga-backed measure/style/cache. Owned by the LayoutTree,
  paired with an `ElementID`.
- LayoutTree owns dirty propagation for layout-only changes (no `markRenderDirty`
  side effects from style writes).
- Text measure cache lives in the LayoutTree, keyed by element id + content
  hash, not stuffed into `attachments`.
- Result: `frames: [ElementID: CGRect]` consumed by the RenderTree builder.

### 4. RenderTree (retained) + LayerTree

- Typed `RenderObject` enum: `solid | rounded | border | shadow | glyphs |
  image | clip | offset | custom`. Each carries the data it needs to emit
  draw commands; nothing is a closure on `Node`.
- A `RenderObject` belongs to an `ElementID` and lives across frames.
- `LayerTree`: groups render objects into composited layers (clip, opacity,
  scroll). A layer caches its baked `DrawList` segment.
- Frame loop: walk dirty layers only, rebuild their segments, splice into the
  frame draw list. Clean layers reuse last frame's segment verbatim.
- Effects like opacity/contentOffset become layer attributes, not per-node
  fields on `Node`.

### 5. InputScene

- `InputNode`: hit shape (rect or path), hit-testable flag, focusable flag,
  focus order, cursor, input attachments (`TextInputArea`, IME anchor, scroll
  wheel target, drag handler).
- InputScene is rebuilt from layout + render output during commit, not from
  draw-time side effects. TextField publishing IME area moves out of the draw
  callback.
- Dispatcher walks the InputScene only — no traversal of paint/layout fields.
- Pointer capture, focus chain, hover path all key off `ElementID`.

### 6. Diagnostics

- `InvalidationLog` ring buffer of `DirtyReason {
    target: ElementID,
    source: SourceKind, // .stateWrite(scopeID) | .styleSet(field) | .layoutChange | .focusChange | .platformResize
    phase: .layout | .render | .input,
    timestamp,
  }`
- `FrameTrace`: per-frame counters: recomposes executed, layouts run, draw
  batches emitted, layer cache hit/miss, glyph atlas uploads, ms per phase.
- `SceneInspector` exposes ElementTree + StateStore summary + last N invalidation
  records + last N FrameTrace samples.

## Migration phases

Each phase ends green: `swift build` for GuavaUI + Editor, full GuavaUI test
suite, and an editor smoke run.

### Phase 1 — Identity & invalidation diagnostics (this PR)

Foundation only. No behavior change. Runtime keeps using `Node`.

- Add `ElementID` (UInt64, opaque struct) and `IdentityAllocator`.
- Mint an `ElementID` for every `Node` at construction; store on `Node`.
- Add `InvalidationLog` + `DirtyReason` types in `GuavaUIRuntime`.
- `Node.markDirty` / `markRenderDirty` accept an optional `DirtyReason` and
  record into the active log.
- `NodeTree.flush` records phase timings into a `FrameTrace` accumulator.
- `SceneInspector` snapshot adds `elementID`, last invalidations, last frame
  trace.
- DevTools protocol gets the new fields (additive, backward compatible).

### Phase 2 — ElementTree + Reconciler shadow

- Introduce `ElementTree` and `IdentityAllocator` as the source of truth for
  id, key, parent, children. `Node` becomes an attribute carrier addressed by
  `ElementID`.
- Move `attachments` and `compositionValues` to a `StateStore`, keyed by
  `ElementID`. Provide back-compat shim properties on `Node` so primitives
  keep compiling.
- Replace `(viewTag, index)` reuse in `ViewGraph` with key-aware reconciliation
  through the new tree. Add `.id(_:)` modifier.
- Preserve user-view nested `@State` across parent recompose by anchoring
  scopes on `ElementID` instead of anchor `Node` identity.

### Phase 3 — LayoutTree extraction

- Spin `LayoutObject` out of `LayoutNode`. Move text measure cache off
  primitives into `LayoutTree`. Drop `attachments` on `LayoutNode`.
- Layout dirtiness becomes a separate flag on the LayoutTree, not a side
  effect of style writes on `Node`.

### Phase 4 — RenderTree + LayerTree

- Define `RenderObject` enum and `LayerTree`. Each primitive emits render
  objects during commit, not draw closures on `Node`.
- Replace `NodeRenderer.renderNode` with a layer walker that rebuilds only
  dirty layers.
- Retire `Node.draw` / `Node.overlayDraw` closures.

### Phase 5 — InputScene

- Build a dedicated input tree from layout + element data during commit.
- Move `EventDispatcher` to walk InputScene exclusively. Remove
  `Node.isHitTestable`, `isFocusable`, `cursor` (read from InputNode instead).
- Move `TextInputAttachmentKey.area` publication out of `Text.draw` /
  `TextField.draw` and into commit.

### Phase 6 — Text subsystem

- Replace `TextEnvironmentHolder.current` global with a per-window
  `TextEnvironment` reachable through the StateStore as a Composition value.
- Glyph atlas uploads run during commit, not inside the host frame loop.

### Phase 7 — Cleanup

- Delete the back-compat shims left for primitives.
- Strip `Node` to the legacy alias of `ElementNode`.
- Remove the residual full-tree paint path.

## Validation per phase

- `cd GuavaUI && swift test`
- `cd Editor && swift build`
- Editor manual smoke (open editor, verify layout, click and type into
  TextField, drag a Dock tab) when input/render phases land.
