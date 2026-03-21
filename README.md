# Guava Engine

Guava Engine 是基于 Zig 构建的 AI-Native 游戏引擎与编辑器。

## 当前状态

- `zig build` 通过
- 场景序列化 `JSON v6`
- MCP `stdio` 协议：只读资源 + 实体写工具 + Staged Transaction + Ghost Preview
- AI 与编辑器共享 `CommandQueue`，支持 `stage/apply/discard`
- `query_entities` 支持分页、语义过滤、半径/AABB 空间过滤 + BVH 候选加速
- WASM 脚本闭环：Zig→WASM 编译、热重载、Guest panic 结构化回传
- 渲染管线：PBR + IBL + 级联阴影 + Bloom + FXAA + SSAO + SSR + TAA + DOF
- Jolt Physics：刚体、碰撞体、Trigger 事件、Constraints、Debug Draw
- 编辑器：Inspector 编译期反射 + WASM 灰盒调参 + Animation Graph + 多视口

## 常用命令

```bash
zig build
zig build test
zig build run
zig build run -- --frames 120
zig build run -- mcp --transport stdio
zig build run -- validate --root assets
zig build run -- --backend vulkan
zig build compile-commands
```

## 文档

- [开发规划](docs/GUAVA_ENGINE.md)

## 协作须知

- AI-Native 方向建立在现有 `World`、`scene_io`、`ScriptVM`、编辑器历史系统之上
- AI 与 UI 共用命令总线、Staged Transaction 和第二世界 Ghost Pass
- 凡涉及 AI 接入，以 MCP `stdio` 为准
- 当前真实状态以代码和本 README 为准
