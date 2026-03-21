# Guava Engine 开发规划

> **基线日期**: 2026-03-21 | **引擎语言**: Zig | **目标**: AI-Native 游戏引擎

---

## 一、项目愿景

Guava Engine 是基于 Zig 构建的现代游戏引擎，核心目标是成为业界领先的 **AI-Native 游戏引擎**：

1. **场景感知** — AI 通过 MCP 协议直接读懂 3D 世界、实体关系和空间属性。
2. **安全修改闭环** — AI 的修改进入 Staged Transaction 预览沙盒，由人类审查后再应用。
3. **即时反馈** — WASM 虚拟机实现毫秒级代码热重载与结构化错误自愈。

当前 AI 基础设施已基本建成，核心任务是**严格遵循 AI-Native 架构标准，补齐让引擎能真正做游戏的核心系统**。

---

## 二、当前状态（已落地能力）

### 2.1 AI-Native 基础设施 ✅
| 能力 | 说明 |
|------|------|
| MCP 协议基座 | `stdio` 传输，稳定运行 |
| 只读场景感知 | `scene://hierarchy`、`entity://{id}`、`selection://current` |
| 编辑器上下文 | `editor://context`、`editor://intent-log` |
| Schema 资源族 | `schema://components`、`schema://scene-json-v6`、`schema://prefab`、`schema://material`、`schema://tools` |
| 统一写入口 | `CommandQueue` 覆盖实体 CRUD、变换、父子层级、显隐 |
| Staged Transaction | `stage/apply/discard` + 同视口 HDR 第二世界着色预览（Ghost Pass） |
| 查询 API | `query_entities` 支持分页、多条件过滤、半径/AABB 空间过滤、BVH 候选加速 |
| WASM 脚本闭环 | WAMR 接入、Zig→WASM 编译、Guest panic 结构化回传（含 source_location） |
| Inspector 反射 | 编译期 comptime 数据驱动 + WASM 公共变量动态灰盒调参 |

### 2.2 渲染系统 ✅ (95%)
| 功能 | 状态 |
|------|------|
| RenderGraph 架构 | ✅ |
| PBR + IBL 环境光 | ✅ |
| 级联阴影 + 点光 Cube Shadow | ✅ |
| Depth Prepass / Skybox | ✅ |
| Bloom / Tonemap / FXAA | ✅ |
| SSAO / SSR / TAA / DOF | ✅ |
| Gizmo / Outline / ID Pass | ✅ |

### 2.3 物理系统 ✅ (80%)
| 功能 | 状态 |
|------|------|
| Jolt Physics 集成 | ✅ |
| Rigidbody (static/dynamic/kinematic) | ✅ |
| Box/Sphere/Mesh Collider | ✅ |
| 固定步长更新 | ✅ |
| Trigger 事件 (enter/stay/exit) | ✅ |
| Constraints (Point/Hinge/Slider/Distance) | ✅ |
| Debug Draw 可视化 | ✅ |
| Physics BVH 空间查询 | ✅ |

### 2.4 动画系统 ✅ (60%)
| 功能 | 状态 |
|------|------|
| 骨骼动画导入 / GPU Skinning | ✅ |
| Animation Graph + 状态机 | ✅ |
| Cross-fade 混合 | ✅ |
| BlendTree 基础实现 | ✅ |

### 2.5 脚本系统 ✅
| 功能 | 状态 |
|------|------|
| ScriptVM 多语言抽象 | ✅ |
| ZigVM 内置脚本 | ✅ |
| WasmVM (WAMR) | ✅ |
| 生命周期回调 (OnInit/OnUpdate/OnDestroy) | ✅ |
| 热重载 | ✅ |
| 参数反射 Inspector | ✅ |

### 2.6 资产 & 场景 ✅
| 功能 | 状态 |
|------|------|
| AssetRegistry + 异步加载 | ✅ |
| glTF / 纹理 / 材质 / 环境贴图导入 | ✅ |
| 场景序列化 JSON v6 | ✅ |
| Prefab 序列化 (含 Script) | ✅ |
| ECS + 层级变换 + BVH 空间索引 | ✅ |

