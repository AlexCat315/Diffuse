# Guava Engine AI-Native 重构执行计划

> 状态：可执行草案 v2
>
> 目标：把 Guava Engine 演进为对 AI 友好的引擎与编辑器，而不是推倒现有系统重来。
>
> 结论：**可以做，但必须基于当前代码渐进迁移，不能按“大爆炸重写”方式推进。**

---

## 一、执行摘要

这份计划的核心不是“发明一套全新的引擎”，而是把现有能力收口成 AI 可读、AI 可调、AI 可调用的统一入口。

本次重构采用以下硬决策：

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
   - Phase 4 的目标是“规范化与拆分重型二进制资产”，不是从零另起一套并行格式。

5. **Command 系统先做最小闭环**
   - 先覆盖实体创建/删除/重命名/挂父子/变换/显隐。
   - 不在第一阶段追求通用 `field_path` 级别的万能修改器。

6. **查询系统先做薄层，不先许诺完美索引**
   - 先复用现有 `World`、BVH、Physics Query。
   - `tags`、`topology_version`、`data_version` 等 schema，只有在真实落地后才进入 API。

---

## 二、当前基线

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

下列能力当前不存在，必须明确作为新增工作处理：

| 能力 | 当前状态 |
|------|----------|
| MCP Server | 不存在 |
| 引擎级写命令总线 | 不存在 |
| WASM 脚本 VM | 不存在 |
| 语义查询 API | 不存在 |
| 面向 AI 的只读快照资源 | 不存在 |
| `tags` / `topology_version` / `data_version` | 数据模型中不存在 |

---

## 三、目标架构（v1）

v1 目标不是一次性把所有 AI-native 能力做满，而是形成一个稳定闭环：

```text
AI Client
  -> MCP (stdio)
  -> Read Resources / Tools
  -> Command Queue
  -> World / ScriptRuntime / Scene IO
```

具体拆分如下：

1. **只读面**
   - 场景树快照
   - 单实体详情
   - 当前选择
   - 脚本错误与运行日志

2. **写入面**
   - 创建实体
   - 删除实体
   - 重命名实体
   - 设置父子关系
   - 设置局部/世界变换
   - 设置可见性

3. **脚本面**
   - 新增 `WasmVM`
   - 保留 `ScriptVM`
   - 热重载沿现有 `HotReloadManager` 扩展

4. **数据面**
   - 继续使用 `scene_io.zig` 的 JSON 场景格式
   - 逐步把脚本/Prefab/材质的文本表示收口成稳定 schema

---

## 四、明确不做（v1 非目标）

以下内容不应进入第一轮实现范围：

1. `SSE` / `WebSocket` 传输
2. 通用 `field_path` 反射写入器
3. 多人协作 / CRDT / OT
4. 完整的 AI prompt 模板体系
5. `tags` 驱动的复杂查询语言
6. 每类资源都新写一套平行 reader/writer
7. “100ms 内编译完成”这类过度激进的硬承诺

---

## 五、必须先修正的前提

在正式进入 AI-native 重构前，需要承认以下现实约束：

### 5.1 编译主干必须恢复为绿色

当前工作树中仍有现存编译问题，必须先修复再继续扩展，否则后续每一阶段都很难做验收。

最低要求：

1. `zig build`
2. `zig build test`

### 5.2 编辑器历史系统不能被直接替换

当前撤销/重做建立在 `src/editor/actions/command.zig` 与 `src/editor/actions/history.zig` 的 snapshot / delta 模型上。

因此迁移策略必须是：

1. 先引入引擎级 `CommandQueue`
2. 再让 editor 写操作调用 `CommandQueue`
3. 最后把历史记录挂接到命令批次

而不是先删掉旧系统。

### 5.3 `ScriptVM` 是稳定抽象，不是临时垃圾层

`src/engine/script/vm.zig` 当前已经承担“多语言 VM 抽象”职责。

因此正确方向是：

1. 保留 `ScriptVM`
2. 新增 `WasmVM`
3. 由 `ScriptRuntime` 决定选择哪个 VM

而不是删除 `vm.zig` 后重写一套并行机制。

### 5.4 版本号与标签不是现成字段

当前 `Entity` 没有：

1. `tags`
2. `topology_version`
3. `data_version`
4. 统一 `components` 容器字段

所以在这些 schema 真正进入 `World` 之前：

1. MCP 不暴露这些字段
2. Query API 不依赖这些字段
3. 文档不再把它们写成“已修复前提”

---

## 六、分周迁移计划

以下周计划按“每周都能验收”为原则编写。若某周未完成，后续周顺延，不并行硬上。

### Week 0：基线收口

**目标**
把主干编译、测试、文档口径收平。

