# Natsel migration performance

Measured on 2026-10-26 on Apple M1, macOS arm64, Swift 6.4.1, Release.
Both backends use 1 or 7 physics workers, 60 warm-up frames and 180 measured frames.
The runs execute serially after compilation and tests finish. These are local
measurements, with fewer sample frames than the benchmark's default 600.

Validation used SDK 0.1.7 at GuavaUI commit `b1ac164`, matching
`Editor/guava.json`, and Natsel revision
`87a0f0d49f7211e84bd79bb0cb7bbfdff4697361`. Set `GUAVA_SDK_ROOT` to a matching
SDK checkout to repeat the build when the selected local SDK has a different version.

## What was fixed

A one-second sample of the original 10,000-body run placed 416 of 483 main-thread
samples in component dictionary copying while clearing physics accumulators.
`ComponentStores.update` retained its store box while asking for unique mutable
access, forcing a full dictionary copy on each update. It now reads the component
value before acquiring the mutable box. Regression coverage checks that copied
worlds and captured component snapshots retain their independent values.

Full-world read views reuse component dictionaries as copy-on-write snapshots.
Typed queries start with their component store (the smallest store for joined
queries), preserving entity order without scanning unrelated entities.

Synchronization compares body descriptors once, reuses the resulting maps as
the next cache, and refreshes cached descriptors in place after writeback.
Worlds without parent/child components propagate independent roots directly,
without building graph snapshots, frontier maps or visited sets. A regression
test covers captured snapshots and switching from independent roots to a hierarchy.

Natsel writebacks update each cached body record once, and trigger detection sorts
the trigger entities. Active-body statistics read the resulting ECS sleep state,
so partial or skipped writebacks do not report awake bodies as inactive.

The benchmark includes complete `SceneRuntime.tick` percentiles (`cpu_tick_ms`),
complete physics CPU phase timings (`physics_cpu_ms`), per-phase percentiles,
and backend-step, synchronization and vertex-stream timings.

## Reproduction

Build with the repository CLI:

```sh
./guava internal build-package Engine --product PhysicsRuntimeBenchmarks --release
```

Run each combination of `natsel`/`jolt` and the following scenarios:

| Scenario | `GUAVA_PHYSICS_BODIES` | Geometry |
| --- | ---: | --- |
| `active-grid` | 10000 | Moving boxes without contacts |
| `dense-contact` | 2000 | Stacked boxes with contacts |
| `cloth-64` | 1 | 4096 cloth vertices, five solver iterations, self collision enabled |

For example:

```sh
GUAVA_PHYSICS_BACKEND=natsel GUAVA_PHYSICS_SCENARIO=active-grid \
  GUAVA_PHYSICS_BODIES=10000 GUAVA_PHYSICS_WORKERS=1 \
  GUAVA_PHYSICS_WARMUP_FRAMES=60 GUAVA_PHYSICS_SAMPLE_FRAMES=180 \
  Engine/.build/out/Products/Release/PhysicsRuntimeBenchmarks
```

## Acceptance budgets

The earlier 16.67 ms backend-step gate was insufficient to establish engine FPS.
It has been replaced by separate CPU tick and physics CPU budgets, checked at both
P95 and P99 for every scenario. At least 100 measured frames are required.

| Target FPS | CPU tick ceiling | Default physics CPU budget |
| ---: | ---: | ---: |
| 60 | 16.67 ms | 2 ms |
| 120 (default) | 8.33 ms | 1 ms |
| 144 | 6.94 ms | 0.833 ms |
| 240 | 4.17 ms | 0.5 ms |

Use `GUAVA_PHYSICS_TARGET_FPS` to choose the target. The physics budget reserves
12% of that frame and can be explicitly set with `GUAVA_PHYSICS_BUDGET_MS`.
It includes preparation, stepping, writeback, spatial-index maintenance and trigger
detection. Vertex streaming defaults to 10% of the physics budget. Destruction
activation defaults to the CPU tick ceiling. Dropped steps and backend errors fail
acceptance; the RSS growth limit remains 32 MiB.

The harness measures one 60 Hz physics step per CPU tick. GPU drawing and a full
game logic workload are outside its scope. Passing these CPU checks cannot verify
complete rendered-frame FPS; the output explicitly records that limitation.

## Initial baseline before native self-contact optimization

These historical measurements use the same single-worker, 60/180-frame settings.
They use Natsel `45e4dfb`, before the native and latest ECS snapshot changes, and
fail the current 120 FPS acceptance budgets, including the Jolt comparison.

| Scenario | Natsel step P95 | Jolt step P95 | Natsel CPU tick P95 | Jolt CPU tick P95 |
| --- | ---: | ---: | ---: | ---: |
| 10000 active boxes | 12.791 ms | 7.538 ms | 67.313 ms | 67.177 ms |
| 2000 contacting boxes | 29.944 ms | 26.599 ms | 43.097 ms | 39.744 ms |
| 64x64 self-colliding cloth | 39.812 ms | 5.735 ms | 40.062 ms | 5.965 ms |

