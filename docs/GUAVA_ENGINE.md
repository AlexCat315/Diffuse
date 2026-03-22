# Guava Engine 开发规划

> **基线日期**: 2026-03-21 | **引擎语言**: Zig | **目标**: AI-Native 实时 + 离线双轨渲染引擎

---

## 一、项目愿景

Guava Engine 是基于 Zig 构建的现代游戏引擎，终极目标是成为业界首个 **AI 与人类同为一等公民** 的 3D 创作平台：

> **一个用户和 AI 都是一等公民的游戏/影视引擎，兼具实时光栅化和离线路径追踪，追求极致的物理真实渲染。**

### 1.1 核心架构原则

1. **场景感知** — AI 通过 MCP 协议直接读懂 3D 世界、实体关系和空间属性。
2. **安全修改闭环** — AI 的修改进入 Staged Transaction 预览沙盒，由人类审查后再应用。
3. **即时反馈** — WASM 虚拟机实现毫秒级代码热重载与结构化错误自愈。
4. **双轨渲染** — 实时光栅化用于创作迭代，离线路径追踪用于影视级出图，共享同一场景数据。
5. **视觉反馈回路** — 引擎频繁回传视口截图给 AI Vision Model，AI 可判断操作结果是否符合审美预期。

### 1.2 Jarvis（AI 助手）的定位

Jarvis **不是取代人类的自动机**，而是一个「拥有无限带宽的高级技术美术 + 引擎客户端」：

- 它能**读取所有 JSON 文本**，知道世界由哪些节点构成
- 它通过 **MCP 接口**直接向引擎发送「创建对象」「修改参数」「编译 Shader」指令
- 它能**看见**——引擎将视口截图回传给 Vision Model，让 AI 通过视觉判断操作是否正确
- 它能**主动提问**——当意图模糊时，AI 返回 `intent_preview` 请求确认，而非盲目执行

### 1.3 人类独立生产力保障

即使完全不使用 AI，这套架构对纯人类开发者同样是生产力提升：
- 编辑器布局遵循 20 年 3D 软件工业标准（Outliner / Viewport / Inspector），无学习成本
- Command System 带来可视化撤销时间线，优于传统的黑盒 Undo 栈
- 异步 UI 渲染解耦——场景卡顿时面板仍满帧响应
- 数据驱动的 Inspector 与 JSON 双向绑定，杜绝面板与场景不同步的幽灵 Bug

当前 AI 基础设施已基本建成，核心任务是**补齐让 AI 能完整管理「概念→资产→逻辑→出图」四阶段工作流的基础设施**。

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
| SSAO | ✅ 已接入 drawFrame，r8_unorm 输出 |
| SSR / DOF | ✅ 管线存在，未接入 |
| TAA | ✅ 管线已修复，未接入 drawFrame（需 Jitter） |
| Gizmo / Outline / ID Pass | ✅ |
| 体积雾 | ✅ |

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

## 三、创作者工作流愿景（四阶段）

以下是创作者在引擎中最核心的四个工作流阶段，以及 Jarvis 在其中扮演的角色。

### 阶段 A：概念构建与场景 Blockout（灰模白盒）

**痛点**：脑中有画面，但手动搭建立方体、摆放光源、调整坐标非常消磨灵感。

**Jarvis 流程**：
1. 人类输入：「搭建一个赛博朋克小巷白盒场景。长 50 米，两边高楼，地面有积水坑。冷蓝月光，深处放红色霓虹灯。」
2. AI 通过 Command API 实例化基础 Mesh（立方体/平面），计算空间坐标，注入 Light 组件
3. 引擎实时热重载，视口瞬间出现灰模场景
4. 人类反馈：「路太宽，收窄一半。霓虹灯亮度翻倍。」→ AI 修改 → 引擎即时更新

**关键价值**：AI 替代了数值试探和坐标计算，创作者像导演一样用自然语言调度场景。

### 阶段 B：资产填充与材质魔法（PBR/Shader）

**痛点**：灰模变真实场景需要找模型、调 PBR 参数、手写 GLSL 特效。

