# Guava Engine AI-Native 重构执行计划

> 状态：可执行草案 v3
>
> 目标：把 Guava Engine 演进为对 AI 友好的引擎与编辑器，而不是推倒现有系统重来。
>
> 结论：**可以做，但必须基于当前代码渐进迁移，不能按“大爆炸重写”方式推进。**

---

## 一、执行摘要

这份计划要解决的，不是“再造一套新引擎”，而是把现有引擎的可读性、可编辑性和可调用性收口成一条统一通路。

从 AI 的视角看，当前问题主要有四类：

1. 场景状态不够稳定地暴露给外部程序，AI 只能通过 UI 间接感知。
2. 编辑器写路径分散，UI、历史系统、运行时各自有自己的入口。
3. 脚本系统虽然已经有 `ScriptVM` 抽象，但还没有面向新 VM backend 的清晰接入方式。
4. 查询和资源读取还停留在“引擎内部可用”，没有形成面向 AI 的稳定接口。

因此本次重构的核心方向是：

1. **协议统一为 MCP**
   - v1 只做 `stdio` 传输。
   - 文档、验收、示例全部以 MCP 为准，不再混用 HTTP/curl 叙事。

2. **沿用现有引擎核心，不平行重写**
   - 沿用 `scene/world.zig`、`scene/scene_io.zig`、`script/runtime.zig`、`script/vm.zig`。
   - 新能力以“新增模块 + 适配层”的方式接入。

3. **脚本架构保留 `ScriptVM` 抽象**
   - `vm.zig` 不删除。
   - `WasmVM` 作为新的 VM backend 接入现有脚本运行时。

4. **文本化优先复用现有 JSON**
   - 当前场景序列化已经是 JSON。
   - 后续的文本化工作是“规范化与拆分重型二进制资产”，不是从零另起一套并行格式。

5. **Command 系统先做最小闭环**
   - 先覆盖实体创建/删除/重命名/挂父子/变换/显隐。
   - 不在第一阶段追求通用 `field_path` 级别的万能修改器。

6. **查询系统先做薄层，不先许诺完美索引**
   - 先复用现有 `World`、BVH、Physics Query。
   - `tags`、`topology_version`、`data_version` 等 schema，只有在真实落地后才进入 API。

一句话概括：这是一份“把现有引擎变成 AI 能稳定读取、编辑、验证”的迁移计划，不是一份推倒重来的架构蓝图。

---

## 二、架构愿景

### 2.1 传统引擎与 AI-Native 引擎的差别

| 维度 | 传统引擎 | AI-Native Guava |
|------|----------|-----------------|
| 状态读取 | UI 面板、内部 API、私有缓存混杂 | MCP resources 作为统一读入口 |
| 状态修改 | Inspector、Hierarchy、脚本、快捷键各自写 | MCP tools + 引擎级 CommandQueue |
| 脚本运行 | 平台/语言相关，接口不统一 | `ScriptVM` 抽象保留，新 backend 逐步接入 |
| 场景数据 | 引擎内部可用，外部难复用 | 继续使用 JSON 场景格式并稳定 schema |
| 查询能力 | 多是内部遍历或特定系统查询 | 先做薄层查询 API，再逐步加索引 |
| 协议 | UI 依赖强，外部调用弱 | MCP stdio，面向 Claude Desktop / Cursor 等客户端 |

### 2.2 最终交互图

```text
AI Client
  -> MCP (stdio)
  -> Read Resources / Tools
  -> Command Queue
  -> World / ScriptRuntime / Scene IO
```

更具体地说，AI 和引擎之间需要的是三层能力：

1. **读**
   - 场景树快照
   - 单实体详情
   - 当前选择
   - 脚本错误、运行日志

2. **写**
   - 创建实体
   - 删除实体
   - 重命名实体
   - 设置父子关系
   - 设置局部/世界变换
   - 设置可见性

3. **执行**
   - 脚本生成与热重载
   - 查询验证
   - 结构化错误返回

### 2.3 交互流程示例

下面是一条更接近真实开发的交互链路：

1. AI 客户端通过 MCP `initialize` 与引擎建立连接。
2. AI 先读取 `scene://hierarchy` 和 `selection://current`，确认当前场景上下文。
3. 如果需要看具体实体，再读取 `entity://{id}`。
4. 后续写能力接入后，AI 通过 MCP tools 发送结构化命令，而不是“模拟点按钮”。
5. 修改完成后，AI 立即再次读取资源做验证。

