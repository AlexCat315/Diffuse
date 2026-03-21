# Guava Engine: AI-Native 游戏引擎总体开发规划 (Master Plan)

> **版本状态**: 2026-03-21 最新快照整合版
> **文档说明**: 本文档由原《Guava Engine 开发计划》与《AI-Native 重构执行计划》深度整合而成。它既定义了引擎缺失的“游戏躯干”功能，也确立了“AI-Native 大脑”的架构标准与开发纪律。

---

## 一、 项目愿景与执行摘要

Guava Engine 是一个基于 Zig 语言开发的现代游戏引擎。它的核心愿景不仅仅是成为一个“图形渲染器 + 物理沙盒”，而是要演进为业界领先的 **AI-Native 游戏引擎**。

在传统引擎中，AI 只是外挂的“代码生成器”；而在 Guava Engine 中，AI 将具备：
1. **场景感知能力**：能通过 MCP 协议直接“看懂” 3D 世界和实体关系。
2. **安全修改闭环**：AI 的修改进入预览沙盒（Staged Transaction），由人类审查通过后再应用。
3. **即时反馈机制**：通过高度集成的 WASM 虚拟机实现毫秒级代码热重载与结构化错误自愈。

当前，Guava 的**“AI 大脑与基础设施”已基本建设完成**，但**“游戏躯干”功能严重缺失**。接下来的核心任务是：**严格遵循 AI-Native 的架构标准，补齐让引擎能真正“做游戏”的核心系统。**

---

## 二、 当前开发状态快照 (2026-03-21 基线)

在推进后续开发前，必须明确当前代码库已具备的真实能力：

### 1. AI-Native 基础设施 (✅ 已落地)
*   **MCP 协议基座**: 基于 `stdio` 的 MCP Server 稳定运行。
*   **场景只读感知**: `scene://hierarchy`, `entity://{id}`, `selection://current` 等资源快照可用。
*   **引擎级写入闭环**: 实现了基于 `CommandQueue` 的统一写入口（包含实体创建、变换、父子层级等）。Editor 与 AI 共享此总线。
*   **安全协作预览**: 实现了 Staged Transaction 机制与同视口 HDR 第二世界着色预览（Ghost Pass）。支持 Gizmo 直接调整预览实体。
*   **WASM 脚本闭环**: 接入 WAMR，支持 Zig 编译到 WASM 并热重载。打通了 Guest 侧 `panic` 结构化回传与源码位置映射。
*   **查询与反射**: 实现了分页/过滤的薄层 `query_entities` API，以及数据驱动的 Inspector 编译期反射。

### 2. 核心与渲染系统 (✅ 高完成度)
*   **渲染管线 (95%)**: PBR 渲染、RenderGraph 架构、级联阴影、IBL。后处理已全面补齐（SSAO, SSR, TAA, DOF, Bloom）。
*   **物理系统 (80%)**: Jolt Physics 集成，支持刚体、碰撞体、固定步长更新。
*   **动画系统 (60%)**: 骨骼动画导入、GPU 蒙皮、BlendTree 基础实现、动画图（Animation Graph）及编辑器接入完成。
*   **底层重构**: ECS 正向 `SparseSet(T)` 容器迁移（Transform/Rigidbody 等已迁移进入混合期）。

---

## 三、 致命功能缺失 (The "Missing Limbs")

以下是 Guava 真正成为“游戏引擎”所**必须立即补齐**的核心模块。**这些模块的开发必须严格遵循第五节的 AI-Native 契约。**

### 1. 音频系统 (Audio System) - **完成度: 0%** 🔴
*   **缺失**: 无音频后端，无空间音效，无音量混合。
*   **方案**: 集成 OpenAL-soft 或 SoLoud。
*   **AI-Native 要求**: 
    *   提供 `audio://mixer-status` 资源供 AI 读取。
    *   WASM 层暴露 `AudioSource.play()` 等 API。

### 2. 游戏内 UI 系统 (Game UI/Canvas) - **完成度: 5%** 🔴
*   **缺失**: 只有编辑器 ImGui，游戏运行时无 Canvas、无按钮/血条、无字体渲染机制。
*   **方案**: 实现轻量级顶点缓存 UI 系统，集成 stb_truetype。
*   **AI-Native 要求**: AI 必须能通过指令生成并排版运行时 UI 组件。

### 3. 场景管理与加载流 (Scene Management) - **完成度: 20%** 🔴
*   **缺失**: 无场景切换 API (`load("level_2")`)，无异步加载，无跨场景持久化对象。
*   **AI-Native 要求**: WASM 层暴露场景生命周期控制接口。

