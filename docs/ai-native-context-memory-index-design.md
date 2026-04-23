# Context Memory Index 详细设计

> 本文是总纲 `ai-native-scene-model-design.md` §12 的落地。范围限定为：Memory 条目的 schema、写入路径、失效与 GC、查询接口、与 SemanticMemoryStore / SceneMemoryStore 的关系、给 LLM 的符号化视图。
> 本文不重复定义 Observation Bus envelope、CapabilityGraph schema、Transaction IR、AmbiguityScorer；它们在
> `ai-native-observation-bus-design.md`、`ai-native-capability-graph-schema-design.md`、总纲 §11、`ai-native-semantic-pipeline-design.md`。

---

## 0. 设计前提

1. Memory 不是数据库，是为 AI agent 维持长上下文而存在的"折算视图"。它的生命周期短于业务库，业务库才是事实。
2. Memory 的所有条目必须能反查到一组 `event_id`（来自 Observation Bus）或一组 `document_ref`（来自业务库）。无来源的条目禁止入库。
3. Memory 不持有 vector / embedding / 渲染图。需要相似性检索时，调用 `SemanticMemoryStore` / `SceneMemoryStore`，Memory 只缓存它们的 handle 与 score。
4. Memory 的写入路径只有一条：订阅 Bus → 经 reducer → 入 Memory。禁止业务侧旁路写。
5. Memory 给 LLM 的视图必须是符号化、定长、可裁剪的；任何"贴一段原始 payload"的捷径都不允许。
6. Memory 失效优先于"看上去更新"：宁可丢条目让 LLM 重问，也不留陈旧条目误导推理。
7. Memory 是 per-agent + per-project 的。不同 agent 不共享条目；切换项目时旧条目 freeze（不删，不参与查询）。

---

## 1. 顶层结构

```
ContextMemoryIndex
├── EntryKindRegistry        # 闭集条目类型
├── Reducers                 # event → entry 的折算器（每 kind 一个）
├── Store                    # 条目持久层（per agent × project）
├── Query                    # 给 agent / planner 的查询接口
├── GC                       # 失效与裁剪
├── SnapshotProvider         # 给 LLM 的符号化视图
└── Bridge                   # 与 SemanticMemoryStore / SceneMemoryStore 的桥
```

---

## 2. EntryKindRegistry

闭集，编译期注册。每个 kind 对应总纲 §12.2 的一类语义。

```text
EntryKindSpec {
  id: EntryKindId,                     // e.g. "scene.overview"
  payload_schema: PayloadSchemaId,     // 闭集 schema
  scope: ProjectScope | SceneScope | SequenceScope | AssetScope | AgentScope,
  cardinality: singleton | bounded(N) | unbounded,
  freshness: stale_after_event(EventKindId) | stale_after_seconds(u32) | manual,
  redact_in_prompt: bool,
  added_in: Version,
  deprecated_in: Option<Version>,
}
```

### 2.1 闭集六类

与总纲 §12.2 一一对应，外加一类 capability 偏好：

| EntryKind | scope | cardinality | 折算自 |
|---|---|---|---|
| `overview` | Scene / Sequence / Project | singleton | `*.changed` 的统计聚合 |
| `focused_slice` | Agent | singleton | `selection.changed` + `focus.changed` |
| `last_diffs` | Scene / Sequence | bounded(N) | `transaction.applied` |
| `unresolved_issues` | Project | bounded(N) | `diagnostics.warning.raised` + `confirmation.requested` 未 resolve |
| `user_intent_continuity` | Agent | bounded(M) | 历次 `transaction.staged/applied` + `confirmation.resolved` 的 user_text 字段 |
| `capability_preference` | Agent | bounded(K) | 历史选择（用户撤销 / 接受 / 改写）频次 |

禁止增加自由 kind；新增需走 EntryKindRegistry 注册流程并补 reducer。

### 2.2 Provenance 标记

每条 entry 必须携带 `provenance: authored | evaluated | runtime | baked | inferred`。规则：

- 若来源事件全部为 `authored` → entry provenance = `authored`
- 若混合 → 取最弱的一种（`authored > baked > evaluated > runtime > inferred`，越右越弱）
- `inferred` 的 entry 在 SymbolicView 中必须带 `(inferred)` 后缀标签，禁止隐式

---

## 3. Entry 通用 Envelope