**Jarvis 流程**：
1. 人类选中地面平面：「加上湿润沥青材质，粗糙度调低，反射霓虹灯。」
2. AI 获取选中 Entity ID，修改 Material 参数（roughness=0.1, metallic=0.2）
3. 人类：「我想要雨水涟漪效果，但不会写 Shader。」
4. AI 编写 `water_ripple.frag.glsl`，编译并挂载到材质上，引擎实时应用

**关键价值**：AI 突破技术壁垒。只要有审美和方向，AI 用 Shader/参数将其物理化。

### 阶段 C：逻辑与交互（脚本与系统）

**痛点**：场景好看但是死的，需要角色控制器、寻路、状态机，容易出错。

**Jarvis 流程**：
1. 人类：「让角色在小巷里巡逻，在垃圾桶之间绕开障碍物。」
2. AI 生成 NavMesh 烘焙指令，编写 Zig/WASM 巡逻脚本并挂载到 Entity
3. 运行时角色卡住 → 人类：「修复碰撞逻辑。」
4. AI 读取 Debug Log，发现碰撞体 Radius 过大，修改参数并重启场景

**关键价值**：AI 充当不知疲倦的 Gameplay 程序员。

### 阶段 D：极致渲染与出片（双轨引擎真正威力）

**痛点**：实时很流畅，但导出影视级短片时光栅化反射太假、阴影不够柔和。

**Jarvis 流程**：
1. 人类：「场景确认，切换离线路径追踪，渲染 10 秒镜头，从巷口推进到霓虹灯下。全局光照。」
2. AI 切换 `render_settings.mode = path_trace`
3. AI 生成 Camera Animation 关键帧轨迹
4. 触发 Progressive Path Tracer，逐帧累积光线追踪采样
5. 输出 HDR EXR 序列

**关键价值**：实时模式极速搭建试错，离线模式 AI 管理繁重的光追出图任务。

---

## 四、AI 协同编辑器 UI 设计

### 4.1 布局总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 📁 File  ⚙️ Edit  🏠 View  | 🔄 Raster ⇌ 🔮 PathTrace | ⏪ Undo (AI: Move) ⏩ │
├────────────┬───────────────────────────────────────────┬────────────────────┤
│            │ [AI State: 🧠 "正在烘焙寻路网格..."]     │                    │
│ 🌳 OUTLINER│                                           │ 🎛️ INSPECTOR      │
│ ────────── │                                           │ ──────────         │
│ ▽ Scene    │                                           │ 📦 entity: "Hero"  │
│  ├─ Camera │                                           │                    │
│  ├─ Light  │           [ 3D VIEWPORT ]                 │ Transform / Mat    │
│  ├─ Hero   │          高帧率 3D 渲染画面               │ (数据驱动滑块)     │
│  └─ Ground │          🧑 选中: 黄色高亮                │                    │
│            │          🤖 AI 操作: 紫色高亮             │                    │
├────────────┤                                           ├────────────────────┤
│ 📁 ASSETS  │                                           │ 💬 JARVIS TERMINAL │
│ ────────── │                                           │ ──────────         │
│ 🗂️ Models  │                                           │ JSON Diff 预览     │
│ 🗂️ Textures│                                           │ [✓ Apply] [✗]      │
│ 🗂️ Shaders │                                           │ 渐进式授权控制     │
├────────────┴───────────────────────────────────────────┴────────────────────┤
│ ⏱️ COMMAND TIMELINE  [🧑 Create Cube]─[🤖 Set Material]─[🧑 Change Light]  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 核心模块

#### 💬 Jarvis Terminal（AI 协同中枢）— 右下角

不仅是聊天框，是 AI 沟通修改意图的地方：

| 功能 | 说明 |
|------|------|
| **Intent → Command 映射** | 自然语言通过 LLM function calling 生成结构化 Command JSON，不直接拼原始 scene JSON |
| **JSON Diff 确认** | 修改前高亮显示变更的 JSON 节点，类似 Git Diff |
| **渐进式授权** | 简单修改（调颜色）可自动应用；破坏性修改（删除实体、替换 Shader）强制显示 Apply/Reject |
| **AI 主动提问** | 意图模糊时 AI 返回 `intent_preview` 请求人类确认再执行 |

