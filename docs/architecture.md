---
path: /zh/docs/architecture
title: 架构
description: Guava Engine 的统一世界模型、编辑事务和运行时分层。
locale: zh
translationKey: docs.architecture
category: 核心概念
order: 40
kind: doc
---

# 架构

Guava 以统一世界为核心。编辑器、游戏运行时和 AI 不维护相互翻译的场景副本，而是围绕相同实体、组件和变更语义工作。

## 运行时分层

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

## 世界与变更

- **World** 是实体、组件与关系的来源。
- **Signal** 表达自然语言、直接操作、选择变化和用户纠正等输入。
- **Proposal** 表达尚未应用的改变，可在执行前检查前置条件和影响。
- **Edit** 表达已经应用的改变，并进入编辑历史与观察通道。

当前代码已经包含 Intent、Capability、AI Session、ObservationBus 和事务执行基础；完整的长期语义记忆和端到端图生场景仍属于后续建设范围。

## 依赖原则

Editor 位于应用顶层并依赖 Engine 与 GuavaUI。GuavaUI 只通过有限的 RHI 和平台能力接入 Engine，避免把完整 3D 场景实现反向耦合到 UI 组件层。
