# AI Intent Pipeline

> Architecture guide for Guava's AI scene-editing pipeline.
> 目标读者：引擎使用者、编辑器开发者、训练自有模型的开发者。

---

## 概述

Guava 的 AI 意图管道分为两条独立路径：

**主路径 — 语义场景规划器（AI key 存在时）**：用户的自然语言输入 + 完整场景语义快照一起发送给 Claude，Claude 以单个 `execute_edit_plan` 工具调用返回一个多步骤、有类型的编辑计划，跳过能力注册表，直接生成 `TransactionIR`。

**回退路径 — 三层级联（无 AI key 时）**：`LocalIntentClassifier`（同步，<5 ms）→ `AnthropicIntentResolverBackend`（异步，从注册表选 verb）→ `NaturalLanguageIntentResolver`（关键词匹配）。

```
用户自然语言输入
        │
        ├─── aiScenePlanner 存在 ──────────────────────────────┐
        │                                                       │
        │    SceneSemanticEncoder.encode(scene)                 │
        │            │                                          │
        │            ▼                                          │
        │    SceneSemanticSnapshot                              │
        │    (实体列表 / 变换 / 灯光 / 摄像机 / 物理)             │
        │            │                                          │
        │            ▼                                          │
        │    AIScenePlanner.plan(userRequest:snapshot:)         │
        │    (Claude, 单工具 execute_edit_plan)                  │
        │            │                                          │
        │            ▼                                          │
        │    SceneEditPlan                                      │
        │    (summary + reasoning + [SceneEditStep])            │
        │            │                                          │
        │            ▼                                          │
        │    SceneEditPlanExecutor.buildTransaction(...)        │
        │    (intent: nil, provenance: .proposal)               │
        │            │                                          │
        │            ▼                                          │
        │    IntentRuntimeCoordinator.submitPlan(...)           │
        │    (跳过 CapabilityInvocationPlanner)                 │
        │            │                                          │
        │    ┌───────┴────────┐                                 │
        │    ▼                ▼                                 │
        │  .automatic      .requiresApproval                    │
        │  直接应用        发起确认 (batchID: "ai_cfm:...")      │
        │                                                       │
        └─── 无 aiScenePlanner ────────────────────────────────┘
                    │
            三层级联回退路径
                    │
             ┌──────▼──────────────────────────────┐
             │ Layer 1: LocalIntentClassifier       │  同步，<5 ms
             │  加权词袋 + 同义词展开                │  无网络
             └──────────────┬──────────────────────┘
                            │ confidence < threshold
                            ▼
             ┌──────────────────────────────────────┐
             │ Layer 2: AnthropicIntentResolverBackend│  异步
             │  完整 capability graph 作为工具定义   │  需要 API key
             └──────────────┬──────────────────────┘
                            │ 后端不可用或失败
                            ▼
             ┌──────────────────────────────────────┐
             │ Fallback: NaturalLanguageIntentResolver│  同步
             │  关键词匹配 → UnresolvableIntent 队列 │
             └──────────────┬──────────────────────┘
                            ▼
                     IntentResolutionResult
                            │
                            ▼
             IntentTransactionBuilder.buildTransaction()
                            │
                            ▼
             IntentRuntimeCoordinator.submit()
              ├─ 直接应用（auto）
              └─ 发起确认（warn / required / destructive_required）
```

---

## 主路径：AIScenePlanner

### 核心数据流

```swift
// 1. 编码场景状态
let snapshot = SceneSemanticEncoder().encode(
    scene,
    selectedEntityID: selectedID,
    workspaceMode: "level",
    localeIdentifier: "zh-Hans"
)

// 2. 生成编辑计划
let plan = try await AIScenePlanner(config: config).plan(
    userRequest: "把所有点光源的强度调低一半",
    snapshot: snapshot
)
// plan.summary    → "Reduce all point light intensities by 50%"
// plan.reasoning  → "User wants dimmer lighting overall..."
// plan.steps      → [SceneEditStep(op: .setLightIntensity, ...), ...]

// 3. 构建 TransactionIR
let executor = SceneEditPlanExecutor()
let transaction = try executor.buildTransaction(
    from: plan,
    scene: scene,
    baseSceneRevision: snapshot.sceneRevision,
    approvalPolicy: .requiresApproval
)
// transaction.intent == nil
// transaction.provenance == .proposal

// 4. 提交（绕过 CapabilityInvocationPlanner）
var ctx = TransactionExecutionContext(...)
let result = try coordinator.submitPlan(transaction, executionContext: &ctx)
```

### SceneSemanticSnapshot

`SceneSemanticEncoder` 同步读取活 `SceneRuntime`，产出 `SceneSemanticSnapshot`（`Codable`）。调用方在异步 API 调用前拍摄快照，避免并发读取场景。

