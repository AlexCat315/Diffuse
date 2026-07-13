---
path: /en/docs/physics-v2
title: Physics v2
description: Guava's Jolt frame stages, vehicle API, state resources, and current boundaries.
locale: en
translationKey: docs.physics-v2
category: Core Concepts
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 uses Jolt as its only production physics backend. Compound colliders, unified queries and events, native characters, typed joints, ragdolls, incremental synchronization, deterministic command replay, and the first M5 wheeled-vehicle slice are implemented.

## Frame stages

Each frame runs in this order:

1. Input and script `onPrePhysics` submit character, vehicle, and rigid-body commands.
2. Incremental ECS changes synchronize into Jolt.
3. Fixed physics steps run.
4. Changed active bodies write back to ECS; characters and vehicles write dedicated frame resources.
5. Script `onUpdate` reads the current-frame results.

Commands submitted from `onPrePhysics` are therefore consumed by the current physics frame.

## Wheeled vehicles

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

## Stability and serialization

- Vehicle creation, removal, commands, and state use stable `EntityID` ordering.
- Engine, gear, clutch, and per-wheel state participate in physics checkpoint hashes.
- Vehicle configuration round-trips through Scene v2 and Editor Manifest v5.
- The C ABI validates every vehicle structure through a dedicated layout table and reports invalid wheel data or indices explicitly.
- AI scene semantics include authored vehicle configuration and a latest-state summary.

## Current boundary

M5 remains in progress. This slice provides the Jolt `VehicleConstraint` wheeled-vehicle path. Tracked and two-wheel controllers, ramp/jump/friction/recovery/moving-platform acceptance scenes, and complete per-wheel Editor array tooling remain future work.
