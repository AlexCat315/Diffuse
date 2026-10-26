# Physics backend

Natsel is the physics backend on macOS, iOS, Linux, Windows and Android.
`PhysicsBackendKind.preferred` is `.natsel`; select `.none` to disable the backend.
Engine follows Natsel's `main` branch; no sibling checkout or physics C++ artifact
is required. SwiftPM resolves the branch and lockfiles record the actual commit
used by the build. Updating Natsel does not require editing `Package.swift`.
The workspace declares `dependencyUpdates: "branches"`. The SDK checks declared
branch dependencies before local build/run and lets SwiftPM refresh changed
branches in the listed packages. No extra command or manifest edit is required.
CI reuses committed lockfiles; offline checks retain the resolved version.

The editor exposes Natsel and None. Loading a scene with a retired or unknown
backend name selects Natsel and rewrites the backend name when saved. Obsolete
backend tuning is ignored and omitted from new manifests. Shared capacity,
worker, gravity, sleep, collision-step and body settings retain their values.

Switching between None and Natsel rebuilds the native world from current ECS
state. Manual `setPhysicsBackend(...)` overrides take precedence.

## Integration

The adapter owns a persistent Natsel world and maps its opaque handles to entities
and compound child IDs. It supports rigid bodies, CCD, compound edits, material
and layer filters, seven joint configurations, break events, virtual characters,
wheeled/tracked/motorcycle vehicles, and surface/tetrahedral soft bodies. Queries
share the simulation world. AABB overlaps use narrow-phase box geometry, and sweep
positions report the query origin at impact, matching the existing Guava API.

`capacity.maxBodies`, worker selection, gravity, sleep and collision steps apply to
Natsel. Natsel caps workers at 32. Deterministic replay is checked within the same
backend and build, including worker-count determinism in native solver tests.

## Behavior to account for

- Cylinders use a 32-sided convex hull. Height fields use the supplied triangle
  geometry. Sphere/capsule scaling uses a conservative radial scale.
- Natsel's split position solver does not retain every positional reaction in its
  reported joint force. Break-force evaluation also estimates the force from the
  corrected anchor error.
- Rigid velocity limits are applied to submitted velocities and ECS writebacks.
  Natsel exposes a world-wide linear integration limit, so bodies with different
  limits can temporarily exceed their own limit during a contact/force solve.
- Soft bodies collide through Natsel's deformable solver. Character support and
  scene queries use lazily rebuilt triangle surfaces that are excluded from the
  physical solver. Character support does not apply pressure to this query mesh.
  Rebuilding surfaces has a cost when querying a deforming mesh every frame.
- Disconnected soft mesh pieces get separated rest-space exclusion neighborhoods
  while retaining their authored initial positions. Restoring those positions uses
  Natsel's per-vertex setter; initialization can be expensive for large meshes
  with many disconnected pieces.
- General mesh-versus-mesh trigger detection is not supported by the proxy query
  path. Use a convex trigger volume for mesh terrain or deformable surfaces.

## Validation and benchmarks

Run through the repository CLI:

```sh
guava test Engine --filter SceneRuntimeTests
guava test Engine
guava build Editor --debug
guava internal build-package Engine --product PhysicsRuntimeBenchmarks --release
```

The physics benchmark defaults to Natsel. For example, after the
release build on macOS:

```sh
GUAVA_PHYSICS_BACKEND=natsel GUAVA_PHYSICS_SCENARIO=active-grid \
  GUAVA_PHYSICS_BODIES=10000 GUAVA_PHYSICS_WORKERS=1 \
  Engine/.build/out/Products/Release/PhysicsRuntimeBenchmarks
```

Keep frame counts, worker counts and build configuration equal for comparisons.
The benchmark defaults to a 120 FPS target: 8.33 ms for the CPU tick and a separate
1 ms physics CPU budget. `GUAVA_PHYSICS_TARGET_FPS` changes the target; the default
physics allocation is 12% of the frame and can be set with `GUAVA_PHYSICS_BUDGET_MS`.
Both P95 and P99 are checked, with at least 100 measured frames required.

`physics_cpu_ms` includes complete preparation, step, writeback, spatial-index and
trigger phases. `step_ms` reports the backend call separately. `cpu_tick_ms` includes
the entire SceneRuntime schedule. Each phase also reports its own percentiles.
This harness does not perform GPU drawing or run a representative game's full
logic load, and always prints `full_rendered_frame_verified=false`.

Measured timings and gate results are recorded in [PhysicsBenchmarkResults.md](PhysicsBenchmarkResults.md).