#### 👁️ 3D Viewport（双态视口）— 正中央

| 功能 | 说明 |
|------|------|
| **Ghost Highlight** | AI 正在读取/操作的物体显示紫色呼吸灯轮廓（复用 `outline_pass`，增加 `ai_focus_entities` 列表） |
| **AI 状态悬浮窗** | 视口正上方半透明胶囊 UI，实时显示 AI 状态（「👀 分析截图...」「⚙️ 编译 GLSL...」） |
| **双轨切换** | 顶部按钮一键 Raster ⇌ PathTrace，Path Tracer 清空采样重新累积 |

#### ⏱️ Command Timeline（命令时间线）— 最底部

| 功能 | 说明 |
|------|------|
| **可视化撤销栈** | 每次操作生成节点，人类=蓝色、AI=紫色 |
| **时间穿越** | 点击任意历史节点，场景 JSON 和画面瞬间回滚 |
| **安全网** | AI 搞砸时只需点上一个蓝色节点即可恢复 |

数据结构：
```zig
const TimelineEntry = struct {
    index: u32,
    command: Command,
    timestamp: i64,
    source: enum { human, ai },
    label: []const u8,        // "Set Roughness: 0.8 → 0.05"
    snapshot_hash: u64,       // 场景状态快速哈希，用于 time travel 验证
};
```

#### 🎛️ Inspector（数据驱动属性面板）— 右上角

- 每个输入框/滑块双向绑定 JSON 文本，不与 C/Zig 指针直接绑定
- AI 在 Jarvis Terminal 修改数值时，Inspector 滑块伴随动画自动滑动到新位置
- 所见数据 = `scene.guava` 文本中的真实数据

### 4.3 截图反馈回路

| 规则 | 说明 |
|------|------|
| **触发时机** | Command 完成后的稳态帧（非每帧），Path Tracer 累积到一定 SPP 后 |
| **分辨率** | 发给 AI 的截图 512×512 足够构图/光照判断 |
| **差异对比** | 可同时发送修改前/后截图，让 AI 判断变化是否符合意图 |

---

## 五、AI-Native 架构标准

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

### 5.5 协议边界
- MCP v1 只做 `stdio`。stdout 只给 MCP 消息，普通日志走 stderr 和文件。
- 协议线程不直接写 `World`，只读资源来自主线程快照。

### 5.6 Command System（所有协同功能的基石）

Command Pattern 是 Timeline、JSON Diff、AI/人类双轨撤销的前提。**所有状态变更必须经过统一的 Command 管道**：

```
人类 Inspector 操作 ──→ Command ──→ Scene JSON ──→ 渲染
AI Jarvis 指令    ──→ Command ──→ Scene JSON ──→ 渲染
```

最小实现：
- `Command { kind, entity_id, component, field, old_value, new_value, source: enum { human, ai } }`
- `CommandHistory` 支持 undo/redo 栈
- Inspector 每个滑块操作产生 Command，而非直接写 ECS

> **注意**：当前 `CommandQueue` 已覆盖实体 CRUD / 变换 / 父子层级。需进一步扩展到材质参数、渲染设置、动画状态等所有可编辑属性，并增加 `source` 标记以区分人类/AI 来源。

### 5.7 MCP API 三层设计

MCP/WebSocket 接口分为三层，AI 不应直接写 JSON 文件等 hot-reload：

| 层级 | 用途 | 示例 |
|------|------|------|
| **Scene API** | 读写场景图 | `create_entity`, `set_component`, `delete_entity` |
| **Asset API** | 管理资产 | `import_texture`, `compile_shader`, `bake_navmesh` |
| **Render API** | 控制渲染 | `screenshot`, `switch_mode(path_trace)`, `render_sequence` |

AI 通过 Command API 发送结构化指令 → 引擎执行 Command → 同时更新内存 ECS 和持久化 JSON。Hot-reload 只作为外部文件变更的兜底机制。

### 5.8 Ghost Highlight 实现路径

