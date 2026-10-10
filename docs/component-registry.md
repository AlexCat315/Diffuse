# Component registry

Each `SceneRuntime` owns a value-type `ComponentRegistry` through its world. New
scenes receive `ComponentRegistry.builtIn`; modules register additional schemas
on the scene or pass a configured registry to its initializer. Registration does
not affect other scenes. Schema closures are `@Sendable` and duplicate type IDs
are rejected.

`ComponentSchema` supplies a stable document key, display name, category,
presence check, codec, default construction and removal. `isUserAddable` excludes
components that require a dedicated creation flow. `incompatibleWith` expresses
editor add-menu exclusions. `requires` lists stable IDs of components that must
receive defaults when their owner is inserted. Spatial built-ins, including
cameras and lights, require `localTransform`.

The runtime serializer, Prefab, GameSave and editor component menu read this same
registry. ScriptRuntime contributes `script` locally; its full serialization and
prefab helpers install the script schema on the document's scene. Script handles
remain transient and decode to zero; stable binding IDs and identifiers persist.

## Document representation

Runtime scenes and prefabs keep the v3 document and its component-key dictionary.
Editor manifest v8 nodes contain `id`, `name`, `kind`, optional `localTransform`,
`components: [{ "type": "camera", "value": { ... } }]`, and `children`. Component
values use exactly the runtime codec. There are no per-component manifest slots
or legacy manifest decoders. The editor envelope continues to hold editor metadata
and scene resources separately.

`ComponentValue` is Codable and Sendable, including exact large integer seeds.
Missing node components and children default to empty arrays. Existing optional
rendering fields now include mesh LODs and material coverage overrides, which were
previously omitted by the runtime codec.

`ComponentEncodeContext.entityIndexMap` assigns document-local indices. Runtime
scenes use document entity order; editor manifests use depth-first root/child
order; prefab capture uses its subtree order. Decoding allocates all entities
before applying any component and provides the complete inverse map through
`ComponentDecodeContext`. Constraints and ragdolls use these maps, including
forward references. References outside a prefab's captured subtree retain the
existing omission behavior. Parent hierarchy remains structural document data.

Authored destruction source snapshots are selected by component codecs through
the encoding purpose. Game-save destruction session state has a separate codec
file and is never included in authored component documents. Particle codecs save
settings and module stacks, rebuilding transient simulation state when loaded.

## Verification

`ComponentRegistryTests` visits every built-in schema, verifies absent values,
default round trips and removal, and exercises a scene-local contributed component
through prefab and save paths. `Fixtures/component-registry-v3.json` was generated
from the pre-registry SceneSerializer and fixes the complete built-in component
output, including parent, constraint and ragdoll references, byte-for-byte. Treat
fixture changes as disk-format changes requiring review.

`EditorComponentRegistryTests` exercises a contributed schema through menus,
defaults, reset, undo/redo, manifest persistence and prefab instantiation. It also
compares editor and prefab component values and verifies remapped references.

Run `swift test --package-path Engine`, `swift test --package-path Editor`, and
`python3 scripts/check-swift-maintainability.py` after changing schemas.
`EditorRegistryInspectorTests` covers generated forms and their transaction bindings;
`InspectorRendererRegistryTests` covers optional rich controls and editor-session
registration lifetime.


Phase 3 replaces the per-field `SceneMutation` cases with thirteen operations:
structural scene edits plus `setComponentData`, `addComponent`, and
`removeComponentData`. `setComponentData` replaces a document by default; its
`merge` mode edits object fields recursively. Arrays replace as a whole, while
an object keyed by existing array indices edits individual compound shapes.
Unknown types, stale entity IDs, invalid array indices, and undecodable values
abort the transaction and restore the original scene snapshot. The registry
owns incompatibilities, codec application, and duplication hooks.

Transaction references use generation-qualified entity IDs (their signed Int
bit pattern), independent of document traversal indices. Duplicating a component
remaps references to the source entity onto the copy. Script handles are carried
only in transaction documents; persisted script documents still resolve handles
at load. Particle authoring edits preserve the simulation pool and RNG when the
seed is unchanged; a different seed creates a fresh simulation.

Inspector writes, including contributed typed components, resolve their schema
through the registry. Interactive history uses sets of `(entityID, typeID)` keys:
updates to one component coalesce, and switching entity or component starts a
separate undo entry. Explicit multi-selection groups still form one undo step.
Capability invocation records remain the authority for AI/plugin requests;
unrecorded generic component writes do not acquire a field capability by
inference. Generic component JSON events accompany the existing semantic field
projection.

## Required components

`RuntimeWorld.setComponent` inserts missing requirements in dependency order.
Shared transitive requirements are created once, and existing authored values
are retained. Removing an owner leaves its dependencies in place; this is an
insertion contract, not cascading ownership. Unregistered runtime-only component
types continue to work without requirements. During document assembly, explicitly
supplied dependencies decode before their owners, so missing defaults can use
authored dependency values regardless of registration or JSON field order.

Registrations may refer forward to another schema. Call `validateRequirements()`
after configuring a module to diagnose missing IDs or cycles. Registration caches
dependency plans, so ordinary component writes do not traverse the graph. Invalid
graphs, incompatible dependencies, or defaults that fail to create their component
reject insertion atomically. Typed setters return `false`; registry authoring APIs
throw an error. Failed insertions preserve components, resources and revisions.

