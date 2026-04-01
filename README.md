# Guava Engine

Guava Engine 是基于 Zig 构建的 AI-Native 游戏引擎与编辑器。

## 当前状态

- `zig build` 通过
- 场景序列化 `JSON v6`
- MCP `stdio` 协议：只读资源 + 实体写工具 + Staged Transaction + Ghost Preview
- AI 与编辑器共享 `CommandQueue`，支持 `stage/apply/discard`
- `query_entities` 支持分页、文本/组件/空间过滤 + BVH 候选加速
- WASM 脚本闭环：Zig→WASM 编译、热重载、Guest panic 结构化回传
- 渲染管线：自研 RHI（Metal / Vulkan）+ PBR + IBL + 级联阴影 + Bloom + FXAA + SSAO（Compute/Fragment 双路径）+ SSR + SSGI + TAA + DOF + Contact Shadows
- 路径追踪重写：CPU / Metal 已同步 GGX VNDF + NEE / MIS + Principled BSDF + HDR `.hdr` 环境重要性采样 + 俄罗斯轮盘 + 8x8 tile adaptive sampling；Editor PathTrace 导出已支持 `albedo / normal` AOV sidecar + 自动降噪后端 `OIDN(动态加载) -> MPS Guided -> CPU Guided`，并可在停止态下按固定步长输出 PNG / OpenEXR 序列
- Jolt Physics：刚体、碰撞体、Trigger 事件、Constraints、Debug Draw
- 编辑器：Inspector 编译期反射 + WASM 灰盒调参 + Animation Graph + Post-Process 参数/效果编辑器 + 响应式状态栏/窄 Inspector 降级

## 常用命令

```bash
zig build
zig build -Doptimize=ReleaseFast
zig build test
zig build run
zig build run -- --create /absolute/path/to/MyGame --name MyGame
zig build run -- --open /absolute/path/to/MyGame
zig build run-engine
zig build run-engine -- --frames 120
zig build run-engine -- --project-path /absolute/path/to/MyGame
zig build run-engine -- mcp --transport stdio
zig build run-engine -- validate --root assets
zig build run-engine -- --backend vulkan
zig build launcher
zig build run-launcher
zig build run-launcher -- --create /absolute/path/to/MyGame --name MyGame --no-launch
zig build compile-commands
# 基线测试（标准光栅化）
zig build render-test

# RT 阴影测试
zig build render-test -- --rt-shadows

# 路径追踪测试
zig build render-test -- --path-trace

# 多特性组合
zig build render-test -- --rt-shadows --fxaa --bloom

# 更新 golden 基准图（第一次或确认改动正确后）
zig build render-test -- --rt-shadows --update-golden

# 导出渲染帧（PPM 格式，可查看）
zig build render-test -- --rt-shadows --export-png
```

## 文档

- [开发规划](docs/GUAVA_ENGINE.md)
- [Hybrid Renderer 升级路线](docs/HYBRID_RENDERER_UPGRADE.md)

## 项目启动器

- `zig build run` 现在默认先启动 `guava-launcher`，创建或选择项目后再拉起引擎。
- `zig build run-engine` 保留为直接进入编辑器/引擎的入口，适合跳过启动器时使用。
- `guava-launcher` 是独立入口，用于创建、选择和打开带 `.guava` 标记文件的游戏项目目录。
- 启动器当前会创建基础结构：`.guava`、`Content/Scenes` 和 `Derived`。
- 启动器通过 `--project-path` 把项目根路径传给编辑器，这也是后续项目隔离和资源面板重构的入口。

## 协作须知

- AI-Native 方向建立在现有 `World`、`scene_io`、`ScriptVM`、编辑器历史系统之上
- AI 与 UI 共用命令总线、Staged Transaction 和第二世界 Ghost Pass
- 凡涉及 AI 接入，以 MCP `stdio` 为准
- 当前真实状态以代码和本 README 为准