复用现有 `outline_pass`（选中物体黄色轮廓），增加 AI 紫色通道：
- `OutlinePass` 增加 `ai_focus_entities: []EntityId`
- 渲染时用紫色 + 呼吸灯 alpha 脉冲
- AI 每次发 Command 时附带 `target_entity_id`，引擎自动设置高亮

---

## 六、待建核心系统

### 6.1 音频系统 🔴
**目标**: 集成 OpenAL-soft 或 SoLoud，实现完整音频能力。

| 交付物 | 规格 |
|--------|------|
| AudioSource / AudioListener / AudioClip 组件 | 场景序列化、Inspector 编辑 |
| 格式支持 | WAV / OGG |
| 3D 空间音效 | 距离衰减、多普勒效应 |
| 混音器 | 主音量 / 音乐 / 音效三组控制 |
| MCP 资源 | `audio://mixer-status` |
| WASM API | `AudioSource.play()` / `stop()` / `setVolume()` |

### 6.2 游戏内 UI 系统 🔴
**目标**: 实现轻量级顶点缓存 Runtime UI，集成 stb_truetype 字体渲染。

| 交付物 | 规格 |
|--------|------|
| Canvas 系统 | 分辨率自适应缩放与对齐 |
| 核心控件 | Button / ProgressBar / Text (SDF) / Image / 九宫格 |
| 交互逻辑 | UI 输入捕获（点击 UI 不触发游戏内事件） |
| WASM API | AI 可通过指令生成和排版运行时 UI 组件 |

### 6.3 场景管理 🔴
**目标**: 实现多场景运行时管理。

| 交付物 | 规格 |
|--------|------|
| SceneManager API | `load("level_2")` / `unload()` |
| 异步加载 | Loading 界面、不阻塞主线程 |
| 叠加加载 | 动态加载/卸载子区域 |
| 全局对象 | 跨场景不销毁对象（玩家数据、全局管理器） |
| WASM API | 场景生命周期控制 |

### 6.4 游戏生命周期 🔴
**目标**: 明确的 Play/Pause/Stop 状态机。

| 交付物 | 规格 |
|--------|------|
| GameState 状态机 | GameStart / Playing / Paused / GameOver / Quit |
| 时间控制 | Time Scale（暂停、慢动作） |
| 脚本生命周期 | 明确的 onStart / onUpdate / onDestroy 执行顺序 |

### 6.5 物理查询 WASM 接口 🟡
**目标**: 将底层物理查询暴露给 WASM 脚本层。

| 交付物 | 规格 |
|--------|------|
| Raycast API | 射线检测，返回 hit 信息 |
| OverlapSphere / OverlapAABB | 区域重叠检测 |
| Trigger 事件回调 | `onTriggerEnter` / `onTriggerExit` |

### 6.6 动画事件系统 🟡
**目标**: 动画关键帧驱动脚本回调。

| 交付物 | 规格 |
|--------|------|
| 关键帧回调 | 动画播放到指定帧触发脚本（攻击判定、脚步声） |
| 1D/2D Blend Tree | 复杂状态混合（Idle→Walk→Run） |
| Upper/Lower Body 分层 | 上下半身独立动画 |

### 6.7 导航寻路 🟡
**目标**: 集成 Recast/Detour，实现 NavMesh 烘焙与自动避障。

| 交付物 | 规格 |
|--------|------|
| NavMesh 生成 | 静态/动态网格烘焙 |
| 寻路代理 | AI 自动避障、路径点追踪 |
| 编辑器可视化 | NavMesh 调试覆盖层 |

### 6.8 资源打包 🟡
**目标**: 将资源压缩打包为发布格式。

| 交付物 | 规格 |
|--------|------|
| Packer | 压缩打包为 `.pak` 二进制文件 |
| 平台适配 | 纹理自动转换为 BC7/ASTC |
| 依赖管理 | 仅打包场景引用的资源 |

### 6.9 开发工具补齐
| 工具 | 规格 |
|------|------|
| 存档系统 | 持久化全局状态框架 |
| 输入映射 | Action-Key 映射（Space + Gamepad A → Jump） |
| 性能分析器 | 帧内 GPU/CPU 时间线 + 内存用量可视化 |