快照包含每个实体的：

| 字段 | 说明 |
|------|------|
| `id` | `"scene:<rawID>"` — 由 `UInt64(entity.index) \| (UInt64(entity.generation) << 32)` 编码 |
| `name` | `SceneNameComponent.value` 或 `"Entity <id>"` |
| `kind` | `Camera` / `Directional Light` / `Point Light` / `Spot Light` / `Static Mesh` / `Group` / `Entity` |
| `position` | `[x, y, z]` 世界位置（来自 `LocalTransform`） |
| `components` | 存在的组件列表：`"transform"` `"mesh"` `"light"` `"camera"` `"rigidbody"` `"collider"` |
| `lightType/Intensity/Color/Range` | 灯光属性（当 `"light"` 在 components 中时填充） |
| `cameraFovYDegrees` / `cameraIsActive` | 摄像机属性 |
| `rigidBodyMotionType` | `"static"` / `"dynamic"` / `"kinematic"` |
| `isSelected` | 是否为当前选中实体 |
| `parentRef` / `childRefs` | 层级引用，格式同 `id` |

### SceneEditPlan 与 SceneEditOp

`SceneEditPlan` 是从 Claude `execute_edit_plan` 工具调用解码的多步计划：

```swift
public struct SceneEditPlan: Codable, Sendable {
    public var summary: String           // 一行描述
    public var reasoning: String?        // Claude 的推理（调试用）
    public var steps: [SceneEditStep]    // 有序的原子变更步骤
}
```

支持的 `SceneEditOp`（JSON `"op"` 字段）：

| Op | 说明 |
|----|------|
| `spawn_entity` | 生成实体 |
| `delete_entity` | 删除实体 |
| `duplicate_entity` | 复制实体 |
| `set_name` | 重命名 |
| `set_transform` | 设置位置 / 旋转 / 缩放 |
| `snap_to_ground` | 贴地（Y = 0） |
| `set_light_type` | 切换灯光类型 |
| `set_light_intensity` | 设置灯光强度 |
| `set_light_color` | 设置灯光颜色（线性 [r, g, b] 0–1） |
| `set_light_range` | 设置灯光范围 |
| `set_light_spot_angles` | 设置聚光灯内外角 |
| `set_camera_pose` | 设置摄像机位置与注视点 |
| `set_rigidbody_motion` | 设置刚体运动类型 |
| `set_rigidbody_mass` | 设置刚体质量 |
| `set_rigidbody_gravity` | 设置重力缩放 |
| `set_collider_trigger` | 切换碰撞触发器模式 |
| `set_constraint_enabled` | 启用 / 禁用约束 |

### SceneEditPlanExecutor

将 `SceneEditPlan` 转换为 `TransactionIR`（`intent: nil`，`provenance: .proposal`）。

关键细节：
- `set_transform`：从场景读取当前变换，只覆盖 Claude 指定的分量（保留其余）
- 旋转：XYZ 内禀欧拉角（度），通过 `simd_quatf(angle:axis:)` 分解组合
- 实体 ID 验证：解析 `"scene:<n>"` 前缀，确认实体存在于场景中
- `baseSceneRevision`：传入快照的修订版本号；如果场景在 API 调用期间发生变更，执行器可以检测冲突

### AI 计划的确认流

`submitPlan` 根据 `approvalPolicy` 分支：

- `.automatic` → 直接应用，返回 `.applied`
- `.requiresApproval` → 暂存，发起确认（`batchID` 前缀 `"ai_cfm:"`），返回 `.confirmationRequested`
- `.forbidden` → 抛出错误

解析确认时，EditorCore 通过 batchID 前缀区分来源：

```swift
if request.batchID.hasPrefix("ai_cfm:") {
    result = try coordinator.resolvePlanConfirmation(resolution, executionContext: &ctx)
} else {
    result = try coordinator.resolveConfirmation(resolution, executionContext: &ctx)
}
```

---

## 回退路径：三层级联

当没有 API key / `aiScenePlanner == nil` 时使用。

### Layer 1：LocalIntentClassifier

同步，<5 ms。加权词袋评分 + 双语同义词展开（英文 + 中文）。

```swift
let classifier = LocalIntentClassifier(confidenceThreshold: 0.32)
// confidence ≥ 0.32 → 直接返回，不调用网络
```

实时建议（每次击键）：

```swift
let matches = classifier.topMatches(intent, context: context,
                                    capabilities: caps, maxCount: 3, minConfidence: 0.08)
```

### Layer 2：AnthropicIntentResolverBackend

异步。将所有 `CapabilitySymbolicView` 作为工具定义发送给 Claude，Claude 选择最匹配的单个动词并返回参数。

