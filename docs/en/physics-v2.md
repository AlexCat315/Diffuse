---
path: /en/docs/physics-v2
title: Physics v2
description: Guava's Jolt frame stages, vehicles, soft bodies, pre-fractured destruction, and current boundaries.
locale: en
translationKey: docs.physics-v2
category: Core Concepts
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 uses Jolt as its only production physics backend. Compound colliders, unified queries and events, native characters, typed joints, ragdolls, incremental synchronization, deterministic command replay, the three M5 vehicle controllers, M6 regular cloth plus arbitrary triangle-surface soft bodies, and M7 pre-fractured destruction are implemented.

## Frame stages

Each frame runs in this order:

1. Input and script `onPrePhysics` submit character, vehicle, rigid-body, and destruction commands.
2. Incremental ECS changes synchronize into Jolt.
3. Fixed physics steps run.
4. Changed active bodies write back to ECS; characters, vehicles, and soft-body vertices write dedicated frame resources.
5. Script `onUpdate` reads the current-frame results.

Commands submitted from `onPrePhysics` are therefore consumed by the current physics frame.

## Vehicles

A `Vehicle` must share an entity with a dynamic `RigidBody` and a `Collider`. Its default configuration creates four wheels with front steering, rear drive, and a rear hand brake.

```swift
let car = scene.createEntity()
_ = scene.setLocalTransform(
    LocalTransform(translation: SIMD3<Float>(0, 1.2, 0)),
    for: car
)
_ = scene.setComponent(
    Collider(shape: .box(
        halfExtents: SIMD3<Float>(1, 0.35, 1.8),
        center: .zero
    )),
    for: car
)
_ = scene.setComponent(
    RigidBody(motionType: .dynamic, mass: 1_200),
    for: car
)
_ = scene.setComponent(Vehicle(), for: car)

scene.submitVehicleCommand(
    VehicleCommand(throttle: 1, steering: 0.25),
    for: car
)
_ = scene.tick(deltaTime: 1.0 / 60.0)

let state = scene.vehicleStateFrame.states[car]
```

`Vehicle` supports a variable wheel count, suspension, steering, brakes, hand brakes, engines, automatic or manual transmissions, differentials, and anti-roll bars. `VehicleStateFrameResource` exposes speed, engine RPM, current gear, clutch friction, and per-wheel transforms, suspension, and contact data.

All three controller types share `VehicleCommand` and `VehicleStateFrameResource`:

```swift
let car = Vehicle()
let tank = Vehicle.tracked()
let bike = Vehicle.motorcycle()
```

The tracked controller maps `steering` to left/right track ratios and performs a pivot turn for steering input at rest. The motorcycle controller exposes maximum lean, balance spring, damping, integration decay, smoothing, and lean steering-limit settings.

## Cloth and soft-body state streaming

A soft-body entity combines `SoftBody` with one topology component. `Cloth` defines a regular grid, spacing, fixed vertices, stretch/shear/bend compliance, and bend-constraint type. `SoftBodyMesh` references an arbitrary triangle-surface asset in `MeshColliderGeometryResource` and defines its fixed vertices and constraint compliance. A resource may additionally provide `tetrahedronIndices` in groups of four; the backend then adds missing internal tetrahedral edges and Jolt volume constraints, whose compliance is controlled by `volumeCompliance`. The two topology components are mutually exclusive. `SoftBody` defines the shared mass, pressure, damping, friction, restitution, gravity scale, vertex radius, solver iterations, and collision layers. When `selfCollision` is enabled, `vertexRadius` is also the intra-body vertex-versus-triangle contact thickness and must be greater than zero.

```swift
let banner = scene.createEntity()
_ = scene.setLocalTransform(
    LocalTransform(translation: SIMD3<Float>(0, 4, 0)),
    for: banner
)
_ = scene.setComponent(
    Cloth.fixedTopEdge(gridSizeX: 16, gridSizeZ: 16, spacing: 0.15),
    for: banner
)
_ = scene.setComponent(SoftBody(allowSleep: false), for: banner)

_ = scene.tick(deltaTime: 1.0 / 60.0)
let deformedMesh = scene.softBodyStateFrame.states[banner]
```

