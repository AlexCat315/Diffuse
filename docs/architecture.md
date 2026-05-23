# Guava AI 原生游戏引擎架构

> 本文档是所有 AI 相关设计的总纲。其他文档描述具体模块实现，以本文档为基准。

---

## 核心命题

传统引擎的 AI 集成模型是翻译架构：引擎有固定 API，AI 把自然语言翻译成 API 调用。这不是 AI 原生。

Guava 的根本命题是：

> **创作意图、世界状态、运行时执行、AI 理解——不是四层，是同一件事的四个视角。**

具体含义：

- 人类作者和 AI 使用完全相同的世界变更原语，不存在"AI API"
- AI 不翻译人类意图，AI 理解世界状态并在其中共同创作
- 每一次交互（人类或 AI 发起）都是学习信号，不需要单独的数据收集
- 世界是持续维护的语义图，不是按需生成的序列化快照

---

## 五个核心概念

### 1. World

World 是唯一的真相来源。它不是 ECS 运行时加上一层文档层，也不是快照的集合——它是一个持续维护的语义图。

**结构：**

```
World
├── Entities
│   ├── id: StableID           // 跨重命名、重导入稳定
│   ├── role: SemanticRole     // "point_light" "hero_character" "collision_trigger"
│   ├── authored: Properties   // 作者设置的值，永久
│   ├── evaluated: Properties  // 引擎求值结果，时态相关
│   ├── inferred: Properties   // AI 推断，标记 confidence + source，可被 authored 覆盖
│   └── relationships: [Relationship]  // 一等公民，有向语义边
│       // "illuminates" "controls" "depends_on" "animates" "overrides"
├── Timeline                   // Shot / Clip / Track，World 的时间轴层
├── Assets                     // 资产语义理解，内嵌，不是外挂文档
│   └── semantic: AssetSemantic  // 由语义生产流水线填充，见 ai-native-semantic-pipeline-design.md
└── History: [Edit]            // 所有变更的完整记录
```

**关键约束：**

- ECS（SceneRuntime）是 World 的**运行时执行后端**，不是 World 的定义
- World 不存在"AI 可见副本"，Session 订阅 World 的变更流，获取 delta
- `authored` 层是永久真相，`inferred` 层不能覆盖 `authored` 层

**World 变更流：**

每次 World 发生变化，产出 `WorldEvent`：

```
WorldEvent
├── entity.authored_changed(id, property, before, after)
├── entity.evaluated_changed(id, property)
├── entity.inferred_updated(id, property, confidence)
├── relationship.added / removed
├── asset.semantic_updated(asset_id)
├── timeline.changed(shot_id)
└── edit.applied(edit_id)
```

这是 Observation Bus 的事件模式，见 `ai-native-observation-bus-design.md`。

---

### 2. Session

Session 是 AI 在 World 中的持续存在。它不是请求处理器，是有状态的共同创作者。

**每个项目一个 Session，跨编辑器重启持久。**

```
Session
├── WorldView                  // World 变更流的压缩理解，增量维护
│   ├── entity_index           // 实体语义角色、关系的快速查询
│   ├── recent_edits           // 近期所有变更，含人类编辑
│   └── active_context         // 当前焦点：选中实体、工作流阶段、未解决问题
├── ConversationHistory        // 跨请求，不随请求重置
├── WorkflowContext            // 当前是游戏关卡编辑、影视场景、角色绑定……
└── process(signal: Signal) → [Proposal]
```

Session 接收的输入是 **Signal**（见下），产出的是 **Proposal**（见下）。

Session 不区分"NL 路径"和"规划器路径"——所有输入走同一个推理过程，根据 WorldView 和 ConversationHistory 生成回应。

---

### 3. Signal

Signal 是所有输入模态的统一表示。不存在针对不同输入的独立管道。

```
Signal
├── NaturalLanguage(text: String, locale: Locale)
├── DirectManipulation(entity: StableID, delta: PropertyDelta)
├── ReferenceImage(image: ImageData, intent: String?)
├── CodeChange(file: Path, diff: Diff)
├── SelectionChanged(entities: [StableID])
├── WorldEvent(event: WorldEvent)          // 引擎内部状态变化也是 Signal
└── UserCorrection(                        // 最有价值的 Signal
        proposed: Proposal,
        actual: WorldDelta,                // 用户实际做了什么
        accepted_steps: [StepID]           // 接受了哪些步骤
    )
```