### 4. 游戏生命周期与循环 (Game State) - **完成度: 0%** 🔴
*   **缺失**: 缺少明确的 Play/Pause/Stop 状态机，无时间缩放（Time Scale）。

---

## 四、 架构与玩法系统缺失 (Gameplay & Architecture Gaps)

这些缺失限制了引擎的性能上限和玩法复杂度：

### 1. 交互与物理玩法 (🟡 优先补齐)
*   **物理查询 API**: 虽然底层有 Jolt，但 WASM 脚本层缺少完善的 `Raycast` 和 `OverlapSphere` 接口，无法实现开枪、检测等逻辑。
*   **动画事件**: 无法在动画关键帧触发脚本回调（如攻击动作生效瞬间）。
*   **导航寻路 (0%)**: 缺少 NavMesh 烘焙与自动避障代理（建议集成 Recast/Detour）。

### 2. 底层架构 (🟡 后续演进)
*   **资源分发打包 (Asset Cooking)**: 目前直接读 JSON/GLTF，缺少将其打包为紧凑二进制格式（如 `.pak`）的构建流，导致游戏无法正式发布。
*   **多线程任务调度 (Job System)**: 缺乏面向游戏逻辑的通用多核并行框架。
*   **网络同步 (0%)**: 没有 ENet/WebRTC 封装，无多人游戏能力。

---

## 五、 AI-Native 核心架构标准与开发纪律

在补齐上述功能（如开发音频或 UI）时，**绝不允许按照传统引擎的思路硬写**。每一行新系统的代码都必须服从以下准则：

### 1. 读写必须分离且结构化 (The MCP Contract)
*   **读 (Resource)**: 新系统的状态必须可被抓取为静态快照，通过 MCP Resource 暴露（如 `schema://components` 必须更新新组件的字段）。
*   **写 (Command)**: 所有对场景状态的修改（如新建 UI 节点）必须通过引擎级的 `CommandQueue` 进行，绝不允许越过总线直接改内存。

### 2. 必须支持安全隔离预览 (Staged Transaction)
*   任何修改指令必须能够运行在 `PreviewWorld` 快照中。
*   在 `apply` 之前，主世界数据绝对不可被污染。新写的系统（例如物理碰撞）在 Preview 模式下应采取静默策略，避免触发真实副作用。

### 3. 脚本 API 设计的“沙盒隔离”
*   `ScriptVM` 抽象已稳定。暴露给 WASM 虚拟机的新 API（如物理查询、播放声音）必须具有严格的安全边界。
*   Host 端捕获陷阱，Guest 端必须承担 Panic 定位与回传的责任。

### 4. 数据格式稳定第一
*   场景序列化继续沿用 JSON v6。添加新组件时，更新对应的 Schema，不要另起炉灶搞“新版二进制格式”扰乱当前 AI 的解析能力。

---

## 六、 内核重构下一阶段路线 (v1 之后的探索)

在游戏基础功能跑通且 AI 协作稳定后，基础架构的演进方向将参考 Bevy 模式：

1. **全面数据导向 ECS (SparseSet 推进)**
   *   当前已实现通用 `SparseSet(T)`，完成 `Transform`, `Rigidbody`, `Collider` 的迁移。
   *   未来将继续把冷热数据分离，等 Query/Physics 跑稳后，再评估是否向 Archetype 模型推进。
2. **Plugin 与 Headless 解耦 (App Shell 拆分)**
   *   当前 `Application` 耦合过重。
   *   **目标**: 拆分为 `CorePlugin`, `PhysicsPlugin`, `ScriptPlugin`, `RenderPlugin` 等。
   *   **最终形态**: 实现纯正的 Headless Profile，允许 AI 在后台静默运行物理/脚本沙盒 5000 帧以验证逻辑，而无需初始化任何渲染和窗口组件。

---

## 七、 推荐执行路线图 (Action Plan)

**阶段一：补全生命线 (Vital Organs)**
1. **音频系统集成**（打通声音）
2. **暴露物理查询 API 到 WASM**（打通逻辑感知）
3. **实现 GameState 与场景生命周期**（打通游戏循环）

**阶段二：交互与表现 (Sensory & Feedback)**
1. **游戏内 2D UI 系统**
2. **动画事件系统**
3. **导航寻路接入**

**阶段三：架构与分发 (Architecture & Release)**
1. **Application Headless 插件化重构**
2. **资源打包 Asset Cooking 系统**
3. **性能分析器集成**

> **最终判准**：当你能对 AI 说：“帮我创建一个带有 UI 血条和音效的主角，当点击鼠标时通过射线检测开火，并打包发布。”且 AI 能在无崩溃的反馈循环中完成这一切时，Guava Engine 才算达到了真正的完全体。