这条链路决定了整个计划的优先级：先把“读”做稳，再把“写”做稳，最后才是更复杂的脚本和查询扩展。

### 2.4 为什么 v1 只做 stdio

stdio 是最稳的第一步，原因很直接：

1. 它最容易和现有桌面 MCP 客户端对接。
2. 它不要求我们先解决网络服务、端口管理和远程生命周期问题。
3. 它更适合先把协议层跑通，而不是在传输层分散精力。

所以 v1 不做 `SSE`、不做 `WebSocket`、不做自定义 HTTP 服务。

---

## 三、当前基线

下列能力已经存在，后续重构必须建立在这些现实基础上：

| 能力 | 当前状态 | 备注 |
|------|----------|------|
| 场景序列化 | 已存在 | `src/engine/scene/scene_io.zig`，JSON v6 |
| 物理查询 | 已存在 | `raycast / overlapAabb / sweepAabb` |
| 脚本运行时 | 已存在 | `script/runtime.zig` |
| 脚本 VM 抽象 | 已存在 | `script/vm.zig` 已支持多语言 VM 接口 |
| 热重载管理器 | 已存在 | `script/hot_reload.zig` |
| 编辑器撤销/重做 | 已存在 | 基于 snapshot / subtree delta |
| 动画图接入 Animator | 已完成 | 运行时已接入 |
| 渲染器选择历史 | 已存在 | `renderer.selectedEntity()` / `selectedEntities()` |

下列能力当前不存在，必须明确作为新增工作处理：

| 能力 | 当前状态 |
|------|----------|
| MCP Server | 不存在 |
| 引擎级写命令总线 | 不存在 |
| WASM 脚本 VM | 不存在 |
| 语义查询 API | 不存在 |
| 面向 AI 的只读快照资源 | 不存在 |
| `tags` / `topology_version` / `data_version` | 数据模型中不存在 |

这张表很重要，因为它决定了计划不能建立在“理应有这些字段”的假设上。文档里凡是写到这些能力，都必须区分为“已有”、“新建”或“后置”。

---

## 四、目标架构（v1）

v1 的目标不是一次性把所有 AI-native 能力做满，而是形成一个稳定闭环。这个闭环必须同时满足三件事：

1. AI 能读到真实场景。
2. AI 能调用安全的写入口。
3. AI 能在修改后立即读回验证。

### 4.1 资源面

先做只读资源，不急着做写工具。原因是只读面最容易验证协议是否正确，也最容易发现数据模型有没有暴露错误假设。

首批资源：

1. `scene://hierarchy`
   - 场景树快照。
   - 需要包含根节点、层级关系、实体基本属性和场景摘要。

2. `entity://{id}`
   - 单实体详情。
   - 需要包含本地/世界变换、组件摘要、层级关系、可见性、编辑器状态等。

3. `selection://current`
   - 当前选择。
   - 需要暴露主选择和完整选择列表，供 AI 和编辑器状态对齐。

### 4.2 工具面

Week 1 不需要写工具，但文档要提前定义方向。后续工具应该最终收口到引擎级 CommandQueue，而不是各模块各写一套修改逻辑。

### 4.3 脚本面

脚本系统的方向不是删掉 `ScriptVM`，而是保留抽象层并增加新的 backend：

1. `ScriptVM` 作为稳定接口保留。
2. `WasmVM` 接入现有 `ScriptRuntime`。
3. `HotReloadManager` 继续作为热重载协调层，而不是另起炉灶。

### 4.4 数据面

数据面继续以 `scene_io.zig` 的 JSON 为基础。这里要强调的是：

1. 文本化不等于重新设计一套全新的 scene 格式。
2. 先把现有格式的 schema 稳定下来，再逐步拆重型二进制资产。
3. 不要为了“看起来像 AI-native”而制造第二套长期维护的 scene reader/writer。

---

## 五、明确不做（v1 非目标）

以下内容不应进入第一轮实现范围：

1. `SSE` / `WebSocket` 传输
2. 通用 `field_path` 反射写入器
3. 多人协作 / CRDT / OT
4. 完整的 AI prompt 模板体系
5. `tags` 驱动的复杂查询语言
6. 每类资源都新写一套平行 reader/writer
7. “100ms 内编译完成”这类过度激进的硬承诺

