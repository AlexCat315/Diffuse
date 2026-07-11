---
path: /zh/docs/editor-workflow
title: 编辑器工作流
description: Guava Editor 的项目入口、核心面板、场景编辑和播放状态。
locale: zh
translationKey: docs.editor-workflow
category: 开始
order: 30
kind: doc
---

# 编辑器工作流

编辑器由 GuavaUI 构建，并通过 EditorCore 管理选择、面板、场景适配和编辑历史。

## 打开项目

未指定 `--project-dir` 时，编辑器显示欢迎界面并维护最近项目列表。指定目录后会直接进入该项目的编辑工作区。

## 核心面板

- **Hierarchy**：浏览实体层级并切换选择。
- **Inspector**：编辑变换、网格、材质、灯光、物理、音频、脚本和动画组件。
- **Viewport**：显示场景，处理相机与 Gizmo 交互。
- **Asset Browser**：浏览与导入项目资源。
- **Console**：显示编辑器与运行时消息。
- **Render Pipeline / Profiler**：检查离线渲染任务和开发诊断数据。

## 播放状态

播放前，编辑器会保留场景快照；暂停会冻结模拟而不丢弃状态；停止会恢复进入播放前的场景。MCP 的 `set_playback_state` 使用相同的 `playing`、`paused` 和 `stopped` 状态。

## 保存与未保存变更

关闭或切换上下文时，编辑器会通过未保存变更对话框保护当前工作。场景导出与保存由 EditorCore 的项目导出和文档层负责。
