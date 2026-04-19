# Migration TODO (guava -> mouse-engine)

## Phase 1

- Port application lifecycle and frame scheduler.
- Port scene/world/entity orchestration.
- Keep editor RPC protocol compatible.

## Phase 2

- Integrate mouse-rhi runtime path for rendering submission.
- Port asset registry orchestration and project loading.
- Port script host lifecycle manager.

## Phase 3

- Move platform-specific native features behind C ABI.
- Keep C/C++ only in backend white-list folders.
- Add cross-platform CI smoke checks.