这部分的作用不是缩小野心，而是防止第一版目标失焦。只要这些内容没有被明确延后，团队就会很容易把资源花在“看起来高级但不收口”的方向上。

---

## 六、必须先修正的前提

在正式进入 AI-native 重构前，需要承认以下现实约束。

### 6.1 编译主干必须恢复为绿色

当前工作树中的编译状态必须保持可验收。如果主干本身不稳定，后续每一阶段都只能凭感觉推进，没法建立信心。

最低要求：

1. `zig build`
2. `zig build test`

### 6.2 编辑器历史系统不能被直接替换

当前撤销/重做建立在 `src/editor/actions/command.zig` 与 `src/editor/actions/history.zig` 的 snapshot / delta 模型上。

因此迁移策略必须是：

1. 先引入引擎级 `CommandQueue`
2. 再让 editor 写操作调用 `CommandQueue`
3. 最后把历史记录挂接到命令批次

而不是先删掉旧系统。

### 6.3 `ScriptVM` 是稳定抽象，不是临时垃圾层

`src/engine/script/vm.zig` 当前已经承担“多语言 VM 抽象”职责。

因此正确方向是：

1. 保留 `ScriptVM`
2. 新增 `WasmVM`
3. 由 `ScriptRuntime` 决定选择哪个 VM

而不是删除 `vm.zig` 后重写一套并行机制。

### 6.4 版本号与标签不是现成字段

当前 `Entity` 没有：

1. `tags`
2. `topology_version`
3. `data_version`
4. 统一 `components` 容器字段

所以在这些 schema 真正进入 `World` 之前：

1. MCP 不暴露这些字段
2. Query API 不依赖这些字段
3. 文档不再把它们写成“已修复前提”

这条约束尤其重要，因为它决定了后续资源、查询和冲突检测的设计边界。

---

## 七、分阶段迁移计划

以下周计划按“每周都能验收”为原则编写。若某周未完成，后续周顺延，不并行硬上。

### Phase 0 / Week 0：基线收口

#### 目标
把主干编译、测试和文档口径收平。

#### 现状
当前工作树里已经暴露过若干编译阻塞项，所以第一周不能继续堆新功能，必须先把基线恢复成可验收状态。

#### 方案
1. 修复当前编译阻塞。
2. 确认脚本、场景、动画、物理查询的当前真实状态。
3. 删除所有 HTTP/curl 旧叙事，只保留 MCP 方案。
4. 为本计划锁定模块命名：统一使用 `mcp/`，不再出现 `rpc/`。

#### 文件
1. `docs/ai_native_restructuring.md`
2. `src/editor/actions/history.zig`
3. 其他被编译阻塞的文件

#### 验收
1. `zig build`
2. `zig build test`
3. 文档中不再同时出现 MCP 与 HTTP 两套方案

---

### Phase 1 / Week 1：只读 MCP 基座

#### 目标
先让 AI 能安全读取，而不是立刻写。

#### 现状
引擎内部已经有 `World`、`Renderer` 和 `scene_io`，但它们还没有形成面向外部客户端的稳定只读面。这里最容易出错的地方不是 JSON，而是线程边界和消息 framing。

#### 方案
1. 只做 `stdio`。
2. 按 MCP 的消息模型做 framing，不自定义“读一次就是一条消息”。
3. 资源只读，不做通知推送。
4. 协议线程不直接摸 `World` / `Renderer` 的可变状态，快照由主线程生成。
5. 首批资源固定为 `scene://hierarchy`、`entity://{id}`、`selection://current`。

#### 文件
1. `src/main.zig`
2. `src/engine/mcp/mod.zig`
3. `src/engine/mcp/protocol.zig`
4. `src/engine/mcp/server.zig`
5. `src/engine/mcp/resources/mod.zig`

#### 验收
1. Claude Desktop / Cursor 能连上。
2. 能列出 resources / tools。
3. 能读取场景树与实体详情。
4. 资源内容与当前场景真实状态一致。

---

### Phase 2 / Week 2：引擎级 Command 最小闭环

#### 目标
建立 AI 与 UI 共用的写入口。

#### 现状
编辑器里已经存在不少写操作，但它们还没有统一进入一个引擎级命令系统。AI 如果直接接到这些写操作上，只会得到一堆分散入口。

