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

  inspect-scene: func(input: inspect-scene-input) -> string;
}

world plugin {
  import guava:scene/query;
  export capabilities;
}
```

宿主从上述 record 自动生成严格 JSON Schema，未知字段会被拒绝。每个 `<name>-input` 必须对应同名 `name: func(input: ...) -> string`，标准 Component 导出包限定的 `example:scene-reader/capabilities` 接口；缺少函数、额外函数或参数类型漂移都会拒绝加载。支持嵌套 `record`、`enum`、别名、`option`、`list`、布尔、字符串、字符、8/16/32 位整数和浮点数；空 record、自由字典、资源句柄、递归类型及 64 位 JSON 整数会在加载时安全失败。

能力清单完全由已验证的 WIT 派生，不再调用插件提供的 `discover()`。调用时，PluginHost 先执行严格 Schema 校验，再把 JSON 编码成对应的 Component 类型值并调用同名函数；组件不能自行提供 Schema、权限、版本、能力 ID 或 Schema Hash。写入插件返回的仍只能是已授权 `HostCapabilityCall` 列表，不能返回原始 mutation。

编辑器启用插件时，会把组件 Hash、WIT Hash、导入权限、可组合宿主能力和全部 Schema Hash 生成一个授权指纹，并与当前 PluginHost `generation` 一起写入 `ExposureSnapshot`、写入 Draft 和 `CapabilityInvocationRecord`。插件升级、禁用、重新授权或 PluginHost 重启会清空旧会话；即使确认窗口已经打开，事务应用前也会再次验证这组绑定。

插件读取能力通过 `PluginCapabilityExecutor.executeRead` 校验后立即执行，结果只能作为有界 JSON 上下文返回。插件写入能力在 `submit_plan` 时展开成已授权的内建 primitive，按 Draft 顺序在同一个 Shadow Scene 中 prepare；整体事务同时记录外层插件调用与每个内建调用，并统一进入 Diff、确认、执行后断言和回滚流程。空写入计划、读取 primitive、未暴露或开放 Schema 的 primitive 都会安全失败。

编辑器设置中的“AI 插件”入口实现固定顺序：选择 `.guavaplugin` 目录 → `EditorApplication.inspectPlugin` 只检查但不加载 → UI 展示访问等级、导入权限、可组合宿主能力、Component/WIT Hash 与每个 Schema Hash → 用户点击“授权并启用” → `makePluginAuthorization` → `enablePlugin`。待批准包路径只保存在 `EditorApplication` 私有内存中，插件管理 UI 状态不会写入 `EditorState` 编码结果。成功启用后，项目级 `plugin_authorizations.json` 只记录精确授权指纹；该文件不会自动加载或启用插件，代码、WIT、权限或 Schema 任一变化都会使记录不可复用。`enablePlugin` 会原子重建 Editor AI 与 MCP 共用的 Registry、Exposure policy 和 authority 映射，清空旧会话/Draft，并用插件感知的 planner 替换执行前权限检查。`Session` 提交插件写入时只把 authority-bound Draft 放入 `Proposal`；Editor 拿到实时 `SceneRuntime` 后才展开并生成事务。插件的场景、选择集和资源查询只来自 Editor 创建的 revision-bound `PluginQuerySnapshot`，不会把运行时对象或绝对资源路径交给插件。

禁用插件或 PluginHost 重启时，Editor 会立即撤销动态暴露、取消活动 AI Run 并清理 MCP 会话。已打开的确认请求即使仍在 UI 中，也会在应用前因 planner 的 generation/authorization 二次校验失败。PluginHost 可执行文件不再是插件管理 API 的参数：Editor 只从安装包 `Contents/Helpers`、发布归档 `Tools`、编辑器同目录或 Debug 构建产物中解析常规可执行文件，并拒绝不可执行文件、目录与符号链接；发布流水线固定构建并打包该宿主。插件包、项目设置、环境变量和模型输入都不能指定 PluginHost 路径。
