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
- MCP `stdio` 已支持场景资源、实体写工具，以及协作资源：`scene://hierarchy`、`selection://current`、`entity://{id}`、`schema://components`、`schema://scene-json-v6`、`schema://prefab`、`schema://material`、`schema://tools`、`editor://context`、`editor://intent-log`、`preview://staged`
- 引擎级 `CommandQueue` 已落地最小闭环，Inspector / Hierarchy / 基础创建路径已复用；MCP 已支持 `stage/apply/discard` staged transaction，编辑器 viewport 已有 ghost preview pins、apply/discard overlay、同视口 HDR 第二世界 shaded ghost pass，并支持直接选中 ghost 后用 gizmo 调整 staged transform
- 现已具备首版 AI 规则与发现层：`schema://components`、`schema://scene-json-v6`、`schema://prefab`、`schema://material`、`schema://tools` 可读，MCP `query_entities` 支持 `count_only` / `limit` / `offset` / `truncated`
- Phase 6 的 Scene / Prefab / Material 保存-读取-再保存一致性测试已补齐；Scene 现已持久化 Script 组件与嵌入式脚本资源（源码 / bytecode / user_data），Prefab 现已持久化 Script 组件、参数与 `script_asset_id`，WASM 公共变量也已反射进 Inspector，可直接灰盒调参并热应用到运行中的 WasmVM 实例
- 当前剩余主任务集中在 Editor Utility UI、Query 扩展、更细的脚本 `source_location` 错误映射，以及更重的 headless / ECS 内核演进

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
- AI 与 UI 已开始共用命令总线、staged transaction 和第二世界 shaded ghost pass；当前缺口主要在 Editor Utility UI、查询扩展、脚本错误定位与内核演进，而不是 MCP 协议本身
- 文档里凡是涉及 AI 接入，优先以 MCP `stdio` 为准，不再扩展 HTTP/WebSocket 叙事
- 如果后续对话涉及“当前真实状态”，优先以代码和本 README 为准，再回头修计划文档


## 架构图

```Plaintext

[ 人类创作者 ]                               [ AI 智能体 (Claude/Cursor) ]
      │                                                │
      ▼                                                ▼
┌────────────────────┐                       ┌────────────────────┐
│ ImGui 编辑器客户端   │                       │    MCP 协议服务端   │
│ (视口/属性面板/拖拽)  │ ◄────上下文注入────── │ (Tools/Resources)  │
└────────┬───────────┘    (选中项/摄像机/射线)   └────────┬───────────┘
         │                                            │
         │ (UI 操作转换)                               │ (JSON 指令解析)
         │                                            │
         ▼                                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Command Queue                           │
│                 (指令去重合并 Coalescing / 历史 Undo 栈)          │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Staged Transaction (暂存事务隔离区)               │
│              (Sparse Delta Map 稀疏补丁表 / 虚拟实体)             │
└─────────┬───────────────────────┬──────────────────────┬────────┘
          │                       │                      │
  【1. 视口协同反馈】         【2. 逻辑沙箱闭环】        【3. 灰盒参数反射】
          │                       │                      │
          ▼                       ▼                      ▼
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│ Ghost Preview 渲染 │  │ WasmVM Sandbox     │  │ 脚本公共变量反射     │
│ (主世界与暂存区混合) │  │ (后台静默编译与热更)│  │ (自动生成UI Slider)  │
│ (半透明绿色幽灵材质) │  │ (Panic 跨界拦截)    │  │ (人类直接拖拽微调)   │
└─────────┬──────────┘  └─────────┬──────────┘  └─────────┬──────────┘
          │                       │                      │
 [人类直观看到AI生成的网格]  [报错通过MCP直接弹回AI]   [参数修改再次压入队列]
          │                       │                      │
          ▼                       ▼                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                        决策与应用 (Commit)                        │
│             (人类点击 Apply / Discard，或者 AI 测试验证通过)       │
└─────────────────────────────────┬───────────────────────────────┘
                                  │ (Delta 补丁执行覆盖)
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                       主世界 (World State)                        │
│                    (ECS Registry / 物理引擎真值)                  │
└─────────────────────────────────────────────────────────────────┘

```

这个架构图定义了引擎中三个极其具体的业务流：
1. 场景编辑流 (防破坏隔离)

当 AI 通过 MCP 下发创建或移动实体的指令时，这些数据停留在 Staged Transaction 层。
渲染器（Renderer）在执行 DrawCall 时，会同时读取主世界和暂存事务。主世界的物体正常渲染，暂存事务里的修改会被强制挂载一个“半透明绿色幽灵材质”。
人类在 ImGui 视口里直接看到绿色的生成物，可以用鼠标 Gizmo 拖拽这个绿色的幽灵网格进行位置微调。人类点击 Apply 后，数据才会沉淀到下方的主世界。这就解决了 AI “搞乱人类场景”的问题。
2. 逻辑生成流 (自动自愈)

AI 编写了一段 Zig 业务代码，引发了内存越界。
引擎后台编译出 WASM，加载进 WasmVM Sandbox。运行时触发陷阱（Trap）。因为存在跨界拦截，引擎主进程不会崩溃，而是抓取到具体的错误行号和原因，立刻通过 MCP 的 Notification 接口反向扔给上方的 AI 智能体。AI 收到错误，自行重写代码并再次下发指令，全程人类无需看报错日志。
3. 参数微调流 (UI 动态扩充)

AI 生成的逻辑通常是一个黑盒，为了让人类拥有控制权，走的是灰盒参数反射链路。
当 WASM 编译完成后，引擎解析其导出的公有变量（如 patrol_speed: f32）。引擎会自动在人类的 ImGui 属性面板 中动态生成一个名为 patrol_speed 的滑动条（Slider）。人类不需要知道 AI 是用什么算法写的巡逻逻辑，只需要在 UI 上拉动滑块，就能实时改变 AI 代码在主世界中的运行表现。
