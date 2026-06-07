# GuavaKit — v2 runtime

A ground-up rewrite of the GuavaUI runtime. It exists because the legacy stack
bred a recurring *class* of bugs (the dropdown "works once then stuck", the
portal leak, the white-model). Those weren't bad luck — they came from four
architectural smells:

1. **Scattered implicit invariants.** "Any geometry change must invalidate the
   hit-test cache" was copy-pasted into `frame`/`contentOffset`/`zIndex`
   `didSet`s. `frame` forgot one line → stale hits → stuck dropdown.
2. **Many trees synced by hand.** Node / Layout / Render / Input were 4 parallel
   trees kept in sync by hand-placed `reconcile/refresh/tearDown` calls. Miss
   one and you get stale state (teardown didn't clean the portal registry).
3. **Process-global mutable singletons.** One stale entry broke *every* instance.
4. **Cleanup by side-effect.** Popover relied on a modifier's `apply()` to
   unregister itself; teardown bypassed it → leak.

## The two rules that kill those bug classes by construction

GuavaKit is built so the bugs above are **not expressible**:

### Rule 1 — geometry mutates through exactly one funnel
`UINode.geometry` is `private(set)`. The *only* way to change it is
`setGeometry(_:)`, which diffs old→new into `DirtyFlags` and calls
`context.invalidate(node, flags)`. Every cache (hit-test, paint, layout)
subscribes to flags in that single `invalidate`. There is no per-property
`didSet` to forget — forgetting is impossible because there is no second path.

### Rule 2 — resources are owned by node lifecycle, released on detach
Anything a node registers with the outside world (a portal entry, a pointer
capture, an input handler) is a `NodeResource` attached to the node. When the
node leaves the tree — for *any* reason: closed, parent removed, panel swapped —
`UIContext.detach` walks the subtree and calls `unmount` on every resource.
Cleanup can't be skipped, and it never depends on a modifier running.

## Scope, not globals
`UIContext` is per-tree (per window). It owns the dirty pipeline and the
registries (portals, hit index, …). Nothing is a process global, so one tree's
state can never corrupt another's.

## Build order (rewrite roadmap)
1. **Core** ← *you are here*: `UINode`, `Geometry`, `DirtyFlags`, `UIContext`,
   `NodeResource`, `HitTestIndex`. The architecture's heart.
2. Layout (Yoga bridge, behind the same invalidation pipe).
3. Input / hit-test dispatch + pointer capture (scoped).
4. Paint / render tree.
5. Recompose + declarative `View` layer.
6. Primitives (Box/Text/Button/Popover/…).
7. Editor switches over once at parity.

Each step keeps the package compiling and its tests green; the legacy GuavaUI
targets stay untouched until the very end.
