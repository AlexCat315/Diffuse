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

## 本地插件能力契约

`.guavaplugin` 包中的 `capabilities.wit` 是插件参数类型的唯一来源。`interface capabilities` 内每个以 `-input` 结尾的 `record` 会生成一个 AI 能力；能力 ID 由宿主组合为 `<plugin-id>.<record-name>`，版本、权限和来源由 `plugin.json` 与宿主确定。

```wit
package example:scene-reader;

interface capabilities {
  enum detail-level { summary, full }

  /// 查找当前场景中的匹配实体。
  record inspect-scene-input {
    /// 可省略的查询文本。
    query: option<string>,
    detail: detail-level,
    tags: list<string>,
  }
}

world plugin {
  import guava:scene/query;
  export discover: func() -> string;
  export prepare: func(capability-id: string, input: string) -> string;
}
```

宿主从上述 record 自动生成严格 JSON Schema，未知字段会被拒绝。支持嵌套 `record`、`enum`、别名、`option`、`list`、布尔、字符串、字符、8/16/32 位整数和浮点数；自由字典、资源句柄、递归类型及 64 位 JSON 整数会在加载时安全失败。

`discover()` 只能返回实现 ID：

```json
{"capability_ids":["example.scene-reader.inspect-scene"]}
```

返回集合必须与 WIT 声明完全一致。组件不能自行提供 Schema、权限、版本或 Schema Hash；调用 `prepare()` 前，PluginHost 会再次验证授权、能力 ID 和输入 Schema。
