---
path: /en/docs/architecture
title: Architecture
description: Guava Engine's shared world model, edit transactions, and runtime layers.
locale: en
translationKey: docs.architecture
category: Core concepts
order: 40
kind: doc
---

# Architecture

Guava is organized around one world. The editor, game runtime, and AI do not maintain independent scene copies connected by translation layers; they operate on shared entity, component, and edit semantics.

## Runtime layers

```text
EditorApp
├── EditorCore ── Engine
├── EditorCore ── GuavaUI
└── MCPBridge  ── guava-mcp

Engine
├── SceneRuntime / ScriptRuntime / AudioRuntime
├── RHIWGPU / RenderBackend / PlatformShell
├── AssetPipeline / SequenceRuntime / CinematicRenderer
└── IntentRuntime / CapabilityRuntime / AIRuntime / ObservationBus
```

## World changes

- **World** is the source of entities, components, and relationships.
- **Signal** represents language, direct manipulation, selection changes, and corrections.
- **Proposal** represents an unapplied change that can be checked and previewed.
- **Edit** represents an applied change observed by history and runtime systems.

Intent, capability, AI session, observation, and transaction foundations exist today. Long-session semantic memory and the complete scene-from-image loop remain ongoing work.
