---
path: /zh/docs/overview
title: 项目概览
description: Guava Engine 的目标、技术栈和四个主要工程模块。
locale: zh
translationKey: docs.overview
category: 开始
order: 10
kind: doc
---

# 项目概览

Guava 的核心主张是：创作意图、世界状态、运行时执行和 AI 理解不是四套独立系统，而是同一个世界的四种视图。

## 技术基础

| 领域 | 当前实现 |
| --- | --- |
| 主语言 | Swift 6.1+ |
| 图形接口 | WebGPU（wgpu-native） |
| 物理 | Jolt Physics |
| 平台层 | SDL3 与原生平台适配 |
| UI 布局与文本 | Yoga、HarfBuzz、FreeType |
| 构建 | Swift Package Manager、CMake、Python bootstrap |

## 工程组成

- **Engine**：场景、物理、渲染、资产、脚本、音频、AI 与影视运行时。
- **GuavaUI**：声明式 Compose API、布局、文本、主题、输入和 WebGPU UI 渲染。
- **Editor**：桌面编辑器、面板工作区、选择与变换、播放控制和 AI 宿主。
- **guava-mcp**：通过标准输入输出暴露 MCP 工具，并连接本机编辑器的 `9898` 端口。

## 面向谁

首要受众是希望理解并参与引擎建设的独立游戏创作者。当前版本更适合原型、技术验证和贡献开发，还不是面向生产项目的一键式稳定发行版。