verbID 中的 `.` 编码为 `__`（Anthropic 工具名不允许含 `.`）。

### Fallback：NaturalLanguageIntentResolver

同步关键词匹配。无法解析时生成 `UnresolvableIntent` 加入队列（可在 UI 中显示）。

### 解析来源标记

`candidates.first?.reason` 决定训练日志的 `layer` 字段：

| `candidates.first?.reason` | 训练日志 `layer` | 来源 |
|---------------------------|-----------------|------|
| `"token_overlap"` | `"local"` | Layer 1 本地分类器 |
| `"ai_tool_use"` | `"ai_tool"` | Layer 2 Anthropic 后端 |
| `"* keyword"`（后缀） | `"keyword"` | Fallback 关键词匹配 |
| 其他 | `"fallback"` | 其他回退逻辑 |

---

## 能力注册（回退路径）

三层级联依赖 `CapabilityRegistry`，JSON 定义位于：

```
Engine/Sources/CapabilityRuntime/Resources/CapabilityRegistry/default/
    capabilities.scene.json
    capabilities.sequence.json
```

`llm_hint` 字段直接注入 Layer 1 词袋和 Layer 2 JSON Schema，是提升 AI 理解精度最直接的手段：

```json
{
  "verb_id": "scene.spawn_entity",
  "summary": "Spawn or create a new entity in the scene",
  "arguments": [
    {
      "name": "label",
      "type": "string",
      "llm_hint": "human-readable name for the new entity"
    }
  ]
}
```

---

## 训练数据收集

每条 NL 意图解析记录自动追加至 `<project>/.guava/intent_training.jsonl`（JSONL，每行独立 JSON 对象）。

**两种不同的记录结构**，根据路径区分：

### 级联回退路径记录（`layer` ∈ `"local"` `"ai_tool"` `"keyword"` `"fallback"`）

```json
{
  "ts": "2026-05-08T09:12:34Z",
  "text": "把这个灯变成点光源",
  "locale": "zh-Hans",
  "layer": "local",
  "verb": "scene.set_light_type",
  "confidence": 0.87,
  "arguments": {"light_type": "point"},
  "candidates": [
    {"verb": "scene.set_light_type",      "confidence": 0.87, "reason": "token_overlap"},
    {"verb": "scene.set_light_intensity", "confidence": 0.31, "reason": "token_overlap"}
  ],
  "workspace": "level",
  "scene_entity_count": 8,
  "selected_entity_kind": "Point Light",
  "latency_ms": 3,
  "outcome": "applied"
}
```

### AI 规划器路径记录（`layer == "ai_planner"`）

```json
{
  "ts": "2026-05-08T09:15:02Z",
  "text": "把所有点光源的强度调低一半",
  "locale": "zh-Hans",
  "layer": "ai_planner",
  "model": "claude-sonnet-4-6",
  "plan_summary": "Reduce all point light intensities by 50%",
  "plan_reasoning": "User wants dimmer lighting overall; halving each current value",
  "plan_step_count": 3,
  "plan_steps": [
    {"op": "set_light_intensity", "entity_id": "scene:1", "intensity": 500},
    {"op": "set_light_intensity", "entity_id": "scene:4", "intensity": 250},
    {"op": "set_light_intensity", "entity_id": "scene:7", "intensity": 125}
  ],
  "workspace": "level",
  "scene_entity_count": 12,
  "selected_entity_kind": "Point Light",
  "latency_ms": 2340,
  "outcome": "applied"
}
```

### 未解析记录（`layer == "unresolved"`）

```json
{
  "ts": "2026-05-08T09:16:11Z",
  "text": "make it glow",
  "locale": "en",
  "layer": "unresolved",
  "candidates": [
    {"verb": "scene.set_light_intensity", "confidence": 0.12, "reason": "token_overlap"}
  ],
  "unresolved_reason": "missing_target",
  "workspace": "level",
  "scene_entity_count": 12,
  "latency_ms": 4,
  "outcome": "unresolved"
}
```

### 字段参考