```text
MemoryEntry {
  entry_id: EntryId,                   // (kind, scope_key, slot)
  kind: EntryKindId,
  scope_key: ScopeKey,                 // project_id / scene_id / sequence_id / agent_id 等
  slot: u32,                           // bounded kind 的位置；singleton 恒为 0
  payload: PayloadRecord,              // 由 payload_schema 决定
  provenance: Provenance,
  evidence: Evidence,
  created_at_seq: { stream_id, seq },
  refreshed_at_seq: { stream_id, seq },
  freshness_state: fresh | aging | stale,
  schema_version: u32,
}

Evidence {
  source_events: [EventRef],           // (stream_id, seq, event_kind)
  source_documents: [DocumentRef],     // (store, doc_id, content_hash)
  external_handles: [ExternalHandle],  // SemanticMemoryStore / SceneMemoryStore handle + score
}
```

`Evidence` 是必填字段。无 evidence 的 entry 视为脏数据，不入库。

---

## 4. 各 EntryKind 的 payload schema

### 4.1 `overview`

scope 可以是 Project / Scene / Sequence。

```text
OverviewPayload {
  scope_kind: ProjectScope | SceneScope | SequenceScope,
  counts: { entities: u32, assets: u32, sequences: u32, shots: u32, diagnostics_open: u32 },
  highlights: [Highlight],             // 闭集 Highlight，bounded(8)
  topology_digest: StructuredDigest,   // 例：层级树缩略，bounded 字段
  last_significant_change: { stream_id, seq, kind },
}

Highlight = NewlyAddedKind | DroppedKind | LongOpenIssueKind | RecentBakeKind | RecentPromoteKind
```

`highlights` 闭集 5 种，禁止自由文本。

### 4.2 `focused_slice`

```text
FocusedSlicePayload {
  selection: [TargetRef],              // bounded(64)
  active_view: ViewId,
  active_document: DocumentRef,
  derived_facts: [DerivedFact],        // bounded(16)，闭集 fact kind
}

DerivedFact =
  | SelectionShares(prop: PropId, value_kind: ValueKindId)
  | SelectionDiffers(prop: PropId)
  | SelectionAllOfKind(target_kind: TargetKindId)
  | SelectionEmpty
  | SelectionDangling(missing_targets: u32)
```

DerivedFact 的全集与 CapabilityGraph 的 PredicateAst 共用闭集（`ai-native-capability-graph-schema-design.md` §6），保证 Memory 折算的判断与 capability 前置条件能对齐。

### 4.3 `last_diffs`

bounded(N=16，可配置)，按 `refreshed_at_seq` 降序。

```text
LastDiffPayload {
  causation_id: TransactionId,
  capability_id: CapabilityId,
  scope_key: ScopeKey,
  diff_summary: DiffSummary,           // 结构化（add/remove/modify counts + top-k 字段名）
  user_initiated: bool,                // 区分 agent 触发与用户触发
  outcome: applied | discarded | reverted,
}
```

`diff_summary` 不内联整个 patch；patch 留在 transaction store，Memory 只放 handle + 摘要。

### 4.4 `unresolved_issues`

bounded(N=32)。

```text
UnresolvedIssuePayload {
  issue_kind: DiagnosticKindId | ConfirmationKindId,
  scope_key: ScopeKey,
  raised_at_seq: { stream_id, seq },
  age_buckets: fresh | day | week | month_plus,
  blocks_capabilities: [CapabilityId],  // 该 issue 在 PreconditionRef 中阻塞了哪些 capability
  user_seen: bool,                      // 是否已在 UI 出现过
}
```

GC 规则：收到对应 `diagnostics.cleared` 或 `confirmation.resolved` 事件即移除。

### 4.5 `user_intent_continuity`

bounded(M=24)。这是唯一允许保留用户自然语言片段的 kind，但有强约束：

```text
IntentContinuityPayload {
  utterance_ref: TextHandle,           // 不内联文本；handle 指向受控文本存储
  resolved_intent: ResolvedIntentRef,  // 指向已解析的 IntentIR
  outcome: committed | abandoned | clarified,
  related_targets: [TargetRef],        // bounded(16)
  superseded_by: Option<EntryId>,      // 同一 agent 的更晚 utterance 替代关系
}
```

约束：