---

## 七、内核演进路线

### 7.1 数据导向 ECS (SparseSet → Archetype 评估)

当前 `World` 采用胖实体 (AoS) + SparseSet 混合布局：

| 组件 | 存储位置 |
|------|----------|
| Transform | ✅ SparseSet |
| Rigidbody | ✅ SparseSet |
| BoxCollider / SphereCollider | ✅ SparseSet |
| 其余冷数据 | Entity (AoS) |

后续路线：冷热分离完成后，等 Query/Physics 稳定运行，再评估是否向 Archetype 模型推进。

### 7.2 Plugin / Headless App Shell

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

## 七-B、渲染系统演进路线

### 当前状态

| 项目 | 状态 |
|------|------|
| RHI 层 | SDL3 GPU API，仅图形管线（无 Compute） |
| 后处理 | Bloom + Tonemap + FXAA ✅，SSAO ✅（已接入 drawFrame），TAA ✅（管线已修复，未接入 drawFrame） |
| 纹理格式 | 新增 r8_unorm（SSAO 单通道输出） |
| Cooked 资产 | JSON hex-encoded，4K HDR 产生 ~256MB。已提高 readFileAlloc 限制到 512MB |
| **光线追踪** | **SDL3 GPU API 不支持 Ray Tracing** |

### 渲染演进路径

| 方案 | 优点 | 缺点 |
|------|------|------|
| **CPU Path Tracer（纯 Zig）** | 不依赖 GPU RT 硬件，可立即开始 | 慢（4K 一帧可能数分钟） |
| **Metal Ray Tracing API** | GPU 加速，Apple Silicon 原生 | 需绕过 SDL3，写原生 Metal 代码 |

**策略**：先做 CPU Path Tracer 作为 MVP，证明双轨切换的 UI 和数据流可以跑通。CPU 版本也适合 CI 自动化 golden image 测试。稳定后用 Metal RT 替换内核提速。

### TAA 完整接入待办

TAA 管线和初始化已修复，但未接入 `drawFrame()`。完整接入需要：
1. **Jitter 注入**：将 Halton 序列偏移加到投影矩阵，影响所有几何 Pass
2. **History Texture 管理**：每帧将当前结果写入 history，下帧对比融合
3. **Velocity Buffer**：可选，静态场景可省略，动态场景需要 motion vector pass
4. **渲染顺序**：TAA 应在 HDR Tonemap 之前运行（HDR 空间保留更多细节）

### Cooked 资产二进制格式迁移

当前 hex-encoded JSON 严重膨胀。迁移计划：
- **场景元数据**：保持 JSON（AI 可读，通常几 KB）
- **GPU 二进制资产**（纹理/网格）：迁移到 `.guava_bin` 二进制格式 + 元数据 JSON 分离
- 分离后 4K HDR 从 ~256MB 降到 ~34MB，IBL 从 ~192MB 降到 ~25MB

---

## 八、执行路线图

### Phase 0：Command System 基石（最高优先级）

> 所有后续 AI 协同功能的前提。

1. 扩展 `CommandQueue` 覆盖材质参数、渲染设置等所有可编辑属性
2. Command 增加 `source: enum { human, ai }` 标记
3. `CommandHistory` 支持可视化 undo/redo 栈
4. Inspector 每个滑块产生 Command，不再直接写 ECS

### Phase 1：MCP Scene API + 截图回传

1. MCP 三层 API 实现（Scene / Asset / Render）
2. `render_api.screenshot()` → base64 PNG 回传接口
3. Jarvis Terminal（ImGui）：文本输入 + JSON Diff 显示 + Apply/Reject

### Phase 2：协同编辑器 UI

1. Ghost Highlight（复用 outline_pass 加紫色通道）
2. Command Timeline UI（ImGui 横向节点渲染）
3. Inspector 双向绑定 JSON，AI 修改实时联动滑块
4.重构 editor 整个界面，确保和 UI 产品设计一致

### Phase 3：补全游戏生命线