The native cloth profile identified self-contact candidate detection and cell
sorting as the main cost. The Natsel optimization branch replaces repeated face
and edge cell entries with refittable feature BVHs, reuses rest-neighborhood
exclusions, and partitions large single-body detection with ordered result merging.

## Native self-contact results

The isolated Natsel `cloth_self64` harness uses the same authored cloth vertex
order and material settings. It runs 60 warm-up steps and 180 measured steps.
The old single-worker baseline has one run; each optimized worker configuration
has three runs. These timings exclude GuavaStudio and use four rigid substeps;
the integration benchmark uses one, so they are a separate measurement.

| Natsel version / workers | Step P95 |
| --- | ---: |
| Before / 1 | 39.302 ms |
| Optimized / 1 | 15.178 ms |
| Optimized / 4 | 8.476 ms |
| Optimized / 7 | 6.321 ms |

Optimized values are the median of the three run-level P95 values. Every run
produced the same final vertex checksum `772246b7f26de325`, including the old
baseline. The old C-compatible world hash does not include soft-only positions;
the new harness prints a separate cloth checksum. Full Natsel validation passes
518 tests, including exact single-cloth vertex comparisons with 1/2/4/8 workers.
GuavaStudio's complete Engine test run passes, including 344 SceneRuntime tests;
the Editor macOS Debug application also builds with the pinned dependency.

## Integrated results after shared runtime optimization

One run per combination, after all builds and functional tests finished. Columns
with two numbers show P95 / P99 in milliseconds. Phase percentiles are measured
individually; their P95 values must not be summed to reconstruct another P95.

| Scenario | Workers | Backend | CPU tick P95 / P99 | Physics CPU P95 / P99 | Backend step P95 | 120 FPS gate |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| active-grid | 1 | natsel | 42.955 / 44.497 | 41.339 / 42.951 | 12.717 | Failed |
| active-grid | 1 | jolt | 37.045 / 39.000 | 35.593 / 37.516 | 6.991 | Failed |
| dense-contact | 1 | natsel | 35.807 / 36.398 | 35.368 / 35.970 | 27.866 | Failed |
| dense-contact | 1 | jolt | 31.828 / 32.103 | 31.356 / 31.668 | 24.569 | Failed |
| cloth-64 | 1 | natsel | 16.253 / 17.246 | 16.115 / 17.113 | 16.008 | Failed |
| cloth-64 | 1 | jolt | 5.844 / 5.939 | 5.721 / 5.821 | 5.643 | Failed |
| active-grid | 7 | natsel | 40.071 / 41.295 | 38.408 / 39.713 | 10.736 | Failed |
| active-grid | 7 | jolt | 37.431 / 41.261 | 36.015 / 39.802 | 7.038 | Failed |
| dense-contact | 7 | natsel | 32.943 / 33.831 | 32.435 / 33.373 | 25.010 | Failed |
| dense-contact | 7 | jolt | 34.555 / 35.835 | 34.069 / 35.354 | 27.047 | Failed |
| cloth-64 | 7 | natsel | 6.846 / 7.391 | 6.723 / 7.257 | 6.631 | Failed |
| cloth-64 | 7 | jolt | 5.761 / 5.797 | 5.644 / 5.673 | 5.561 | Failed |

All twelve runs report zero dropped steps and no backend errors. RSS growth stays
below 32 MiB, and the 4096-vertex stream has P95 0.005 ms for both Natsel worker
configurations. The integrated Natsel cloth vertex-stream checksum is `6.618588`
with both 1 and 7 workers; this lightweight sum is distinct from the exact native
vertex checksum used for determinism tests.

Every run fails the 1 ms complete physics envelope. Single-worker active boxes
and contacting boxes also exceed the 8.33 ms CPU tick ceiling for both backends;
Natsel's single-worker cloth exceeds it as well. Seven-worker cloth fits this
CPU tick ceiling, but its physics cost still leaves too little of the reserved
game/rendering budget. These results do not establish complete 120 FPS rendering.

For 10000 active boxes, the initial single-worker Natsel CPU tick P95 was
67.313 ms; it is now 42.955 ms, about 36% lower. The latest shared-pipeline batch
alone reduced it from 55.632 ms to 42.955 ms, about 23% lower. Jolt benefits from
the same runtime changes: its corresponding final CPU tick P95 is 37.045 ms.

The latest Natsel batch isolates where that reduction came from:

| 10000 active boxes, 1 worker | Before latest shared batch P95 | Final P95 |
| --- | ---: | ---: |
| Preparation phase | 13.842 ms | 8.208 ms |
| Writeback phase | 21.974 ms | 14.885 ms |
| Backend step | 12.883 ms | 12.717 ms |

Preparation, writeback, the 5.558 ms P95 spatial-index phase, and Natsel's contact
solver remain substantial costs. The next work needs to reduce descriptor/state
copying and repeated whole-world synchronization, accelerate spatial updates,
and continue native contact detection/solve optimization. Raising the acceptance
budgets would not resolve these costs.