#### 方案
1. 新建 `src/engine/core/command.zig`。
2. 新建 `src/engine/core/command_queue.zig`。
3. 只实现最小命令集：
   - `create_entity`
   - `delete_entity`
   - `rename_entity`
   - `set_parent`
   - `set_local_transform`
   - `set_world_transform`
   - `set_visible`
4. 为变换命令加 coalescing。
5. 命令执行结果返回实际 `entity_id`、成功状态和错误类型。

#### 文件
1. `src/engine/core/command.zig`
2. `src/engine/core/command_queue.zig`
3. `src/engine/core/application.zig`

#### 验收
1. 直接调用 `CommandQueue` 可完成最小实体编辑闭环。
2. 高频 gizmo/transform 写入不会无限堆积。
3. 命令执行结果可用于历史系统和 MCP 写工具。

---

### Phase 3 / Week 3：Editor 写路径接入 Command

#### 目标
让编辑器与未来 MCP 写入使用同一套入口。

#### 现状
Inspector、Hierarchy、Manipulator 都已经在改 world，但它们的写逻辑并不共享统一的收口点。这会让历史记录、AI 工具和 UI 行为慢慢分叉。

#### 方案
1. 先把 Inspector 的 transform 编辑接到 `CommandQueue`。
2. 再把层级面板的创建/删除/重命名/挂父子接入。
3. 历史系统继续沿用现有 snapshot / delta，只是在命令批次提交后记录。
4. 保持现有 UX 不回退。

#### 文件
1. `src/editor/ui/windows/inspector.zig`
2. `src/editor/ui/windows/scene_hierarchy.zig`
3. `src/editor/interaction/manipulation.zig`
4. `src/editor/actions/history.zig`

#### 验收
1. Inspector 改位置/旋转/缩放仍可 Undo/Redo。
2. 场景层级改名/删除/创建仍可 Undo/Redo。
3. Editor 与直接调用 `CommandQueue` 的结果一致。

---

### Phase 4 / Week 4：MCP 写工具

#### 目标
把 Week 2 的写命令暴露成 MCP tools。

#### 现状
只读资源已经足够让 AI 理解场景，但没有写工具就无法完成闭环。这里的重点不是“工具数量多”，而是“工具语义稳定且可验证”。

#### 方案
1. 新建 `src/engine/mcp/tools/mod.zig`。
2. 按最小命令集暴露 tool：
   - `create_entity`
   - `delete_entity`
   - `rename_entity`
   - `set_parent`
   - `set_transform`
   - `set_visible`
   - `get_entity`
3. tool 的实现只负责参数校验、转命令、调 `CommandQueue`、返回快照/结果。
4. tool schema 必须只暴露当前真实存在的字段。

#### 文件
1. `src/engine/mcp/tools/mod.zig`
2. `src/engine/mcp/server.zig`
3. `src/engine/core/command_queue.zig`

#### 验收
1. AI 能通过 MCP 创建实体并立刻读回。
2. AI 能通过 MCP 改变 transform 并从资源读取验证。
3. 错误响应结构化。

---

### Phase 5 / Week 5：WASM 脚本作为新 VM Backend 接入

#### 目标
让 AI 生成的脚本以新 VM backend 的方式进入现有脚本系统。

#### 现状
`ScriptVM` 已经是稳定抽象，热重载也已经存在。这里不应该推倒重来，而应该增加一个新的 backend，把它挂到现有框架上。

#### 方案
1. 接入 Wasm3 到 `build.zig`。
2. 新建 `src/engine/script/wasm_vm.zig`。
3. 新建 `src/engine/script/wasm_compiler.zig`。
4. `WasmVM` 实现现有 `ScriptVM` vtable。
5. `ScriptRuntime` 增加 Wasm backend 注册与选择。
6. 热重载基于现有 `src/engine/script/hot_reload.zig` 扩展，不重写一套管理器。

#### 文件
1. `build.zig`
2. `src/engine/script/wasm_vm.zig`
3. `src/engine/script/wasm_compiler.zig`
4. `src/engine/script/runtime.zig`
5. `src/engine/script/hot_reload.zig`

#### 验收
1. AI 提供 Zig 脚本源码可编译为 WASM 并挂到实体。
2. 脚本出错后引擎主循环仍继续。
3. 热重载后至少支持“重置实例并重新初始化”。

---

### Phase 6 / Week 6：文本状态与资源 schema 收口

#### 目标
让 AI 读取和修改的文本数据与当前工程真实格式一致。

