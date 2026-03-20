# Guava Engine

Guava Engine 是一个使用 Zig 开发的游戏引擎与编辑器，当前处于活跃开发阶段。

这份 README 的目标不是替代详细设计文档，而是给新的协作者或新的对话一个可靠入口，避免继续建立在过时前提上。

## 当前状态

以下状态基于当前代码库整理，并已用本地命令验证：

- `zig build` 通过
- `zig build test` 通过
- 场景序列化为 `JSON v6`
- 物理查询已存在：`raycast`、`overlapAabb`、`sweepAabb`
- 动画编辑器已具备运行时检视、时间轴浏览、Animation Graph 基础编辑
- MCP 已有 `stdio` 只读基座，可暴露 `scene://hierarchy`、`selection://current`、`entity://{id}`
- MCP tools、引擎级 `CommandQueue`、WASM 脚本 backend、语义查询层仍未完成

## 常用命令

```bash
zig build
zig build test
zig build run
zig build run -- --frames 120
zig build run -- mcp --transport stdio
zig build run -- validate --root assets
zig build compile-commands
```

说明：

- `mcp` 是 `run -- --mcp --transport stdio` 的命令别名
- `validate` 默认检查 `assets`，并生成 `dist/reports/asset_validation_report.json`

## 文档索引

- [开发计划](docs/plan.md)
- [AI-Native 重构计划](docs/ai_native_restructuring.md)

## 对话式协作最需要知道的事实

- 这不是“从零重写”的项目，AI-native 方向默认建立在现有 `World`、`scene_io`、`ScriptVM`、编辑器历史系统之上
- 当前 MCP 仍是只读阶段，后续如果要让 AI 和 UI 真正共用写入口，核心缺口不是协议，而是引擎级命令总线
- 文档里凡是涉及 AI 接入，优先以 MCP `stdio` 为准，不再扩展 HTTP/WebSocket 叙事
- 如果后续对话涉及“当前真实状态”，优先以代码和本 README 为准，再回头修计划文档