1. 音频系统集成（SoLoud 已在 third_party）
2. 物理查询 API 暴露到 WASM
3. GameState 状态机 + 场景生命周期
4. 游戏内 2D UI 系统

### Phase 4：双轨渲染

1. CPU Path Tracer MVP（BVH + 蒙特卡洛积分）
2. Raster ⇌ PathTrace 一键切换 UI
3. EXR 序列帧输出
4. TAA 完整接入（Jitter + History + Velocity）
5. Cooked 资产二进制格式迁移

### Phase 5：架构与分发

1. Application Headless 插件化重构
2. 资源打包 Asset Cooking（.pak）
3. 性能分析器

### Phase 6：Metal Ray Tracing（远期）

1. Metal RT API 替换 CPU Path Tracer 内核
2. 保留 SDL3 做窗口/输入/音频，仅渲染走原生 API
3. 导航寻路、动画事件、BlendTree 等交互系统补全

---

## 九、开发纪律

### 9.1 日常流程
1. 改最小模块 → 跑单测 → 跑集成验证 → 跑全量 `zig build` / `zig build test`/`zig build run -- --frames 120`。
2. 不要同时大面积改 MCP 协议和 Editor UI —— 问题来源不可分辨。

### 9.2 验收方式
每个功能至少保留三种验证：编译验证、单元测试、手工 smoke test。

### 9.3 Staged Transaction 约束
- v1 只允许单活跃事务，新的 `stage_transaction` 替换旧事务。
- 内存模型：命令列表 + 预览世界快照 + 轻量摘要三层。
- apply = 重放命令到主世界；discard = 销毁预览，不改主世界。
- PreviewWorld 不向主物理系统注册真实刚体。

### 9.4 线程安全
- 协议线程不直接写 `World`。只读资源来自主线程快照。退出信号用原子变量传递。

### 9.5 新系统 Runbook
接手新模块时，先读这 6 个文件再动手：
1. `src/engine/mcp/server.zig`
2. `src/engine/mcp/collaboration.zig`
3. `src/engine/core/command_queue.zig`
4. `src/editor/ai_native/collaboration.zig`
5. `src/engine/render/renderer.zig`
6. `src/engine/script/runtime.zig`

---

## 十、术语表

| 术语 | 含义 |
|------|------|
| `World` | 引擎主场景世界，ECS 容器 |
| `CommandQueue` | AI 与编辑器共享的统一写入口 |
| MCP Resource | 只读资源（不执行修改） |
| MCP Tool | 可执行动作（通过 CommandQueue） |
| Staged Transaction | 待确认的协作修改（需 apply/discard） |
| `PreviewWorld` | Staged 对应的预览世界（渲染/选中/gizmo） |
| `ScriptVM` | 脚本运行时抽象层（WasmVM 挂载于下） |
| `Jarvis` | AI 助手，通过 MCP 读写场景的「无限带宽技术美术」 |
| `Command Timeline` | 可视化的 Undo/Redo 时间线，区分人类/AI 操作 |
| `Ghost Highlight` | AI 正在操作的物体在视口中显示紫色呼吸灯轮廓 |
| `Path Tracer` | 离线路径追踪渲染器（双轨制的「离线轨」） |

---

## 十一、已完成的历史开发阶段

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

## 十二、文件索引

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

## 十三、FAQ

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

**Q: 为什么先做 CPU Path Tracer 而不是直接上 Metal RT？**
A: CPU 版本零硬件依赖、可立即开始、适合 CI golden image 测试。它先验证双轨切换的 UI 和数据流是否跑通，再用 Metal RT 替换内核提速。

**Q: AI 应该直接写 JSON 文件还是走 Command API？**
A: 走 Command API。直接写 JSON 再等 hot-reload 太慢且有竞态。AI 发结构化 Command → 引擎执行 → 同时更新内存 ECS 和持久化 JSON。Hot-reload 只作为外部文件变更的兜底。

**Q: 截图多久发一次给 AI？**
A: 不是每帧，而是 Command 完成后的稳态帧。Path Tracer 需要累积到一定 SPP 后再截图。发 512×512 分辨率即可。可同时发修改前/后对比。