| 字段 | 出现路径 | 说明 |
|------|----------|------|
| `ts` | 所有 | ISO 8601 UTC 时间戳 |
| `text` | 所有 | 用户原始 NL 输入 |
| `locale` | 所有 | 语言标识，如 `"zh-Hans"` `"en"` |
| `layer` | 所有 | `"local"` `"ai_tool"` `"keyword"` `"fallback"` `"ai_planner"` `"unresolved"` |
| `outcome` | 所有 | `"applied"` `"discarded"` `"unresolved"` `"error"` |
| `verb` | 级联路径 | 解析到的 capability verb ID |
| `confidence` | 级联路径 | 解析置信度（0–1） |
| `arguments` | 级联路径 | 解析到的参数键值对，vec3 序列化为 `[x,y,z]` |
| `candidates` | 级联 + unresolved | 前 N 个候选（含获胜者），用于边界分析 |
| `unresolved_reason` | unresolved | `"empty_input"` `"unsupported_verb"` `"missing_target"` `"missing_argument"` |
| `model` | ai_planner | Anthropic model ID |
| `plan_summary` | ai_planner | Claude 的一行计划描述 |
| `plan_reasoning` | ai_planner | Claude 的推理链（调试与训练用） |
| `plan_step_count` | ai_planner | 计划步骤总数 |
| `plan_steps` | ai_planner | 完整步骤列表，字段同 `SceneEditStep.CodingKeys` |
| `workspace` | 所有 | `"level"` `"modeling"` `"animation"` |
| `scene_entity_count` | 所有 | 提交时场景实体数量 |
| `selected_entity_kind` | 所有（如有选中）| 选中实体的 kind 标签 |
| `latency_ms` | 所有 | 从提交到解析完成的毫秒数 |

### 离线处理示例

```sh
# 所有 AI 规划器路径的已应用记录（用于 SFT）
jq 'select(.layer == "ai_planner" and .outcome == "applied")' intent_training.jsonl

# 有近似候选但未解析的记录（找 classifier 盲区）
jq 'select(.layer == "unresolved" and (.candidates | length) > 0)' intent_training.jsonl

# 按 layer 统计 outcome 分布
jq -n '[inputs] | group_by(.layer) | map({layer: .[0].layer, total: length, applied: [.[] | select(.outcome=="applied")] | length})' intent_training.jsonl

# AI 规划器平均延迟（ms）
jq '[select(.layer == "ai_planner") | .latency_ms] | add / length' intent_training.jsonl

# 提取可直接用于 SFT 的 (text, plan_steps) 对
jq '{input: .text, output: .plan_steps}' \
   <(jq 'select(.layer == "ai_planner" and .outcome == "applied")' intent_training.jsonl)
```

### 写入时机

| 事件 | 写入时机 |
|------|----------|
| 级联路径·未解析 | `resolveNaturalLanguageIntentAsync` 返回后立即写 |
| 级联路径·待确认 | 解析完成后暂存 `pendingTrainingEntry`；确认/拒绝后由 `flushTrainingLog` 写入 |
| AI 规划器·待确认 | `planner.plan` 返回后暂存；确认/拒绝后写入 |
| AI 规划器·错误 | `planner.plan` 抛出异常时立即写（`outcome: "error"`） |

---

## 线程与并发

| 调用 | 线程要求 |
|------|---------|
| `SceneSemanticEncoder.encode` | 同步，在进入 async 边界前调用 |
| `AIScenePlanner.plan` | `async`，内部使用 URLSession |
| `SceneEditPlanExecutor.buildTransaction` | 同步，`Sendable` |
| `IntentRuntimeCoordinator.submitPlan` | 同步，内部 `NSLock` 保护 |
| `LocalIntentClassifier.classify` | 同步，任意线程 |
| `IntentRuntimeCoordinator.resolveNaturalLanguageIntentAsync` | `async` |
| `IntentRuntimeCoordinator.setBackend` | 线程安全（`lock.withLock`） |

---

## 关键文件索引

```
Engine/
  Sources/AIRuntime/
    SceneSemanticSnapshot.swift      # 场景语义快照（Codable）
    SceneSemanticEncoder.swift       # SceneRuntime → SceneSemanticSnapshot
    SceneEditPlan.swift              # SceneEditOp + SceneEditStep + SceneEditPlan
    SceneEditPlanExecutor.swift      # SceneEditPlan → TransactionIR

  Sources/IntentRuntime/
    IntentRuntimeCoordinator.swift   # submitPlan / resolvePlanConfirmation
                                     # + 三层级联 resolveNaturalLanguageIntentAsync
    LocalIntentClassifier.swift      # Layer 1
    IntentResolverBackend.swift      # Layer 2 协议
    IntentTransactionBuilder.swift   # IntentIR → TransactionIR（回退路径）
    NaturalLanguageIntentResolver.swift  # Fallback

  Sources/CapabilityRuntime/
    CapabilityRegistry.swift
    CapabilitySymbolicView.swift

Editor/
  Sources/EditorCore/
    AI/
      AIScenePlanner.swift                  # 主路径：NL + snapshot → SceneEditPlan
      AnthropicIntentResolverBackend.swift  # 回退 Layer 2 实现
      EditorAISettings.swift               # Provider 枚举 + Keychain
      IntentTrainingLogger.swift           # 训练数据收集
    EditorCore.swift                       # submitNaturalLanguageIntent（路径路由）
                                           # submitPlanTransaction
                                           # resolvePendingConfirmation（batchID 分支）
```