#### 现状
`scene_io.zig` 已经在用 JSON，但周边还没有形成稳定的面向 AI 的 schema 分层。这里应当做收口，而不是新开格式战场。

#### 方案
1. 继续沿用 `scene_io.zig` 的 JSON v6。
2. 从 `scene_io` 中提炼稳定快照结构，而不是平行再造一套 scene writer/reader。
3. 梳理以下文本资源的稳定 schema：
   - Scene
   - Prefab
   - Material
   - Animation Graph（如需要）
4. 把重型二进制资产继续留在独立资源文件中。

#### 文件
1. `src/engine/scene/scene_io.zig`
2. `src/engine/scene/prefab.zig`
3. `src/engine/assets/*`

#### 验收
1. Scene / Prefab / Material 的文本 schema 有明确版本。
2. 保存 -> 读取 -> 再保存结果稳定。
3. AI 可从文本资源中恢复主要语义结构。

---

### Phase 7 / Week 7：查询 API（薄层版）

#### 目标
为 AI 提供低成本检索，而不是一开始就构建复杂数据库系统。

#### 现状
引擎已经能做一些内部查询，但这还不是一个对外稳定的查询层。第一版应该先沿用现有数据和空间索引，尽量少引入新概念。

#### 方案
1. 新建 `src/engine/core/query_engine.zig`。
2. 第一版直接复用现有数据：
   - `World.entities`
   - `worldTransformConst`
   - 现有 BVH / spatial index
   - 现有 physics queries
3. 支持的过滤：
   - `id`
   - `name_contains`
   - `has_component`
   - `parent_id`
   - `visible`
   - 半径空间过滤
4. 如确有必要，再逐步引入增量索引。

#### 文件
1. `src/engine/core/query_engine.zig`
2. `src/engine/scene/world.zig`
3. `src/engine/physics/system.zig`

#### 验收
1. AI 可查询附近实体。
2. AI 可查询带某组件的实体。
3. 结果与场景真实状态一致。

---

### Phase 8 / Week 8（可选）：版本与多客户端一致性

#### 目标
只有在前 7 周闭环稳定后，才处理并发与冲突。

#### 现状
版本号、标签和多客户端冲突控制并不是当前数据模型里已经存在的基础设施。它们应该是“在读写闭环稳定后再加”的能力，而不是先验假设。

#### 方案
1. 先加 `world_revision`。
2. 再评估是否需要：
   - `hierarchy_revision`
   - per-entity `topology_version`
   - per-entity `data_version`
3. 冲突检测只建立在已经真实存在的数据模型上。

#### 文件
1. `src/engine/scene/world.zig`
2. `src/engine/core/query_engine.zig`
3. `src/engine/core/command_queue.zig`

#### 验收
1. 读写接口能返回 revision。
2. 过期写入可检测并拒绝。

---

## 八、模块落点

### 8.1 新增模块

1. `src/engine/core/command.zig`
2. `src/engine/core/command_queue.zig`
3. `src/engine/core/query_engine.zig`
4. `src/engine/mcp/mod.zig`
5. `src/engine/mcp/protocol.zig`
6. `src/engine/mcp/server.zig`
7. `src/engine/mcp/resources/mod.zig`
8. `src/engine/mcp/tools/mod.zig`
9. `src/engine/script/wasm_vm.zig`
10. `src/engine/script/wasm_compiler.zig`

### 8.2 重点修改模块

1. `src/main.zig`
2. `src/editor/ui/windows/inspector.zig`
3. `src/editor/ui/windows/scene_hierarchy.zig`
4. `src/editor/interaction/manipulation.zig`
5. `src/engine/script/runtime.zig`
6. `src/engine/script/hot_reload.zig`
7. `src/engine/scene/scene_io.zig`

### 8.3 明确保留

1. `src/engine/script/vm.zig`
2. `src/editor/actions/command.zig`
3. `src/editor/actions/history.zig`

保留的含义是“继续作为迁移过渡层演进”，不是永久不改。

---

## 九、实现顺序与依赖

这一节不是简单重复周计划，而是把依赖关系单独拎出来，避免执行时把顺序打乱。

### 9.1 最小依赖链

```text
World / Renderer / scene_io
  -> MCP resources snapshot
  -> MCP stdio server

World / CommandQueue
  -> Editor write path
  -> MCP tools

ScriptVM
  -> WasmVM backend
  -> ScriptRuntime integration
```

### 9.2 必须先后顺序

