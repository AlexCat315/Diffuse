# AI Intent Resolution Pipeline

> Implementation guide for the three-layer intent cascade introduced in `guava-next`.
> 目标读者：引擎使用者、编辑器开发者、训练自有模型的开发者。

---

## 概述

Guava 的 AI 意图解析是一个**三层级联管道**，设计目标是：

- 常见操作在 <5 ms 内本地完成，无网络调用
- 复杂、模糊的意图路由至配置的 LLM 后端
- 任何层都可以独立替换或扩展（包括本地小模型）
- 所有解析结果都有来源标记，便于训练数据收集

```
用户输入
    │
    ▼
┌───────────────────────────────────────┐
│ Layer 1: LocalIntentClassifier        │  同步，<5 ms
│  • 加权词袋 + 双语同义词展开           │  无网络
│  • confidence ≥ threshold → 直接返回   │
└────────────────┬──────────────────────┘
                 │ confidence < threshold
                 ▼
┌───────────────────────────────────────┐
│ Layer 2: IntentResolverBackend        │  异步，0.5-2s
│  • 协议：Engine 仅知道接口            │  需要 API key
│  • 默认实现：AnthropicIntentResolver  │
│  • 完整 capability graph 作为工具定义 │
└────────────────┬──────────────────────┘
                 │ 后端不可用或调用失败
                 ▼
┌───────────────────────────────────────┐
│ Fallback: NaturalLanguageIntentResolver│  同步
│  • 确定性关键词匹配                   │
│  • 无法解析 → UnresolvableIntent 队列 │
└───────────────────────────────────────┘
                 │
                 ▼
         IntentResolutionResult
         （包含 verb、confidence、layer 来源）
                 │
                 ▼
    IntentTransactionBuilder.buildTransaction()
                 │
                 ▼
    IntentRuntimeCoordinator.submit()
     ├─ 直接应用（auto）
     └─ 发起确认请求（warn / required / destructive_required）
```

---

## 核心类型

### `NaturalLanguageIntent`

用户输入的原始文本，带语言和来源标注。

```swift
let intent = NaturalLanguageIntent(
    text: "在场景中心创建一个实体",
    localeIdentifier: "zh-Hans",
    source: .human
)
```

### `NaturalLanguageIntentContext`

解析时的编辑器状态快照，供各层使用：

| 字段 | 类型 | 说明 |
|------|------|------|
| `selectedObjectIDs` | `[String]` | 格式：`"scene:<entityID>"` |
| `selectedEntityLabels` | `[String]` | 选中实体的名称（供 LLM 理解） |
| `entityCount` | `Int` | 场景中实体总数 |
| `workspaceMode` | `String?` | `"level"` / `"modeling"` / `"animation"` |
| `recentVerbs` | `[String]` | 最近 3 条已解析的 verb，用于多步上下文 |
| `localeIdentifier` | `String?` | BCP-47 语言标签 |

### `IntentResolutionResult`

所有层返回的统一结果：

```swift
public struct IntentResolutionResult {
    public var intent: IntentIR?                     // 解析成功时非空
    public var unresolved: UnresolvableIntent?        // 解析失败时非空
    public var candidates: [IntentResolutionCandidate] // 包含 reason 字段
}
```

`candidates.first?.reason` 指示解析层：
- `"token_overlap"` → Layer 1（本地分类器）
- `"ai_tool_use"` → Layer 2（LLM 后端）
- `"* keyword"` → Fallback（关键词匹配）

---

## Layer 1：LocalIntentClassifier

### 算法

```
score(query, capability) =
    Σ(matched_weight) / Σ(total_weight)

权重：
  verbID 词元  × 3.0   （最具辨识度）
  summary 词元 × 2.0
  参数提示词元  × 0.5

同义词展开（仅针对 verbID + summary 核心词元，避免参数描述词造成误匹配）
```

**中文支持**：CJK 字符同时产生单字和双字 bigram，确保「创建」「移动」等复合词能匹配同义词表。

### 自定义阈值

```swift
let classifier = LocalIntentClassifier(confidenceThreshold: 0.4)
// 提高精度（减少误匹配），降低召回率
```

### 获取多个候选结果（用于 UI 提示）