`localTransform` is a structural schema: it participates in dependency resolution
and typed lookup, but `componentSchemas` and component document encoding exclude
it. Runtime and editor documents continue to use their existing structural
transform fields. Component duplication likewise preserves the separately copied
transform and any requested position offset.

Camera and light creation uses registry default construction, then applies only
explicit request overrides. Editor templates supply names, types and positions;
their lens, light intensity and shadow settings match the Add Component menu.
`RequiredComponentTests` covers graph validation, dependency order, atomic failure,
value preservation and document/prefab/save behavior. Editor registry tests cover
template defaults, contributed defaults, omitted transforms and undo/redo.

## Inspector and AI descriptions

`ComponentSchema.inspection` describes fields by paths into the codec document.
Fields without presentation overrides are inferred from that document, including
nested objects and numeric vectors. Overrides provide labels, groups, enum
choices, visibility conditions, read-only access and numeric display constraints.
Numeric `scale` converts stored units to display units, such as camera radians
to degrees; field paths and defaults always use stored units. Integer fields
with explicit integral bounds inside Float's exact range use rounded, bounded
number controls. Other integers use text editing to preserve large seeds and
handles. Enum choices carry a control ID, label and typed `ComponentValue`;
numeric enums such as cloth bend types retain their numeric disk representation.

`isNullable` string fields write JSON null when cleared, letting the owning codec
restore an absent optional key. Color presentation limits RGB channels to 0...1
by default; an absent `color.maximum` retains HDR values, while alpha stays in
0...1. Non-finite channels reject the whole edit. `inferredFieldsAreAdvanced`
keeps additional codec fields behind the advanced form without maintaining a
second field list. Explicit descriptors control read-only runtime or asset data.

The editor traverses the registry to build component sections. Camera, light,
audio source/listener, character controller, render mesh, render material,
animation player and rigid body use the generic form. Soft body, cloth and
soft-body mesh also generate their authored controls from the schema; small
renderers append read-only simulation and geometry diagnostics without adding
those values to persisted components. New module
registrations obtain the same form automatically. Each `EditorSceneAdapter` owns
an `EditorInspectorRendererRegistry` keyed directly by component `typeID`. Its
built-in registrations provide rich controls for particles, scripts, compound
colliders and other structured behaviors. Runtime schemas contain no editor
implementation identifiers. Missing renderers, or renderers returning `nil`,
fall back to the generated form. Component sections always carry their schema's
type ID, so workspace visibility uses the same category policy as the component
menu even when a renderer uses a different section ID.

Native modules can supply UI factories without editing the inspector dispatcher:

```swift
var renderers = EditorInspectorRendererRegistry.builtIn
try renderers.register(componentTypeID: "myModule.terrain") { adapter, entity in
    terrainSection(adapter: adapter, entity: entity)
}
let adapter = EditorSceneAdapter(componentRegistry: moduleComponents,
                                 inspectorRenderers: renderers)
```

`terrainSection` is the module's UI factory and `moduleComponents` includes its
runtime schema. Registration rejects empty IDs and duplicates; explicitly remove
a renderer before replacing it. Registries are value types, independent across
adapters, and may be configured on the UI thread before or after scene loading.
They survive reset, load and undo/redo, but are never serialized or recorded in
edit history. Factories receive the current adapter at render time; avoid
capturing its owning adapter strongly in a stored factory.

Animation playback edits use the runtime registry's merge rule: switching a clip
resets its playhead unless the caller also supplies a time. Speed, loop and play
controls retain playback progress. Full document replacement and loading still
preserve the stored time. Optional clip names, HDR emission and imported mesh /
material references retain the existing component disk format.

Rigid-body merge rules synchronize motion quality when CCD is toggled, preserving
explicit quality overrides and unrelated state. `normalizeChanges` canonicalizes
accepted partial input before merge and codec validation: deformable fixed-point
lists are sorted, deduplicated and filtered by the typed topology, and optional
mesh resource IDs are trimmed. Wrong JSON types and unknown fields still reject
the complete transaction. Full document replacement and loading bypass partial
input normalization. Transaction postconditions replay normalized requests on
value snapshots from the original document, preserving sequential array-index
semantics and checking only asserted fields. Published events contain canonical
component data.

Generic bindings patch one document path through component transactions. Undo,
redo, interactive cancellation and multi-selection use the existing history
flow. Vector edits patch individual array indices to retain the other axes.
Locked entities and components removed after presentation reject stale edits.
The typed codec still validates the resulting document; presentation hints do
not replace component invariants.

`SceneRuntime.componentDescriptions(typeID:)` returns Codable descriptors from
the same inspection metadata and codec defaults without changing the scene. AI
and guava-mcp expose this via the discoverable read capability
`scene.describe_components`, with an optional `type_id` filter. Editor sessions
install a provider for the current scene registry, including module registrations.
This query creates no write drafts. Write capabilities retain their existing
contracts and authorization.

WASM plugin-defined component storage/registration and migration of the remaining
rich component forms to shared field metadata remain separate follow-up work.
The current module registration API is native Swift.
