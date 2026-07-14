---
path: /en/docs/physics-v2
title: Physics v2
description: Guava's Jolt frame stages, vehicles, cloth state resources, and current boundaries.
locale: en
translationKey: docs.physics-v2
category: Core Concepts
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 uses Jolt as its only production physics backend. Compound colliders, unified queries and events, native characters, typed joints, ragdolls, incremental synchronization, deterministic command replay, the three M5 vehicle controllers, and the first native-cloth M6 slice are implemented.

## Frame stages

Each frame runs in this order:

1. Input and script `onPrePhysics` submit character, vehicle, and rigid-body commands.
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

The first M6 slice combines `SoftBody` and `Cloth` on one entity. `Cloth` defines a regular grid, spacing, fixed vertices, stretch/shear/bend compliance, and bend-constraint type. `SoftBody` defines mass, pressure, damping, friction, restitution, gravity scale, vertex radius, solver iterations, and collision layers.

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

Deformed world-space vertices and triangle indices stream through `SoftBodyStateFrameResource`; ordinary ECS `Transform` components are not used for per-vertex writeback. A cloth with a visible `RenderMeshComponent` is also extracted as a `RenderDeformableMesh`. The render backend owns entity-keyed dynamic GPU vertex and index buffers: an unchanged content revision causes no upload, while unchanged topology permits a vertex-only update. Depth, shadow, base, outline, and render-bundle paths all resolve the same deformable mesh, and shadow bounds use its current world-space vertices. Creation, incremental rebuild, removal, state copying, and render extraction use stable `EntityID` ordering.

`RenderFrameStats` independently reports deformable mesh, vertex, triangle, rejected-mesh, uploaded-byte, and upload-time metrics; the Editor Render debugger exposes them directly. A render frame with no fixed physics substep keeps the latest soft-body state and GPU buffers instead of dropping the cloth for one frame. The current Jolt API does not expose soft-body self-collision, so `selfCollision: true` reports an explicit `invalidArgument` instead of silently reducing capability.

## Stability and serialization

- Vehicle creation, removal, commands, and state use stable `EntityID` ordering.
- Engine, gear, clutch, and per-wheel state participate in physics checkpoint hashes.
- Vehicle configuration round-trips through Scene v2 and Editor Manifest v5.
- C ABI v4 validates rigid-body, character, vehicle, and soft-body structure sizes and explicitly reports invalid configuration.
- AI scene semantics include vehicle, soft-body, and cloth configuration plus available latest-state summaries.
- The `cloth-64` and `soft-body-instances` benchmarks independently report step and vertex-stream p50/p95/p99, memory, and dropped substeps for one 64×64 cloth and eight 32×32 instances, with separate budget gates.

## Current boundary

M5 is complete. M6 currently includes native Jolt regular-grid cloth, fixed points, pressure/damping settings, incremental synchronization, Scene v2 and Manifest v5 round-tripping, a dedicated deformed-vertex stream, revision-cached GPU mesh uploads, integration across every mesh render path and shadow bounds, static/dynamic-body/character collision acceptance, Editor parameter/fixed-point editing and upload profiling, and 64×64 plus multi-instance performance gates. Arbitrary mesh/volumetric soft-body assets, self-collision, and Editor constraint visualization remain for later slices.