```swift
let matches = classifier.topMatches(
    intent,
    context: context,
    capabilities: capabilities,
    maxCount: 3,
    minConfidence: 0.1
)
// → [(capability: CapabilitySymbolicView, confidence: Double)]
```

### 同义词表扩展

同义词表位于 `LocalIntentClassifier.swift` 的 `Synonyms.groups`。每个等价组同时包含英文和中文，确保跨语言匹配：

```swift
["move", "translate", "position", "transform",
 "移动", "平移", "位置", "移到", "变换"]
```

如需添加自定义术语（如领域专用词），在注册能力时使用 `llmHint` 字段：

```swift
CapabilityArgumentSpec(
    name: "targetPosition",
    typeID: "simd_float3",
    llmHint: "destination xyz world coordinates drop point"
)
```

---

## Layer 2：IntentResolverBackend

Engine 层只暴露协议，不依赖任何具体 AI 服务：

```swift
// Engine/Sources/IntentRuntime/IntentResolverBackend.swift
public protocol IntentResolverBackend: Sendable {
    func resolve(
        _ intent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext,
        capabilities: [CapabilitySymbolicView]
    ) async throws -> IntentResolutionResult
}
```

### 内置实现：AnthropicIntentResolverBackend

位于 `Editor/Sources/EditorCore/AI/AnthropicIntentResolverBackend.swift`。

工作方式：
1. 将所有 `CapabilitySymbolicView` 转换为 Anthropic tool 定义（JSON Schema）
2. verbID 中的 `.` 编码为 `__`（Anthropic 不允许工具名包含 `.`）
3. POST 到 `https://api.anthropic.com/v1/messages`，`tool_choice: any`
4. 从 `tool_use` block 解析工具名和参数，还原为 `IntentIR`

### 自定义后端

实现 `IntentResolverBackend` 协议即可接入任意 AI 服务：

```swift
struct MyLocalModelBackend: IntentResolverBackend {
    func resolve(
        _ intent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext,
        capabilities: [CapabilitySymbolicView]
    ) async throws -> IntentResolutionResult {
        // 调用本地推理服务...
        let verbID = await myModel.infer(intent.text, capabilities)
        guard let cap = capabilities.first(where: { $0.verbID == verbID }) else {
            return IntentResolutionResult(
                naturalLanguageIntent: intent,
                unresolved: UnresolvableIntent(...)
            )
        }
        let ir = IntentIR(verb: verbID, summary: cap.summary,
                          targetObjectIDs: context.selectedObjectIDs,
                          arguments: [:], confidence: 0.85,
                          evidence: [.init(kind: "local_model", summary: intent.text)],
                          source: .ai)
        return IntentResolutionResult(
            naturalLanguageIntent: intent,
            intent: ir,
            candidates: [.init(verbID: verbID, confidence: 0.85, reason: "local_model")]
        )
    }
}

// 注册（热插拔，无需重启）
intentCoordinator.setBackend(MyLocalModelBackend())
```

---

## 能力注册

能力通过 `CapabilityRegistry` 注册，JSON 格式位于：

```
Engine/Sources/CapabilityRuntime/Resources/CapabilityRegistry/default/
    capabilities.scene.json
    capabilities.sequence.json
    ...
```

重要字段：

```json
{
  "verb_id": "scene.spawn_entity",
  "summary": "Spawn or create a new entity in the scene",
  "scope": "scene_graph",
  "target_kind": "entity",
  "confirmation_policy": { "level": "auto" },
  "reversible": true,
  "arguments": [
    {
      "name": "label",
      "type": "string",
      "required": true,
      "llm_hint": "human-readable name for the new entity"
    }
  ]
}
```

`llm_hint` 直接注入 Layer 1 的词袋和 Layer 2 的 JSON Schema description，是提升 AI 理解准确度最直接的手段。

---

## IntentTransactionBuilder

Layer 1/2/Fallback 解析出 `IntentIR` 后，由 `IntentTransactionBuilder` 将其转换为具体的 `TransactionIR`（带操作列表）。

当前支持的动词：

| Verb | 说明 |
|------|------|
| `scene.spawn_entity` / `scene.create_instance` | 生成实体 |
| `scene.delete_entity` / `scene.delete_instance` | 删除实体 |
| `scene.duplicate_entity` | 复制实体 |
| `scene.set_name` | 重命名 |
| `scene.set_transform` / `scene.set_local_transform` | 设置变换 |
| `scene.snap_to_ground` | 贴地（Y=0） |
| `scene.set_camera_pose` | 设置相机位置与目标 |

