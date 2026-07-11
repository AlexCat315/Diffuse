---
path: /zh/docs/module-map
title: 模块地图
description: Engine、GuavaUI、Editor 与 MCP 的主要产品和职责。
locale: zh
translationKey: docs.module-map
category: 核心概念
order: 50
kind: doc
---

# 模块地图

Swift 包清单是模块边界的事实来源。下面只列出当前仓库已经声明的产品。

## Engine

- **基础与平台**：`SIMDCompat`、`EngineMath`、`EngineCore`、`EngineKernel`、`PlatformShell`
- **图形**：`RHIWGPU`、`RenderBackend`、`ImageDecodeBridge`
- **世界运行时**：`SceneRuntime`、`ScriptRuntime`、`AudioRuntime`、`AssetPipeline`
- **AI 与语义**：`ObservationBus`、`CapabilityRuntime`、`IntentRuntime`、`PerceptionRuntime`、`AIRuntime`、`ContextMemory`、`SemanticPipeline`
- **影视**：`SequenceRuntime`、`ColorPipeline`、`EXRIO`、`CinematicRenderer`

## GuavaUI

- `GuavaUIRuntime`：节点、布局、绘制、输入、文本和状态基础。
- `GuavaUICompose`：声明式 View 与组件层。
- `GuavaUIWorkspace`：Dock 和工作区布局。
- `GuavaUIApp`：窗口与 WebGPU surface 装配。
- `GuavaUIDevTools`：运行时检查能力。

## Editor 与 MCP

根包生成 `EditorApp`，内部由 `EditorCore` 和应用层组成。`guava-mcp` 单独生成 `GuavaMCP` 可执行程序，通过本机连接把工具调用转发给正在运行的编辑器。
