# mouse-engine

Swift-first runtime engine scaffold for migration from guava.

## Goals

- Keep engine orchestration in Swift.
- Keep C ABI minimal for host/editor/plugin interoperability.
- Integrate with mouse-rhi through stable interfaces.

## Package layout

- Sources/MouseEngineCore: app loop, scene, entity orchestration.
- Sources/MouseEngineRPC: editor-facing protocol bridge.
- Sources/CMouseEngine: C ABI entrypoints.

## Next steps

1. Add project loading and scene serialization.
2. Bridge renderer submission to mouse-rhi runtime.
3. Add RPC schema compatibility tests.