添加新动词只需在 `buildTransaction` 的 `switch` 中增加 `case`，并创建对应的 `SceneMutation`。

---

## 训练数据收集

每条解析记录自动追加至 `<project>/.guava/intent_training.jsonl`：

```json
{"ts":"2026-05-07T12:00:00Z","locale":"zh-Hans","text":"创建一个实体","verb":"scene.spawn_entity","layer":"local","confidence":0.87,"outcome":"applied"}
{"ts":"2026-05-07T12:01:00Z","locale":"zh-Hans","text":"删掉这个","verb":"scene.delete_entity","layer":"AI","confidence":0.92,"outcome":"discarded"}
{"ts":"2026-05-07T12:02:00Z","locale":"zh-Hans","text":"变成红色","verb":null,"layer":"unresolved","confidence":0,"outcome":"unresolved"}
```

`outcome` 值：
- `applied` — 事务已提交
- `discarded` — 用户在确认对话中拒绝
- `unresolved` — 所有层均无法解析

### 用于训练本地分类器

```bash
# 提取所有成功解析的记录
jq 'select(.outcome == "applied") | {text, verb, layer, confidence}' \
  .guava/intent_training.jsonl > training_positive.jsonl

# 提取所有未解析记录（可用于扩展同义词或能力）
jq 'select(.outcome == "unresolved") | .text' \
  .guava/intent_training.jsonl
```

**推荐训练流程**：
1. 收集 ≥500 条 `applied` 记录
2. 用 `layer` 字段区分：`local` = Layer 1 能处理，`AI` = 需要 LLM，`keyword` = 关键词回退
3. 用 `text` + `verb` 作为分类标注对（input → class）
4. 微调轻量分类模型（BERT 或领域专用 transformer），导出 CoreML，替换或增强 Layer 1

---

## UI 入口

### 命令面板（Cmd+K）

主要 AI 入口，在编辑器任意位置可用：

- `Cmd+K` 打开
- `Escape` 或点击背景关闭
- 输入时实时显示 Layer 1 匹配建议（<5 ms，无网络）
- `Enter` 提交，经三层级联解析后自动关闭

### IntentInputPanel（开发者面板）

位于工作区面板中，额外提供：
- 当前能力图快照（最多 8 个）
- 未解析意图队列（可手动关闭）
- 逐条手动触发能力的调试接口

### 状态栏

解析完成后显示：`[local] scene.spawn_entity` / `[AI] scene.delete_entity` / `Resolving…`

---

## 线程与并发

- Layer 1：同步，可在任意线程调用
- Layer 2：`async`，必须 `await`
- `IntentRuntimeCoordinator.resolveNaturalLanguageIntentAsync`：async，内部串联三层
- `submitNaturalLanguageIntent`：在 `Task { @MainActor }` 中调用级联，状态更新在主线程
- `IntentRuntimeCoordinator.setBackend`：线程安全（`lock.withLock`）

---

## 关键文件索引

```
Engine/
  Sources/IntentRuntime/
    LocalIntentClassifier.swift      # Layer 1
    IntentResolverBackend.swift      # Layer 2 协议
    IntentRuntimeCoordinator.swift   # 三层级联
    IntentTransactionBuilder.swift   # Intent → Transaction
    NaturalLanguageIntentResolver.swift  # Fallback
  Sources/CapabilityRuntime/
    CapabilityRegistry.swift         # 能力注册与查询
    CapabilitySymbolicView.swift     # LLM 可读的能力描述

Editor/
  Sources/EditorCore/
    AI/
      AnthropicIntentResolverBackend.swift  # Anthropic 实现
      EditorAISettings.swift               # Provider 枚举 + Keychain
      IntentTrainingLogger.swift           # 训练数据收集
    EditorCore.swift                       # submitNaturalLanguageIntent
  Sources/EditorApp/
    ai/
      CommandPaletteOverlay.swift    # Cmd+K 命令面板
      IntentInputPanel.swift         # 开发者调试面板
      ConfirmationHostPanel.swift    # 确认 UI

Tests/
  IntentRuntimeTests/
    LocalIntentClassifierTests.swift  # 18 个分类测试
```
