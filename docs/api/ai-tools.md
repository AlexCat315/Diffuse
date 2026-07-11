---
path: /zh/docs/mcp-tools
title: MCP 与 AI 工具
description: Guava MCP 服务的连接方式和当前工具集合。
locale: zh
translationKey: docs.mcp-tools
category: 参考
order: 70
kind: doc
---

# MCP 与 AI 工具

`guava-mcp` 是一个 MCP stdio 服务。它把工具请求转发到本机 `127.0.0.1:9898` 上运行的 Guava Editor，因此调用工具前必须先启动编辑器。

## 启动

```bash
swift run --package-path guava-mcp GuavaMCP
```

## 当前工具

| 工具 | 用途 |
| --- | --- |
| `get_scene_entities` | 返回实体、ID、组件和主要属性 |
| `find_entities` | 按条件查找实体 |
| `get_selection` / `select_entity` | 读取或更新编辑器选择 |
| `get_ai_entity` | 读取 AI 可见的实体语义记录 |
| `execute_edit_plan` | 执行结构化场景编辑步骤 |
| `set_playback_state` | 控制播放、暂停与停止 |
| `undo` / `redo` | 操作编辑历史 |
| `analyze_image` | 分析参考图像 |
| `get_context_memory` | 读取上下文记忆 |

## 安全边界

工具使用 `scene:<number>` 形式的实体引用。变更前应先读取当前场景，基于真实 ID 构造计划；涉及多步修改时优先使用 `execute_edit_plan`，让编辑器统一验证并执行。
