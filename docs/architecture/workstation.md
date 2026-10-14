---
path: /zh/docs/architecture/workstation
title: 'GuavaStudio 工作站边界'
description: 'GuavaStudio 工作站边界 — GuavaStudio documentation'
locale: zh
translationKey: architecture/workstation
category: architecture
order: 100
kind: doc
---

# GuavaStudio 工作站边界

GuavaStudio 是产品；`Engine/` 是场景、物理、渲染、脚本和 AI 等可复用运行库的实现目录。根 SwiftPM 工作区名为 GuavaStudioWorkspace，启动产品为 `GuavaStudio`。Editor 的包名为 GuavaStudioEditor，运行库包名为 GuavaStudioRuntime；资源 bundle、安装校验、发行包和官网使用对应的新标识。

## 生产领域

Editor 的生产领域与 Agent/manual 交互模式独立。默认交互为 Agent Workbench，用户仍能进入手动面板。工作流由 EditorWorkspaceProfile 定义面板与授权工具范围：

| 工作流 | 文档/操作 | 主要入口 |
| --- | --- | --- |
| Text and Code | 项目中的普通 UTF-8 文件，不隐式编译或执行 | DocumentsPanel、list/read/write_file |
| Video Editing | 视频源、顺序 cuts、裁剪、排序、预览/播放与 MP4 导出 | MediaTimelinePanel、媒体项目工具 |
| Game Development | 场景、游戏脚本、模拟和游戏构建 | 原有场景/脚本能力 |
| 3D Creation / Animation | 模型、渲染与动画组件 | 原有创作面板和能力 |

`EditorWorkstation` 组合三个服务：scripts、documents、media。普通文档的路径、UTF-8 和磁盘冲突规则由独立 `Editor/Documents` 包管理；UI 模型只是边界适配器。媒体解码/剪辑来自独立 `Engine/Media` 包。已有 EditorApplication 不再新增并行脚本/文档字段。

Agent 与 MCP 共用 executeProjectTool，不把文件操作伪装为 scene mutation。文本工作流不暴露场景变更能力；媒体工作流提供读取时间线、添加/裁剪/移除 cuts、保存和导出。现有文件写入要求 read_file 返回的完整 expected_text，并拒绝覆盖未保存缓冲区或磁盘外部变更。

## 文档与会话

原始文本文件是持久内容。视频剪辑保存到 `.guava/media.json`，解码器、图像、设备和播放/导出任务是 session 状态。关闭项目和退出窗口会检查并保存所有三类文档，切换领域不丢弃缓冲区。文件和媒体服务只接受工程范围内的路径。媒体导出生成新的 Exports 文件，不覆盖原始素材。

当前视频工作流是可执行的顺序剪辑基础；多轨编辑、转场、媒体代理、通用语言 LSP 和跨设备完整工作站 UI 属于后续扩展。平台 SDK 的 iOS 应用宿主与桌面工作站的全部功能是两个独立支持范围。