An imported mesh can directly reuse vertex, triangle, and UV data cached by resource ID and revision:

```swift
let softProp = scene.createEntity()
scene.setResource(MeshColliderGeometryResource(geometryByResourceID: [
    "asset:soft-tetra": MeshColliderGeometry(
        positions: tetraVertices,
        triangleIndices: surfaceTriangles,
        tetrahedronIndices: volumeTetrahedra,
        revision: 1
    )
]))
_ = scene.setComponent(
    SoftBodyMesh(
        resourceID: "asset:soft-tetra",
        fixedVertexIndices: [0, 3],
        volumeCompliance: 1.0e-6,
        bendType: .distance
    ),
    for: softProp
)
_ = scene.setComponent(SoftBody(allowSleep: false), for: softProp)
```

An unresolved `SoftBodyMesh.resourceID`, an out-of-range topology index, a degenerate triangle, a zero-volume or repeated-vertex tetrahedron, or an entity carrying both `Cloth` and `SoftBodyMesh` reports an explicit `invalidArgument`; no substitute shape is created. Tetrahedron indices must be generated by the import pipeline in advance; an ordinary surface mesh is not tetrahedralized at runtime.

Deformed world-space vertices and triangle indices stream through `SoftBodyStateFrameResource`; ordinary ECS `Transform` components are not used for per-vertex writeback. A cloth with a visible `RenderMeshComponent` is also extracted as a `RenderDeformableMesh`. The render backend owns entity-keyed dynamic GPU vertex and index buffers: an unchanged content revision causes no upload, while unchanged topology permits a vertex-only update. Depth, shadow, base, outline, and render-bundle paths all resolve the same deformable mesh, and shadow bounds use its current world-space vertices. Creation, incremental rebuild, removal, state copying, and render extraction use stable `EntityID` ordering.

`RenderFrameStats` independently reports deformable mesh, vertex, triangle, rejected-mesh, uploaded-byte, and upload-time metrics; the Editor Render debugger exposes them directly. A render frame with no fixed physics substep keeps the latest soft-body state and GPU buffers instead of dropping the cloth for one frame.

Jolt 5.5 does not expose an intra-soft-body collision solver switch, so Guava's bridge generates non-adjacent vertex-versus-triangle candidates with a spatial hash after each fixed step and applies mass-weighted separating-velocity constraints. Faces containing the vertex or sharing a topology edge with it are excluded. Entity, vertex, face, and candidate processing all use stable order, and the bridge only changes vertex velocity—the externally controllable field documented by Jolt—rather than mutating internal positions or bounds.

Selecting a soft-body entity in the Editor overlays its constraint topology in the viewport: cyan lines are surface edges, purple lines participate in tetrahedral volume constraints, and yellow anchors are fixed vertices. The overlay follows the latest simulated vertices during play and uses the authored rest pose while stopped. Edges are stably ordered by vertex index and bounded to 4,096 lines per entity.

## Pre-fractured destruction

The first M7 release uses offline pre-fractured assets. `DestructibleAssetBaker` accepts closed convex fragment meshes, density, and local transforms. It sorts by fragment ID, generates stable `asset#convex:<fragmentID>` geometry resource IDs, and computes mass from closed-mesh volume times density. When explicit edges are absent, the importer filters candidates with transformed AABBs and then generates a stable graph from vertex-to-triangle surface distance under a configurable tolerance. Explicit edges take precedence, and automatic generation can be disabled. Duplicate IDs, invalid connections or tolerance, non-finite vertices, out-of-range indices, and zero-volume geometry fail explicitly; no fallback box is generated. A bake result installs the geometry and destructible asset resources together.