1. 自然语言原文不进 SymbolicView，进 LLM 时只暴露 `resolved_intent` 的结构化形式 + `outcome` + `related_targets`。
2. 若用户撤回（`transaction.discarded`），entry 标 `outcome = abandoned`；不删除（agent 需要知道"用户曾尝试但放弃了什么"）。
3. `superseded_by` 形成单向链；过老的链尾按 GC 规则裁剪。

### 4.6 `capability_preference`

bounded(K=32)。

```text
CapabilityPreferencePayload {
  capability_id: CapabilityId,
  user_signals: { accepted: u32, edited_then_accepted: u32, discarded: u32, reverted: u32 },
  last_used_at_seq: { stream_id, seq },
  context_tags: [ContextTagId],        // 闭集 tag（如 day_lighting / interior / hardsurface）
}
```

仅作为 planner 的排序提示，禁止用作 capability 的 enable/disable 开关。

---

## 5. Reducer

每个 EntryKind 注册一个 reducer：

```text
Reducer {
  consumes: [EventKindId],             // 必须存在于 EventKindRegistry
  reduce: (current_entry?, event) -> ReducerOutcome,
}

ReducerOutcome =
  | NoOp
  | Upsert(MemoryEntry)
  | InsertSlot(MemoryEntry)            // bounded kind 用，自动按策略淘汰
  | Drop(EntryId)
  | MarkStale(EntryId)
```

### 5.1 约束

1. Reducer 必须是纯函数，仅依赖入参与显式注入的 store handle。
2. Reducer 不允许直接读业务库的可变状态；如需补充，只能查 SnapshotProvider 或 SemanticMemoryStore（只读接口）。
3. Reducer 输出的 entry 的 `Evidence.source_events` 必须包含本次 event。
4. Reducer 内禁止调用 `bus.publish`（防止环路）。

### 5.2 bounded(N) 的淘汰策略

bounded kind 在 EntryKindSpec 上声明：

```text
eviction: lru | lifo | priority(by: FieldPath)
```

不允许 `random` / `manual`。`unresolved_issues` 强制 `priority(by = age_buckets desc, then user_seen asc)`。

---

## 6. Store

per (agent_id, project_id) 一个逻辑分区。

| 实现 | 适用 |
|---|---|
| 内存 BTreeMap | 默认开发态 |
| 嵌入式 KV（如 sled / rocksdb，待选型） | 长会话与崩溃恢复 |

写入要求：

1. Upsert 必须原子：(entry, evidence, refreshed_at_seq) 三者一致。
2. `created_at_seq` 一旦写入不可改。
3. 任何写入都更新 `freshness_state`：默认 `fresh`，被 §7 的策略转 `aging` / `stale`。
4. 不提供"清空全表"接口；只提供按 scope_key + kind 的批量 GC。

### 6.1 跨会话恢复

agent 重连时按 (agent_id, project_id) 加载所有 entry，并触发一次"对账"：

1. 取每个 entry 的 `refreshed_at_seq`；
2. 调 Bus 的 `bus.replay(stream, from_seq=cursor, to_seq=now)`；
3. 对所有 entry 重跑相关 reducer，得到当前一致 entry 集；
4. 对账期间 SnapshotProvider 返回 `state = warming_up`，禁止给 LLM。

---

## 7. 失效与 GC

三种失效路径：

| 路径 | 触发 | 行为 |
|---|---|---|
| 事件失效 | EntryKindSpec.freshness = `stale_after_event(K)` 且收到 K | 标 `stale`，下次查询返回前 reducer 重算或丢弃 |
| 时间失效 | freshness = `stale_after_seconds` 超时 | 同上 |
| 显式失效 | reducer 返回 `MarkStale` 或上游 store 通知 invalidate | 同上 |

`stale` 的 entry 不进 SnapshotProvider，但保留在 Store 直到 GC 触发：

- 周期 GC：删除所有 `stale` 且超过 `gc_grace` 的 entry
- 容量 GC：bounded kind 超 N 时按 §5.2 策略淘汰
- 项目切换：旧 project 的所有 entry 标 `frozen`，不参与查询，30 天后真正删除

### 7.1 跨 store 失效联动

- `SemanticMemoryStore` 的 region 被重新指派语义（authored 升格） → 相关 `overview.highlights` / `last_diffs` 标 stale
- `SceneMemoryStore` 的图像哈希条目被用户拒绝 → 相关 `user_intent_continuity` 链上对应 entry 标 `outcome = clarified`，但不删除