1. 先做 Week 0，保证主干可编译、可测试。
2. 再做 Week 1，只读 MCP 基座。
3. 再做 Week 2，统一写入口到 CommandQueue。
4. 再做 Week 3，把 Editor 写路径迁过来。
5. 再做 Week 4，把 CommandQueue 暴露成 MCP tools。
6. 再做 Week 5，把 WASM 作为新 VM backend 接入。
7. 再做 Week 6 和 Week 7，补文本 schema 与查询层。
8. 最后才考虑 Week 8 的 revision / 多客户端一致性。

### 9.3 依赖说明

1. `MCP resources` 依赖 `World` 的只读快照，不依赖写工具。
2. `MCP tools` 依赖 `CommandQueue`，但不依赖 WASM。
3. `WasmVM` 依赖 `ScriptVM` 抽象，但不依赖 MCP。
4. `Query API` 依赖现有 `World` 和空间索引，不依赖 MCP tools。
5. `revision` 依赖读写闭环跑通，不应提前进入第一轮。

---

## 十、工作流与验证

### 10.1 日常开发流程

推荐的开发顺序是：

1. 先改最小模块。
2. 跑对应单测。
3. 跑相关集成验证。
4. 再跑全量 `zig build` / `zig build test`。

不要一边改 MCP 协议，一边大面积改 Editor UI 和脚本系统。这样会让问题来源不可分辨。

### 10.2 验证方式

每个阶段都至少保留三种验证：

1. 编译验证。
2. 单元测试或定向测试。
3. 手工 smoke test。

对 Week 1 来说，smoke test 就是：

1. 启动 `--mcp --transport stdio`。
2. 用 MCP 客户端 `initialize`。
3. `resources/list`。
4. `resources/read`。
5. 确认返回值和场景状态一致。

对 Week 2 和 Week 4 来说，smoke test 就是：

1. 创建实体。
2. 修改变换。
3. 读回验证。
4. 撤销或重新读取，确认结果可解释。

### 10.3 推荐的验收节奏

1. 每周先跑局部测试。
2. 再跑相关模块测试。
3. 最后跑全量构建。
4. 只要全量验证失败，就不要宣布该周完成。

---

## 十一、安全边界

### 11.1 协议边界

1. MCP server v1 只做 stdio。
2. stdout 只给 MCP 协议消息，不混普通日志。
3. 普通日志继续走 stderr 和日志文件。

### 11.2 线程边界

1. 协议线程不直接写 `World`。
2. 只读资源来自主线程快照。
3. 退出信号用原子变量传递，不靠隐式线程退出。

### 11.3 数据边界

1. 不在 MCP schema 中伪造不存在字段。
2. 不把实验性字段写成正式契约。
3. 不在第一版暴露 `tags`、`topology_version`、`data_version`。

### 11.4 运行时边界

1. `ScriptVM` 保留，`WasmVM` 作为 backend 接入。
2. Host 写操作必须回到主线程安全点。
3. trap / panic 必须结构化返回，不能把引擎拖死。

---

## 十二、FAQ

### 12.1 为什么不先做 HTTP 服务？

因为 v1 的目标是让现有桌面 MCP 客户端稳定接入，而不是先建一套网络栈。stdio 更直接、更容易验证，也更符合当前迁移的节奏。

### 12.2 为什么不删 `vm.zig`？

因为它已经是稳定抽象。现在正确的方向不是拆掉它，而是把新的执行后端接进来。删掉抽象层只会把现有脚本系统和热重载一起打散。

### 12.3 为什么不先上 `tags` / `topology_version` / `data_version`？

因为这些字段还不是当前数据模型里的真实基础设施。先把它们写进文档，只会让实现和契约脱节。应该等读写闭环稳定后，再决定是否需要这些字段。

### 12.4 为什么资源要做快照，而不是让 MCP server 直接读 `World`？

因为协议线程和主线程的职责不同。直接跨线程摸可变状态会把线程安全问题带进协议层。快照虽然多一层，但边界清晰，后续调试也更可控。

### 12.5 为什么 Week 1 不做写工具？

因为写工具一旦上来，协议、命令队列、历史系统和 UI 迁移会同时进入同一轮调试，问题会很难分离。先把读打通，能明显降低风险。

---

## 十三、附录

### 13.1 首批 MCP 资源约定

1. `scene://hierarchy`
2. `entity://{id}`
3. `selection://current`