An authored entity references the asset through `Destructible` and configures accumulated-damage and contact-impulse thresholds, a per-source fragment budget, maximum lifetime, sleeping recycle delay, and separation impulse. Scripts submit `DestructionCommand` from `onPrePhysics`; direct commands fracture before body synchronization, so new fragments participate in the current fixed step. The unified Jolt contact listener estimates a nonzero solver impulse from pre-solve velocities and contact settings. Contact-triggered fracture is generated after that fixed step and synchronizes into Jolt on the next one.

Connection edges can override damage or impulse thresholds; zero inherits the source threshold. A non-forced command with `worldPoint` treats the world-space midpoint between its endpoint fragment origins as the edge anchor and breaks only the nearest eligible edge. An incremental break that does not yet separate the graph emits a `connectionBreak` event with empty fragment arrays. A command without a hit point represents global or area damage and breaks every eligible edge. Distance ties use connection ID, and accumulated damage saturates at a finite value. Runtime processing uses stable EntityID, command-index, fragment-ID, and connection-ID order. Reaching a source threshold, forcing fracture, or disconnecting the graph from its root activates the complete pre-fractured asset. This release does not activate individual connected islands or perform arbitrary runtime Boolean cutting.

Global `DestructionSettingsResource` limits active fragments and per-frame events. Fragment budgets truncate by lowest fragment ID and report the dropped count. Fragments recycle by lifetime, continuous sleeping duration, or source removal. `DestructionEventFrameResource` reports fracture, failure, recycle, and overflow; `DestructionStateFrameResource` exposes accumulated damage, broken connections, and active fragments. Scene v2 and Prefab v2 use asset semantics: runtime fragment entities are filtered and the source body, collider, and visible mesh are restored from the pre-fracture snapshot; runtime fragments cannot be Prefab roots. GameSave v2 uses live-snapshot semantics: it preserves accumulated damage, broken edges, relocatable fragment ownership, rigid-body velocities, pending forces and impulses, sleeping state, and remaining lifetime and sleeping-recycle budgets. The source `Destructible` policy also round-trips through Editor Manifest v5.

The unified `PhysicsDebugFrameResource` emits destruction-edge world endpoints, broken state, and source-fractured state in source-EntityID and connection-ID order. Selecting a `Destructible` in the Editor consumes that frame directly: intact edges and midpoint anchors are green, broken ones are red, and each entity is bounded to 4,096 displayed connections. The Inspector edits the full policy and displays asset fragment/connection counts plus current active/broken state. AI scene semantics expose the asset ID, thresholds, budget, and runtime summary. The `destruction-fragments` benchmark deterministically activates a requested count of simple convex pieces and gates activation latency, fixed-step percentiles, memory growth, active count, and dropped substeps separately.

## Stability and serialization

- Vehicle creation, removal, commands, and state use stable `EntityID` ordering.
- Engine, gear, clutch, and per-wheel state participate in physics checkpoint hashes.
- Accumulated destruction damage, broken connections, and active-fragment ownership participate in checkpoint hashes; destruction commands are recorded and replayed.
- Destruction fragments, connections, budget truncation, and events are normalized by fragment ID and connection ID even if callers reorder the mutable runtime resource arrays.
- Vehicle configuration round-trips through Scene v2 and Editor Manifest v5.
- C ABI v6 validates rigid-body, character, vehicle, and soft-body structure sizes and explicitly reports invalid grid, arbitrary-surface, or tetrahedral topology.
- AI scene semantics include vehicle, soft-body, cloth, surface-mesh, and pre-fractured-asset configuration plus available latest-state summaries.
- The `cloth-64`, `soft-body-instances`, and `destruction-fragments` benchmarks independently gate one self-colliding 64×64 cloth, eight 32×32 instances, and bulk pre-fractured activation.

## Current boundary

M5, M6, and M7 are complete. M7's production boundary is offline pre-fracture: import supplies closed convex fragments and a connection graph; runtime owns localized/global damage and impulse thresholds, incremental edge breaking, deterministic activation, budgets, recycling, events, command replay, Editor support, and AI semantics. A disconnected graph still activates the complete asset; connected islands are not released incrementally, and arbitrary runtime Boolean cutting is out of scope.