**工作**
1. 修复当前编译阻塞。
2. 确认脚本、场景、动画、物理查询的当前真实状态。
3. 删除所有 HTTP/curl 旧叙事，只保留 MCP 方案。
4. 为本计划锁定模块命名：统一使用 `mcp/`，不再出现 `rpc/`。

**文件**
1. `docs/ai_native_restructuring.md`
2. `src/editor/actions/history.zig`
3. 其他被编译阻塞的文件

**验收**
1. `zig build`
2. `zig build test`
3. 文档中不再同时出现 MCP 与 HTTP 两套方案

---

### Week 1：只读 MCP 基座

**目标**
先让 AI 能安全读取，而不是立刻写。

**工作**
1. 新建 `src/engine/mcp/mod.zig`
2. 新建 `src/engine/mcp/protocol.zig`
3. 新建 `src/engine/mcp/server.zig`
4. 新建 `src/engine/mcp/resources/mod.zig`
5. 在 `src/main.zig` 增加 `--mcp --transport stdio`
6. 实现只读资源：
   - `scene://hierarchy`
   - `entity://{id}`
   - `selection://current`
7. 资源内容全部从现有 `World` / `scene_io` 快照构建，不虚构不存在字段

**约束**
1. 只做 `stdio`
2. 必须按 MCP 实际消息模型做 framing，不自定义“read 一次就是一条消息”
3. 先不做通知推送

**验收**
1. Claude Desktop / Cursor 能连上
2. 能列出 resources / tools
3. 能读取场景树与实体详情

---

### Week 2：引擎级 Command 最小闭环

**目标**
建立 AI 与 UI 共用的写入口。

**工作**
1. 新建 `src/engine/core/command.zig`
2. 新建 `src/engine/core/command_queue.zig`
3. 只实现最小命令集：
   - `create_entity`
   - `delete_entity`
   - `rename_entity`
   - `set_parent`
   - `set_local_transform`
   - `set_world_transform`
   - `set_visible`
4. 为变换命令加 coalescing
5. 命令执行结果返回实际 `entity_id` / 成功状态 / 错误类型

**明确不做**
1. 不做通用 `modify_component_field`
2. 不做任意组件反射序列化写入
3. 不做历史系统重写

**验收**
1. 直接调用 `CommandQueue` 可完成最小实体编辑闭环
2. 高频 gizmo/transform 写入不会无限堆积

---

### Week 3：Editor 写路径接入 Command

**目标**
让编辑器与未来 MCP 写入使用同一套入口。

**工作**
1. 先把 Inspector 的 transform 编辑接到 `CommandQueue`
2. 再把层级面板的创建/删除/重命名/挂父子接入
3. 历史系统继续沿用现有 snapshot / delta，只是在命令批次提交后记录
4. 保持现有 UX 不回退

**优先替换点**
1. `src/editor/ui/windows/inspector.zig`
2. `src/editor/ui/windows/scene_hierarchy.zig`
3. `src/editor/interaction/manipulation.zig`

**验收**
1. Inspector 改位置/旋转/缩放仍可 Undo/Redo
2. 场景层级改名/删除/创建仍可 Undo/Redo
3. Editor 与直接调用 `CommandQueue` 的结果一致

---

### Week 4：MCP 写工具

**目标**
把 Week 2 的写命令暴露成 MCP tools。

**工作**
1. 新建 `src/engine/mcp/tools/mod.zig`
2. 按最小命令集暴露 tool：
   - `create_entity`
   - `delete_entity`
   - `rename_entity`
   - `set_parent`
   - `set_transform`
   - `set_visible`
   - `get_entity`
3. tool 的实现只负责：
   - 参数校验
   - 转命令
   - 调 `CommandQueue`
   - 返回快照/结果
4. tool schema 必须只暴露当前真实存在的字段

**不做**
1. 不暴露 `tags`
2. 不暴露 `topology_version`
3. 不暴露通用 component patch

**验收**
1. AI 能通过 MCP 创建实体并立刻读回
2. AI 能通过 MCP 改变 transform 并从资源读取验证
3. 错误响应结构化

---

### Week 5：WASM 脚本作为新 VM Backend 接入

**目标**
让 AI 生成的脚本以新 VM backend 的方式进入现有脚本系统。

**工作**
1. 接入 Wasm3 到 `build.zig`
2. 新建 `src/engine/script/wasm_vm.zig`
3. 新建 `src/engine/script/wasm_compiler.zig`
4. `WasmVM` 实现现有 `ScriptVM` vtable
5. `ScriptRuntime` 增加 Wasm backend 注册与选择
6. 热重载基于现有 `src/engine/script/hot_reload.zig` 扩展，不重写一套管理器

**Host API 第一批只做**
1. 读写 transform
2. 获取 delta time
3. 日志输出
4. 播放动画
5. 生成/销毁实体（若命令队列已稳定）