### 2.7 编辑器 ✅
| 功能 | 状态 |
|------|------|
| Dock 布局 / Scene Hierarchy / Inspector | ✅ |
| Gizmo 变换工具 (平移/旋转/缩放) | ✅ |
| Material Editor / Animation Editor | ✅ |
| Undo/Redo | ✅ |
| 多语言 i18n | ✅ |
| 多视口 / 相机书签 | ✅ |
| Editor Utility UI (WASM ImGui 35 API) | ✅ |

---

## 三、AI-Native 架构标准

所有新系统的开发必须遵循以下准则：

### 3.1 读写分离 (MCP 契约)
- **读 (Resource)**: 新系统状态必须可抓取为静态快照，通过 MCP Resource 暴露。`schema://components` 必须更新新组件字段。
- **写 (Command)**: 所有场景状态修改必须通过 `CommandQueue`，禁止越过总线直接写内存。

### 3.2 安全隔离预览 (Staged Transaction)
- 修改指令必须能运行在 `PreviewWorld` 快照中。
- `apply` 前主世界数据不可被污染。
- `PreviewWorld` 不注册真实物理刚体。

### 3.3 脚本沙盒隔离
- 暴露给 WASM 的新 API 必须有严格安全边界。
- Host 捕获 trap，Guest 承担 panic 定位与回传责任。

### 3.4 数据格式稳定
- 场景序列化保持 JSON v6。添加新组件时更新对应 Schema，不另起新格式。

### 3.5 协议边界
- MCP v1 只做 `stdio`。stdout 只给 MCP 消息，普通日志走 stderr 和文件。
- 协议线程不直接写 `World`，只读资源来自主线程快照。

---

## 四、待建核心系统

### 4.1 音频系统 🔴
**目标**: 集成 OpenAL-soft 或 SoLoud，实现完整音频能力。

| 交付物 | 规格 |
|--------|------|
| AudioSource / AudioListener / AudioClip 组件 | 场景序列化、Inspector 编辑 |
| 格式支持 | WAV / OGG |
| 3D 空间音效 | 距离衰减、多普勒效应 |
| 混音器 | 主音量 / 音乐 / 音效三组控制 |
| MCP 资源 | `audio://mixer-status` |
| WASM API | `AudioSource.play()` / `stop()` / `setVolume()` |

### 4.2 游戏内 UI 系统 🔴
**目标**: 实现轻量级顶点缓存 Runtime UI，集成 stb_truetype 字体渲染。

| 交付物 | 规格 |
|--------|------|
| Canvas 系统 | 分辨率自适应缩放与对齐 |
| 核心控件 | Button / ProgressBar / Text (SDF) / Image / 九宫格 |
| 交互逻辑 | UI 输入捕获（点击 UI 不触发游戏内事件） |
| WASM API | AI 可通过指令生成和排版运行时 UI 组件 |

### 4.3 场景管理 🔴
**目标**: 实现多场景运行时管理。

| 交付物 | 规格 |
|--------|------|
| SceneManager API | `load("level_2")` / `unload()` |
| 异步加载 | Loading 界面、不阻塞主线程 |
| 叠加加载 | 动态加载/卸载子区域 |
| 全局对象 | 跨场景不销毁对象（玩家数据、全局管理器） |
| WASM API | 场景生命周期控制 |

### 4.4 游戏生命周期 🔴
**目标**: 明确的 Play/Pause/Stop 状态机。

| 交付物 | 规格 |
|--------|------|
| GameState 状态机 | GameStart / Playing / Paused / GameOver / Quit |
| 时间控制 | Time Scale（暂停、慢动作） |
| 脚本生命周期 | 明确的 onStart / onUpdate / onDestroy 执行顺序 |

### 4.5 物理查询 WASM 接口 🟡
**目标**: 将底层物理查询暴露给 WASM 脚本层。

| 交付物 | 规格 |
|--------|------|
| Raycast API | 射线检测，返回 hit 信息 |
| OverlapSphere / OverlapAABB | 区域重叠检测 |
| Trigger 事件回调 | `onTriggerEnter` / `onTriggerExit` |