### 13.2 首批 MCP tools 约定

Week 1 不暴露写工具。Week 4 之后才逐步开放：

1. `create_entity`
2. `delete_entity`
3. `rename_entity`
4. `set_parent`
5. `set_transform`
6. `set_visible`
7. `get_entity`

### 13.3 关键文件清单

1. `src/main.zig`
2. `src/engine/mcp/*`
3. `src/engine/core/command*`
4. `src/editor/ui/windows/inspector.zig`
5. `src/editor/ui/windows/scene_hierarchy.zig`
6. `src/engine/script/runtime.zig`
7. `src/engine/script/hot_reload.zig`
8. `src/engine/scene/scene_io.zig`

### 13.4 最终判断标准

当 AI 能通过 MCP 完成“读场景 -> 改实体 -> 读回验证 -> 运行脚本 -> 再验证”这个闭环时，才说明这份计划进入了真正的可用阶段。

---

## 十四、风险与缓解

### 风险 1：命令系统把编辑器交互拖慢

**缓解**
1. 只对 transform 命令做 coalescing。
2. 命令队列只负责收口，不做复杂反射。
3. 热路径先保守替换 Inspector / Gizmo。

### 风险 2：WASM 脚本 API 面过大

**缓解**
1. 第一批 Host API 严格限缩。
2. 所有写操作必须走命令缓冲。
3. 错误先求结构化可见，再谈复杂回溯。

### 风险 3：MCP 实现与真实客户端不兼容

**缓解**
1. v1 只做 stdio。
2. 严格按 MCP 协议测试。
3. 不自定义简化 framing。

### 风险 4：场景文本 schema 再次分叉

**缓解**
1. 统一从 `scene_io.zig` 演进。
2. 新旧 schema 必须有版本与迁移测试。
3. 不平行维护两套长期 scene 格式。

### 风险 5：后台协议线程与主线程状态冲突

**缓解**
1. MCP server 只读快照，不直接碰 `World` 的可变状态。
2. 快照由主线程在安全点更新。
3. 退出路径用原子标记收敛，不让线程生命周期阻塞主循环。

---

## 十五、每周验收清单

### Week 1
- [ ] MCP stdio 可连接
- [ ] 可读取场景树
- [ ] 可读取单实体详情
- [ ] 可读取当前选择

### Week 2
- [ ] 命令队列可执行最小实体编辑命令
- [ ] transform 命令具备合并能力

### Week 3
- [ ] Inspector 变换走命令队列
- [ ] Scene Hierarchy 基础写操作走命令队列
- [ ] Undo/Redo 不回退

### Week 4
- [ ] MCP tools 可写场景
- [ ] 写后可立即读回验证

### Week 5
- [ ] WasmVM 作为新 backend 接入 ScriptRuntime
- [ ] 编译错误与运行时错误可结构化上报

### Week 6
- [ ] Scene / Prefab / Material 文本 schema 有稳定版本
- [ ] 读写一致性测试通过

### Week 7
- [ ] Query API 支持基础过滤与空间查询
- [ ] 查询结果与场景状态一致

---

## 十六、阶段性完成定义

只有当以下四项同时成立时，才能认为 AI-native v1 成型：

1. AI 能通过 MCP 读取场景与实体。
2. AI 能通过 MCP 做基础场景编辑。
3. AI 能挂载并热重载简单 WASM 脚本。
4. AI 能通过查询接口验证修改结果。

如果这四条里有任何一条还不成立，就不要把 v1 说成已经完成。这样做不是保守，而是避免把“演示可用”误判成“工程稳定”。

---

## 十七、后续扩展（v2 以后）

以下内容留到 v2 之后：

1. `SSE` / `WebSocket`
2. 推送通知
3. 资源依赖图与资产查询
4. `tags`
5. 多客户端冲突控制
6. CRDT / OT
7. 更完整的脚本 source map / backtrace
8. Blend Tree / AI 动画 authoring tools 的 MCP 暴露

---

## 十八、最终建议

这份计划可以做，前提是始终守住三个边界：

1. 先把读通路做稳，再做写通路。
2. 先挂到现有抽象上，再考虑替换抽象。
3. 先把真实存在的数据模型暴露出去，再谈更复杂的 schema 和查询。

如果按这个节奏推进，Guava Engine 的 AI-native 化是可落地的；如果跳过这些边界，文档会再次变成“看起来很完整，但执行起来到处打架”的方案。