`UserCorrection` 是当前所有系统中完全缺失但最重要的数据：**AI 提议 A，用户改成 B——这个 delta 才是真正的训练信号**。

---

### 4. Proposal

Proposal 是任何作者（人类或 AI）对 World 的变更意图。人类直接操作产生的 Proposal 与 AI 生成的 Proposal 使用完全相同的结构。

```
Proposal
├── id: ProposalID
├── author: Human | AI(session_id)
├── semantic_intent: String         // 自然语言描述意图，用于 CorrectionSignal
├── steps: [WorldDelta]             // 有序的原子变更步骤
├── reasoning: String?              // AI 的推理链，调试和训练用
├── confidence: Double
└── approval_policy: Automatic | RequiresApproval | Forbidden
```

**Proposal 的生命周期：**

```
Proposal
    │
    ▼ Validation（约束检查）
    │  ├── 实体是否存在
    │  ├── 作用域是否合法（authored vs. evaluated vs. inferred）
    │  └── 是否有破坏性风险
    │
    ▼ StagedWorld（Ghost World 预览）
    │  现有 StagedTransactionStore 机制保留
    │
    ▼ Confirmation（用户决策）
    │  ├── accept  → Edit（应用）
    │  ├── reject  → UserCorrection(proposed, actual=nil) → Session.learn()
    │  └── modify  → Edit(actual_delta) + UserCorrection(proposed, actual_delta)
    │
    ▼ Edit（已应用，见下）
```

---

### 5. Edit

Edit 是已应用到 World 的变更，是 World History 的基本单元，也是系统的训练数据。

**不存在单独的 IntentTrainingLogger。Edit 本身就是训练数据。**

```
Edit
├── id: EditID
├── world_delta: WorldDelta             // 实际发生了什么
├── provenance
│   ├── author: Human | AI(session_id)
│   ├── timestamp: Date
│   ├── from_proposal: Proposal?        // 来自哪个 Proposal
│   └── correction_delta: WorldDelta?   // 用户在 AI 提议上改了什么
├── world_revision_before: UInt64
└── world_revision_after: UInt64
```

每次 Edit 应用后：
1. World 更新状态
2. World 发出 `WorldEvent.edit.applied`
3. Session 收到事件，增量更新 WorldView
4. 如果存在 `correction_delta`，Session 执行学习更新

---

## 完整数据流

```
用户输入（任意模态）
        │
        ▼
Session.process(Signal)
        │
        ├── 查询 WorldView（了解当前状态）
        ├── 检索 ConversationHistory（了解上下文）
        ├── 结合 WorkflowContext（理解工作阶段）
        └── 生成 Proposal[]
                │
                ▼
        Validation（约束检查，不需要 CapabilityGraph 路由）
                │
                ▼
        StagedWorld（视口预览）
                │
                ▼
        用户 Confirmation
        ├── accept ──────────────────────────── World.apply(proposal.steps)
        │                                              │
        │                                         Edit { correction_delta: nil }
        │                                              │
        │                                         Session.update(edit)
        │
        ├── reject ──── UserCorrection(proposed, actual=nil) → Session.learn()
        │
        └── modify ─── World.apply(actual_delta)
                               │
                          Edit { correction_delta: actual_delta - proposed_delta }
                               │
                          Session.learn(UserCorrection)  ← 最重要的学习信号
```

---

## 与现有实现的对应关系

### 保留（语义不变或微调）

| 现有实现 | 新角色 |
|---------|--------|
| `TransactionIR` | WorldDelta（rename，保留语义） |
| `StagedTransactionStore` | StagedWorld（保留机制） |
| `TransactionExecutor` | World.apply() 的执行后端 |
| `ObservationBus` | World 变更流（reposition，见 `ai-native-observation-bus-design.md`） |
| `SceneEditPlanExecutor` | Proposal → WorldDelta 的转换（保留机制，扩展范围） |
| Confirmation 流程 | 保留 UI，重新定义为学习协议 |