**运行时约束**
1. 所有 Host 变更都写入命令缓冲，在主线程安全点 flush
2. trap / panic 转结构化错误，不允许把引擎拖死
3. v1 不要求保留复杂脚本内部状态迁移

**验收**
1. AI 提供 Zig 脚本源码可编译为 WASM 并挂到实体
2. 脚本出错后引擎主循环仍继续
3. 热重载后至少支持“重置实例并重新初始化”

---

### Week 6：文本状态与资源 schema 收口

**目标**
让 AI 读取和修改的文本数据与当前工程真实格式一致。

**工作**
1. 继续沿用 `scene_io.zig` 的 JSON v6
2. 从 `scene_io` 中提炼稳定快照结构，而不是平行再造一套 scene writer/reader
3. 梳理以下文本资源的稳定 schema：
   - Scene
   - Prefab
   - Material
   - Animation Graph（如需要）
4. 把重型二进制资产继续留在独立资源文件中

**策略**
1. 能在现有 schema 上演进，就不要另起格式
2. 新 schema 必须有版本号
3. 必须提供读回一致性测试

**验收**
1. Scene / Prefab / Material 的文本 schema 有明确版本
2. 保存 -> 读取 -> 再保存结果稳定
3. AI 可从文本资源中恢复主要语义结构

---

### Week 7：查询 API（薄层版）

**目标**
为 AI 提供低成本检索，而不是一开始就构建复杂数据库系统。

**工作**
1. 新建 `src/engine/core/query_engine.zig`
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
4. 如确有必要，再逐步引入增量索引

**明确延后**
1. `tag:` 查询
2. `health < 20` 这类脚本字段查询
3. `topology_version` 冲突控制
4. 自定义 DSL

**验收**
1. AI 可查询附近实体
2. AI 可查询带某组件的实体
3. 结果与场景真实状态一致

---

### Week 8（可选）：版本与多客户端一致性

**目标**
只有在前 7 周闭环稳定后，才处理并发与冲突。

**工作**
1. 先加 `world_revision`
2. 再评估是否需要：
   - `hierarchy_revision`
   - per-entity `topology_version`
   - per-entity `data_version`
3. 冲突检测只建立在已经真实存在的数据模型上

**验收**
1. 读写接口能返回 revision
2. 过期写入可检测并拒绝

---

## 七、模块落点

### 7.1 新增模块

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

### 7.2 重点修改模块

1. `src/main.zig`
2. `src/editor/ui/windows/inspector.zig`
3. `src/editor/ui/windows/scene_hierarchy.zig`
4. `src/editor/interaction/manipulation.zig`
5. `src/engine/script/runtime.zig`
6. `src/engine/script/hot_reload.zig`
7. `src/engine/scene/scene_io.zig`

### 7.3 明确保留

1. `src/engine/script/vm.zig`
2. `src/editor/actions/command.zig`
3. `src/editor/actions/history.zig`

保留的含义是“继续作为迁移过渡层演进”，不是永久不改。

---

## 八、风险与缓解

### 风险 1：命令系统把编辑器交互拖慢

**缓解**
1. 只对 transform 命令做 coalescing
2. 命令队列只负责收口，不做复杂反射
3. 热路径先保守替换 Inspector / Gizmo

### 风险 2：WASM 脚本 API 面过大

**缓解**
1. 第一批 Host API 严格限缩
2. 所有写操作必须走命令缓冲
3. 错误先求结构化可见，再谈复杂回溯

### 风险 3：MCP 实现与真实客户端不兼容

**缓解**
1. v1 只做 stdio
2. 严格按 MCP 协议测试
3. 不自定义简化 framing

### 风险 4：场景文本 schema 再次分叉

**缓解**
1. 统一从 `scene_io.zig` 演进
2. 新旧 schema 必须有版本与迁移测试
3. 不平行维护两套长期 scene 格式

---

## 九、每周验收清单

### Week 1
- [ ] MCP stdio 可连接
- [ ] 可读取场景树
- [ ] 可读取单实体详情

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

## 十、阶段性完成定义

只有当以下四项同时成立时，才能认为 AI-native v1 成型：

1. AI 能通过 MCP 读取场景与实体
2. AI 能通过 MCP 做基础场景编辑
3. AI 能挂载并热重载简单 WASM 脚本
4. AI 能通过查询接口验证修改结果

---

## 十一、后续扩展（v2 以后）

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

## 十二、最终建议

这次重构最重要的不是“技术上能不能做”，而是**不要把目标态文档写成当前实现说明**。

从现在开始，所有 AI-native 文档都遵守三条规则：

1. 只写当前代码真实存在的前提
2. 目标能力与迁移步骤分开写
3. 每一阶段必须能独立验收

按照本计划推进，Guava Engine 可以稳定演进成 AI-native 引擎；按旧文档那种并行重写方式推进，则大概率会在协议、脚本和数据模型三处同时返工。