### 4.6 动画事件系统 🟡
**目标**: 动画关键帧驱动脚本回调。

| 交付物 | 规格 |
|--------|------|
| 关键帧回调 | 动画播放到指定帧触发脚本（攻击判定、脚步声） |
| 1D/2D Blend Tree | 复杂状态混合（Idle→Walk→Run） |
| Upper/Lower Body 分层 | 上下半身独立动画 |

### 4.7 导航寻路 🟡
**目标**: 集成 Recast/Detour，实现 NavMesh 烘焙与自动避障。

| 交付物 | 规格 |
|--------|------|
| NavMesh 生成 | 静态/动态网格烘焙 |
| 寻路代理 | AI 自动避障、路径点追踪 |
| 编辑器可视化 | NavMesh 调试覆盖层 |

### 4.8 资源打包 🟡
**目标**: 将资源压缩打包为发布格式。

| 交付物 | 规格 |
|--------|------|
| Packer | 压缩打包为 `.pak` 二进制文件 |
| 平台适配 | 纹理自动转换为 BC7/ASTC |
| 依赖管理 | 仅打包场景引用的资源 |

### 4.9 开发工具补齐
| 工具 | 规格 |
|------|------|
| 存档系统 | 持久化全局状态框架 |
| 输入映射 | Action-Key 映射（Space + Gamepad A → Jump） |
| 性能分析器 | 帧内 GPU/CPU 时间线 + 内存用量可视化 |

---

## 五、内核演进路线

### 5.1 数据导向 ECS (SparseSet → Archetype 评估)

当前 `World` 采用胖实体 (AoS) + SparseSet 混合布局：

| 组件 | 存储位置 |
|------|----------|
| Transform | ✅ SparseSet |
| Rigidbody | ✅ SparseSet |
| BoxCollider / SphereCollider | ✅ SparseSet |
| 其余冷数据 | Entity (AoS) |

后续路线：冷热分离完成后，等 Query/Physics 稳定运行，再评估是否向 Archetype 模型推进。

### 5.2 Plugin / Headless App Shell

将 `Application` 拆分为可组合插件：

| 插件 | 职责 |
|------|------|
| CorePlugin | 主循环、时间、输入 |
| PhysicsPlugin | Jolt 步进、碰撞 |
| ScriptPlugin | WASM / Zig VM |
| RenderPlugin | 渲染管线 |
| EditorPlugin | ImGui UI |
| McpPlugin | MCP 协议 |

**最终目标**: 纯正 Headless Profile，AI 可在后台静默运行物理/脚本沙盒 5000 帧验证逻辑，无需初始化渲染和窗口。

---

## 六、执行路线图

### 阶段一：补全生命线
1. 音频系统集成
2. 物理查询 API 暴露到 WASM
3. GameState 与场景生命周期

### 阶段二：交互与表现
1. 游戏内 2D UI 系统
2. 动画事件系统
3. 导航寻路

### 阶段三：架构与分发
1. Application Headless 插件化重构
2. 资源打包 Asset Cooking
3. 性能分析器

---

## 七、开发纪律

### 7.1 日常流程
1. 改最小模块 → 跑单测 → 跑集成验证 → 跑全量 `zig build` / `zig build test`。
2. 不要同时大面积改 MCP 协议和 Editor UI —— 问题来源不可分辨。

### 7.2 验收方式
每个功能至少保留三种验证：编译验证、单元测试、手工 smoke test。

### 7.3 Staged Transaction 约束
- v1 只允许单活跃事务，新的 `stage_transaction` 替换旧事务。
- 内存模型：命令列表 + 预览世界快照 + 轻量摘要三层。
- apply = 重放命令到主世界；discard = 销毁预览，不改主世界。
- PreviewWorld 不向主物理系统注册真实刚体。

### 7.4 线程安全
- 协议线程不直接写 `World`。只读资源来自主线程快照。退出信号用原子变量传递。