### 删除（被新架构取代）

| 现有实现 | 原因 |
|---------|------|
| `LocalIntentClassifier` | Session 处理所有推理，词袋分类器不是正确单元 |
| `CapabilityRegistry` 作为路由 | Validation 层负责约束，不需要路由注册表 |
| `AnthropicIntentResolverBackend` | Session 统一处理，不存在单独的 NL 后端 |
| `SceneSemanticSnapshot` | Session 通过 WorldView 增量理解，不需要全量快照 |
| `IntentTrainingLogger` | Edit.provenance + UserCorrection 是真正的训练数据 |
| NL 两路分叉（planner vs. cascade） | Session 统一入口 |
| `NaturalLanguageIntentResolver` | Session 内部推理 |

### 演进（保留概念，改变定位）

| 现有设计 | 新定位 |
|---------|--------|
| `SceneDocument` | World 的 authored 层，不是单独文档对象 |
| `ModelDocument` | World 的 Asset.semantic，不是外挂文档 |
| `ModelSemanticSummary` | World Entity 的 inferred 层，由语义生产流水线填充 |
| `Context Memory Index` | Session.WorldView 的内部状态，不是独立系统 |
| `CapabilityGraph` | Validation 层的约束来源，不是路由机制 |

---

## 实现路径

严格按顺序，不破坏现有功能：

### Phase 1：插桩 ✅

`TransactionExecutor.apply()` 现在产出 `Edit` 并写入 `<project>/.guava/edit_log.jsonl`：

```
Engine/Sources/IntentRuntime/
  Edit.swift          — WorldRevisionSnapshot, EditAuthorKind, EditProvenance, Edit
  TransactionExecutor — apply() 构造 Edit，附到 TransactionApplyResult.edit

Editor/Sources/EditorCore/AI/
  EditLog.swift       — 追加写 JSONL，线程安全
  EditorCore          — applyInvocationResult() 写 edit_log
```

### Phase 2：建 Session ✅

`Session` 是 AI 的有状态参与者，替代 `AIScenePlanner` + 级联路由作为主路径：

```
Engine/Sources/AIRuntime/
  Signal.swift              — 统一输入模态枚举
  WorldView.swift           — Session 对 World 的增量理解（Phase 2 仍基于 snapshot）
  ConversationTurn.swift    — 多轮历史记录
  Proposal.swift            — Session 产出，携带 SceneEditPlan + 元数据
  SessionBackend.swift      — 协议：generateProposal(signal:worldView:history:sessionID:)
  Session.swift             — Actor：维护 WorldView，调用 backend，记录 history
  AnthropicEditPlanTool.swift — 共享工具 schema（原 AIScenePlanner 私有，现在共用）

Editor/Sources/EditorCore/AI/
  AnthropicSessionBackend.swift — 实现 SessionBackend，比 AIScenePlanner 上下文更丰富
  EditorCore                    — Session 作为主 NL 路径；edit 应用后回传 observe()
```

**并行运行策略**：有 API Key 时 Session 优先；AIScenePlanner 和级联路由保留不变。
Phase 4 删除旧路径。

### Phase 3：接入 UserCorrection ✅

accept / discard 路径已接线（EditorCore.applyInvocationResult）。
修改分支（modify）已接线：EditorCore 在 .applied 时调用
`session.process(.userCorrection(proposalID:acceptedStepIDs:rejectedStepIDs:))`
而非 `recordOutcome`，由 `processCorrection` 统一处理历史归档与重推理。

### Phase 4：删除翻译层 ✅

`LocalIntentClassifier`、旧 NL pipeline、`IntentTrainingLogger` 从未进入主干，不存在。
`CapabilityRegistry` 保留用于 Validation（约束检查），不作路由用，符合设计预期。

### Phase 5：World 统一 ✅

World 的 authored / evaluated / inferred 三层逐步取代 ECS 直接暴露给上层的模式。ECS 降级为运行时执行后端。

Phase 5a（已完成）— delta 驱动的 WorldView：