---

## 8. Query 接口

提供给 planner / agent 的查询是只读、限定形状的：

```text
memory.snapshot(agent_id, project_id) -> MemorySnapshot
memory.scope_view(agent_id, project_id, scope_key) -> ScopedSnapshot
memory.lookup_intent_chain(agent_id, project_id, anchor_intent) -> [IntentContinuityPayload]
memory.lookup_unresolved(agent_id, project_id, blocks: CapabilityId?) -> [UnresolvedIssuePayload]
memory.lookup_preference(agent_id, capability_id) -> CapabilityPreferencePayload?
```

禁止：

- 任意结构化 SQL / Cypher 查询入口
- 暴露原始 evidence 中的 raw payload
- 跨 agent 的 join 接口

---

## 9. SnapshotProvider（给 LLM 的符号化视图）

LLM 不直接读 Memory 条目；走 `MemorySymbolicView`。

```text
MemorySymbolicView {
  scope: { project_id, scene_id?, sequence_id?, agent_id },
  overview: SymbolicOverview?,
  focused_slice: SymbolicFocusedSlice?,
  last_diffs: [SymbolicDiff],          // 截断到 top_k
  unresolved_issues: [SymbolicIssue],
  intent_continuity: [SymbolicIntent], // 已脱敏
  capability_preference: [SymbolicPreference],
  state: ready | warming_up | partial,
  evidence_index: EvidenceIndex,       // entry → handle 反查表，agent 可按需 fetch
}
```

裁剪规则（与 Bus §15 一致并加严）：

1. 任何 `redact_in_prompt = true` 的字段替换为 handle ref + 类型标签。
2. `intent_continuity.utterance_ref` 永不展开为原文；只输出 `resolved_intent` 的结构化形态。
3. `evidence_index` 只放 handle，不放事件 payload；agent 想看完整事件需调 Bus 的 `read_payload`，并经 capability 校验。
4. `inferred` provenance 的 entry 必须带显式 `(inferred)` 标签，且不与 `authored` 同等排序。
5. 视图大小硬上限：`max_entries_per_kind` 与 `max_total_chars` 双重 cap，超出按 reducer 声明的 priority 截断，截断事实写入 `state = partial`。

---

## 10. 与 SemanticMemoryStore / SceneMemoryStore 的关系

三者职责严格分层：

| 名称 | 职责 | 数据形态 |
|---|---|---|
| `SemanticMemoryStore` | 几何指纹 → 已确认语义的检索（B.5） | 向量 + 结构化标签 |
| `SceneMemoryStore` | 图像哈希 → 已确认场景布局的检索（F） | 图像 handle + 结构化布局 |
| `ContextMemoryIndex` | 当前 agent 的上下文折算视图 | 结构化条目，不持向量 |

调用关系：

- ContextMemoryIndex 单向读 SemanticMemoryStore / SceneMemoryStore（拿 handle 与 score）
- 反向不允许（两个 Store 不感知 Memory 存在）
- 三者的 invalidation 通过 Observation Bus 事件解耦，不直接互相调用 invalidate API

---

## 11. 与其他模块的对接矩阵

| 模块 | 关系 |
|---|---|
| Observation Bus | 唯一上游写入路径；Memory 是其订阅者，cursor 形态见 Bus §6 / §11 |
| CapabilityGraph | `unresolved_issues.blocks_capabilities` 与 `last_diffs.capability_id` 引用 schema 中的 CapabilityId；planner 用 `capability_preference` 排序 |
| Transaction IR | `last_diffs.causation_id` = TransactionId；Memory 不持有 patch，只指向 transaction store |
| MinimalConfirmationUI | `confirmation.requested` 未 resolve → `unresolved_issues`；`confirmation.resolved` → 触发对应 issue 删除 + 可能写 `user_intent_continuity` |
| AmbiguityScorer | 不直接对接；Scorer 在生成 Question 时可读 Memory，但写回必须经 Bus 事件 |
| SemanticMemoryStore / SceneMemoryStore | 见 §10 |
| Game / Film 工作流 | DiagnosticsView / Telemetry 是 `unresolved_issues` 与 `overview` 的具体 UI 物化 |

---