### 7.5 新系统 Runbook
接手新模块时，先读这 6 个文件再动手：
1. `src/engine/mcp/server.zig`
2. `src/engine/mcp/collaboration.zig`
3. `src/engine/core/command_queue.zig`
4. `src/editor/ai_native/collaboration.zig`
5. `src/engine/render/renderer.zig`
6. `src/engine/script/runtime.zig`

---

## 八、术语表

| 术语 | 含义 |
|------|------|
| `World` | 引擎主场景世界，ECS 容器 |
| `CommandQueue` | AI 与编辑器共享的统一写入口 |
| MCP Resource | 只读资源（不执行修改） |
| MCP Tool | 可执行动作（通过 CommandQueue） |
| Staged Transaction | 待确认的协作修改（需 apply/discard） |
| `PreviewWorld` | Staged 对应的预览世界（渲染/选中/gizmo） |
| `ScriptVM` | 脚本运行时抽象层（WasmVM 挂载于下） |

---

## 九、已完成的历史开发阶段

以下为 AI-Native 重构已完成的各阶段记录，作为架构约束的来源参考。

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 0 | 基线收口：编译/测试恢复绿色，删除 HTTP 旧叙事 | ✅ |
| Phase 1 | MCP `stdio` 只读基座：scene/entity/selection 资源 | ✅ |
| Phase 2 | CommandQueue 最小闭环：实体 CRUD + 变换 + coalescing | ✅ |
| Phase 3 | Editor 写路径接入 Command：Inspector/Hierarchy/Manipulation | ✅ |
| Phase 4 | MCP 写工具 + Staged Transaction + Ghost Preview | ✅ |
| Phase 5 | WASM 脚本 + Editor Utility UI (35 native symbols) | ✅ |
| Phase 6 | Schema 资源族 + Scene/Prefab/Material 一致性测试 | ✅ |
| Phase 7 | Query API：语义过滤 + 排序 + 半径/AABB + BVH 加速 | ✅ |

---

## 十、文件索引

| 模块 | 关键文件 |
|------|----------|
| MCP 服务器 | `src/engine/mcp/server.zig` / `tools.zig` / `resources/mod.zig` |
| 命令总线 | `src/engine/core/command.zig` / `command_queue.zig` |
| 查询引擎 | `src/engine/core/query_engine.zig` |
| 协作层 | `src/engine/mcp/collaboration.zig` / `src/editor/ai_native/collaboration.zig` |
| 渲染管线 | `src/engine/render/renderer.zig` / `base_pass.zig` / `mesh_pass.zig` |
| 物理系统 | `src/engine/physics/system.zig` / `physics_bvh.zig` |
| 脚本系统 | `src/engine/script/runtime.zig` / `wasm_vm.zig` / `wasm_compiler.zig` |
| 场景 IO | `src/engine/scene/scene_io.zig` / `world.zig` / `prefab.zig` |
| 编辑器 | `src/editor/core/layer.zig` / `ui/viewport.zig` |

---

## 十一、FAQ

**Q: 为什么 v1 只做 stdio？**
A: stdio 最容易对接桌面 MCP 客户端，不需要先解决网络服务和端口管理。协议层跑通比传输层更优先。

**Q: 为什么不删 `vm.zig`？**
A: `ScriptVM` 是稳定抽象层。正确方向是把 WasmVM 作为新 backend 挂进来，而不是拆掉抽象层导致脚本系统和热重载一起打散。

**Q: 为什么不上 `tags` / `topology_version` / `data_version`？**
A: 这些字段不是当前数据模型的真实基础设施。读写闭环稳定后再决定是否需要，避免契约与实现脱节。

**Q: 资源为什么做快照？**
A: 协议线程和主线程职责不同。跨线程直接读可变状态会把线程安全问题带进协议层。快照多一层但边界清晰。

**Q: 最终判断标准是什么？**
A: 当 AI 能完成"读场景 → 改实体 → 读回验证 → 运行脚本 → 再验证"这个闭环时，引擎进入真正可用阶段。当你能对 AI 说"帮我创建一个带有 UI 血条和音效的主角，当点击鼠标时通过射线检测开火，并打包发布"且 AI 能在无崩溃的反馈循环中完成这一切时，Guava Engine 达到完全体。