```
Engine/Sources/IntentRuntime/
  WorldEvent.swift        — WorldPropertyValue, WorldEvent（5 种事件类型）
  TransactionExecutor     — apply() 产出 worldEvents: [WorldEvent]，附到 TransactionApplyResult

Engine/Sources/AIRuntime/
  WorldView.swift         — WorldEntityRecord（authored 层实体记录，Codable）
                            entityIndex: [String: WorldEntityRecord] 替代 sceneSnapshot
                            apply(event:) — O(1) 增量更新，apply(snapshot:) 保留作为 bootstrap
  Session.swift           — observe(event:) 接收 delta；systemPrompt() 从 entityIndex 构建
                            entityIndexJSON() 替代 encodeSnapshot()

Editor/Sources/EditorCore/
  EditorCore              — bootstrap session 于创建/设置更新时
                            applyInvocationResult() 将 worldEvents 传入 session.observe(event:)
                            移除每次 NL 请求前的全量快照编码
```

Phase 5b（已完成）— evaluated 和 inferred 层：

```
Engine/Sources/IntentRuntime/
  WorldEvent.swift        — WorldPropertyValue 加 Codable；新增 entityEvaluatedChanged /
                            entityInferredUpdated 两种事件类型
  TransactionExecutor     — deriveWorldEvents() 对 transform 操作追加 entityEvaluatedChanged
                            (worldPosition)，在 propagateTransforms() 后查询世界坐标

Engine/Sources/AIRuntime/
  WorldView.swift         — WorldEntityRecord 加 evaluated / inferred 两层字典；
                            InferredProperty（displayValue, confidence, source）
                            apply(event:) 处理 Phase 5b 事件
  Session.swift           — systemPrompt() 将 evaluated / inferred 数据自动序列化进实体 JSON；
                            Rules 说明 worldPosition 用于空间推理，set_transform 写 local space
                            conversationHistory 加入 system prompt；learn() 改为 .user turn
```

Phase 5c（已完成）— 语义生产流水线骨架：

```
Engine/Sources/SemanticPipeline/
  SemanticContracts.swift       — RawStructure, GeometrySignals, Region,
                                  GeometryFingerprint, SemanticProposal,
                                  AmbiguityDecision, SemanticConfirmation
  SemanticAnalyzerBackend.swift — SemanticAnalyzerBackend 协议；
                                  NameHeuristicBackend（DCC 命名模式匹配）
                                  RigBackend（骨骼名 → 部位）
                                  MetadataBackend（DCC 自定义属性）
  SemanticMemoryStore.swift     — SemanticMemoryStore 协议；
                                  EphemeralSemanticMemoryStore（测试用内存实现）
  AssetSemanticPipeline.swift   — 流水线协调器：backend 并发采集 → 歧义评分 →
                                  AutoCommit / NeedsConfirmation；确认落盘写 memory
```

待完成：GeometryAnalyzer 真实实现、VisionBackend、SQLite 持久化 SemanticMemoryStore、
与 World inferred 层的 WorldEvent 写入对接。

---

## 文档索引

| 文档 | 内容 | 状态 |
|------|------|------|
| `architecture.md`（本文档） | 总纲：五个核心概念、数据流、实现路径 | 总纲 |
| `ai-native-observation-bus-design.md` | World 变更流的技术实现 | 参考 Phase 1 |
| `ai-native-semantic-pipeline-design.md` | Asset 导入时填充 World inferred 层的流水线 | 参考 Phase 2 |
| `ai-native-perception-runtime-design.md` | 视觉/感知模型的训练、部署、许可证、IR 与 World 写入契约 | 参考 Phase 2 |
| `ai-native-sequence-document-design.md` | World 的时间轴层（Shot/Clip/Binding）详细设计 | 参考 Phase 2 |
| `ai-native-scene-from-image-design.md` | ReferenceImage Signal 的处理流水线 | 参考 Phase 2 |
| `ai-native-minimal-confirmation-ui-design.md` | Confirmation 作为学习协议的 UI 实现 | 参考 Phase 3 |
| `ai-native-film-workflow-design.md` | Session 在影视工作流上下文的行为模式 | 参考 Phase 2+ |
| `ai-native-game-workflow-design.md` | Session 在游戏开发工作流上下文的行为模式 | 参考 Phase 2+ |