## 12. 失败模式与降级

| 故障 | 行为 |
|---|---|
| Reducer 抛错 | 标记该 entry `stale`，写 `diagnostics.warning.raised`；不阻塞其他 reducer |
| EntryKindRegistry 校验失败 | Memory 子系统启动失败，agent 进入"无 Memory 模式"（仍可工作，但 LLM 视图为空，state = partial） |
| 对账期间崩溃 | 重启时丢弃所有非持久化 fresh 状态，重新对账 |
| Bus 长时间断连 | Memory state 转 `partial`；Snapshot 标记 stale，但不清空已有 entry |
| Store 写满 | 暂停 Upsert，按 §7 容量 GC 释放；释放期间新事件入待办队列 |
| SemanticMemoryStore handle 失效 | 相关 entry 的 evidence.external_handles 该项标 `dangling`，下次查询忽略 |
| 跨 schema 版本读取 | 老 entry 的 `schema_version` 不匹配时强制重算或丢弃，禁止"猜字段" |

---

## 13. 安全与隐私

1. `user_intent_continuity` 是唯一保留用户自然语言的 kind；其 `utterance_ref` 指向受控文本存储，存储侧负责加密 / 脱敏 / 用户撤回时硬删除。
2. SymbolicView 永不直出原文；调用方若想审阅原文需走带审计的接口（不在本文范围）。
3. Memory 跨 agent / 跨用户共享被禁止；多 agent 协作必须各自维护，或经显式 share 接口（待设计，不在本文范围）。
4. 项目导出 / 备份默认不包含 Memory（agent 短期工作记忆不进版本库），如需打包训练数据，走 Bus cold_log，不走 Memory。

---

## 14. 实现顺序

1. EntryKindRegistry + 基础 Envelope + 内存 Store
2. 6 个内置 EntryKind 的 payload schema 与 reducer（先 overview / focused_slice / last_diffs）
3. Bus 订阅与 cursor 持久化
4. 失效策略 + 周期 GC
5. SnapshotProvider 与 SymbolicView 裁剪
6. 跨会话对账（replay 联调）
7. 与 CapabilityGraph 的 blocks_capabilities 校验
8. SemanticMemoryStore / SceneMemoryStore handle 桥
9. capability_preference 与 planner 排序的 A/B 验证

---

## 15. 验收标准

1. 任一 entry 都能反查到 source_events 或 source_documents；CI 用 fuzz event 流验证。
2. Reducer 是纯函数：同一事件序列重放产出 bit-equal 的 entry 集。
3. SymbolicView 不出现：自然语言原文（除 capability 显式声明的 prompt_safe 字段）、向量、图像 bytes、handle 之外的二进制。
4. 跨会话重连后，对账完成时间与事件量呈次线性（依赖 Bus 的 snapshot/replay）。
5. `unresolved_issues` 的 `blocks_capabilities` 与 CapabilityGraph 的 PreconditionRef 在 CI 中双向校验。
6. bounded kind 的容量约束与 eviction 策略可观测（metric 公开）。
7. inferred 来源的 entry 在视图中带显式标签，agent prompt 模板能区别处理。
8. 项目切换后，旧 project 的 entry 不出现在任何 query / view 结果中。
9. 任意单个 reducer 抛错不影响整体 Memory 可用性。

---

## 16. 不在范围

- IntentIR / TransactionIR 字段定义（属总纲 §11）
- Bus envelope / 投递语义（属 `ai-native-observation-bus-design.md`）
- SemanticMemoryStore / SceneMemoryStore 内部 schema（属 B.5 / F 子文档）
- 多 agent 共享 Memory 的协议
- 用户文本审计 / 合规导出
- planner 的具体排序公式（仅给出 capability_preference 作为信号源）
- Memory 的 UI 可视化（如有，是另一份编辑器侧设计）

---

## 17. 后续待办

- ContextTagId 的初始闭集（与 capability_preference 联动）
- Highlight 的初始闭集补充示例与触发阈值
- DerivedFact 与 PredicateAst 的字段对齐表（保证 Memory 折算与 capability 前置条件同口径）
- 嵌入式 KV 的具体选型与基准
- 跨会话对账的"最大 replay 窗口"配置默认值与降级（窗口外只能丢 entry 重新冷启）
- Memory 在多用户协作场景下的隔离与 share 协议
