---
path: /en/docs/module-map
title: Module map
description: Current products and responsibilities across Engine, GuavaUI, Editor, and MCP.
locale: en
translationKey: docs.module-map
category: Core concepts
order: 50
kind: doc
---

# Module map

Swift package manifests are the source of truth for module boundaries.

## Engine

- **Foundation and platform**: `SIMDCompat`, `EngineMath`, `EngineCore`, `EngineKernel`, `PlatformShell`
- **Graphics**: `RHIWGPU`, `RenderBackend`, `ImageDecodeBridge`
- **World runtime**: `SceneRuntime`, `ScriptRuntime`, `AudioRuntime`, `AssetPipeline`
- **AI and semantics**: `ObservationBus`, `CapabilityRuntime`, `IntentRuntime`, `PerceptionRuntime`, `AIRuntime`, `ContextMemory`, `SemanticPipeline`
- **Film**: `SequenceRuntime`, `ColorPipeline`, `EXRIO`, `CinematicRenderer`

## GuavaUI

`GuavaUIRuntime` provides nodes, layout, drawing, input, text, and state. `GuavaUICompose` provides declarative views and controls. `GuavaUIWorkspace`, `GuavaUIApp`, and `GuavaUIDevTools` add docking, app assembly, and inspection.

## Editor and MCP

The root package builds `EditorApp` from EditorCore and the app layer. The separate `guava-mcp` package builds `GuavaMCP`, which forwards tool calls to a running editor.
