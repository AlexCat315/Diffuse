# CapabilityGraph Schema 详细设计

> 本文档是 `ai-native-scene-model-design.md` §10 的 schema 详细设计，与 `ai-native-capability-catalog.md`（实例集）配套。
> 本文档定义 capability 的字段、关系、生命周期、注册流程、过滤策略、版本演化；不重复列出具体 verb（实例见目录文档）。

---

## 0. 设计前提

1. CapabilityGraph 是 AI 与 Transaction IR 之间的**唯一**协议层；任何写操作必须先解析为 capability 调用
2. capability 是**符号**而非函数指针；schema 决定它能被 LLM 理解和约束器静态检查
3. 同名 capability 在不同版本下行为可能不同，必须显式版本化
4. 任何"自由参数 / 任意 JSON"字段都视为 schema 缺陷，必须收敛到闭集
5. CapabilityGraph 不持有副作用，副作用属于 capability 实现（绑定到引擎模块）
6. 实例化见 `ai-native-capability-catalog.md`，本文档不复述具体 verb 名

---

## 1. 顶层结构

```
CapabilityRegistry
├── capabilities: map<verb_id, CapabilitySpec>
├── scopes: map<scope_id, ScopeSpec>
├── target_kinds: map<target_kind_id, TargetKindSpec>
├── argument_types: map<type_id, ArgumentTypeSpec>
├── effect_kinds: map<effect_id, EffectSpec>
├── policies: map<policy_id, PolicySpec>
└── versions: VersionTable
```

每张表都按 stable id 寻址；引用通过 id 而非内联，避免重复定义。

---

## 2. CapabilitySpec

```text
CapabilitySpec {
  verb_id: string                    // 反向域名风格："scene.set_transform"
  display_name: i18n_key
  summary: i18n_key                  // 一句话语义，给 LLM 看
  description: i18n_key              // 长描述，给人看
  category: string                   // catalog 章节锚点（asset / scene / sequence / ...）
  scope: scope_id
  target_kind: target_kind_id
  arguments: [ArgumentSpec]
  preconditions: [PreconditionRef]
  effects: [EffectRef]
  reversible: bool
  preview_support: PreviewSupport
  confirmation_policy: ConfirmationPolicy
  read_after_write: [ReadAfterWriteRef]
  writes_documents: [DocumentRef]
  writes_runtime: bool
  side_band_emits: [EventKind]       // Observation Bus 事件类型
  failure_modes: [FailureMode]
  release_phase_gate: ReleasePhaseGate
  required_role: RoleRef
  rate_limit?: RateLimit
  cost_estimate?: CostHint
  version: SemVer
  status: experimental | stable | deprecated | removed
  deprecates?: [verb_id@SemVer]
  superseded_by?: verb_id@SemVer
  evidence_kinds: [EvidenceKind]     // 给 MinimalConfirmationUI 用
  audit_required: bool
  provenance_input_allowed: [authored | inferred | baked]
  provenance_output: ProvenanceTag
}
```

### 2.1 verb_id 命名规则

- 反向域名格式：`<category>.<action>` 或 `<category>.<sub>.<action>`
- 全小写 + 下划线
- 不允许复数 / 进行时
- 必须在目录文档中可定位
- 跨版本不复用 id；废弃后移入 `removed`，新行为用 `_v2` 后缀或独立 verb

### 2.2 status 流程

`experimental → stable → deprecated → removed`

- experimental：默认仅 `editor` 角色以上可见，不出现在 LLM prompt 默认 capability 列表
- stable：完全开放
- deprecated：可调用，但每次调用回写 deprecation warning 到 Observation Bus
- removed：注册表保留 metadata（用于历史 transaction 回放），不可新调用

---

## 3. ScopeSpec

```text
ScopeSpec {
  scope_id: string                   // asset / prefab / scene_instance / shot_override / runtime / project_config / sequence / track / clip
  display_name: i18n_key
  hierarchy_parent?: scope_id        // 用于 UI 折叠与权限继承
  isolation_level: doc | runtime | hybrid
  default_required_role: RoleRef
  conflict_strategy: serialize | optimistic | last_write_wins | merge_required
}
```

### 3.1 scope 必须显式

任何 capability 不允许"作用域可变"。同一 verb 的语义在不同 scope 下应拆为不同 verb（参考 `model.set_part_transform` 与 `scene.set_transform`）。

### 3.2 isolation_level

- `doc`：写入 canonical document，走文档级 transaction
- `runtime`：仅作用于 RuntimeWorld，不持久化
- `hybrid`：先写 doc，立即同步到 runtime

---

## 4. TargetKindSpec

```text
TargetKindSpec {
  target_kind_id: string             // asset_uri | scene_instance_id | shot_id | clip_id | data_row_id | mesh_region_id | ...
  resolves_to: DocumentRef           // 此 target 必须能从某个 document 解析
  identity_stability: stable | revision_scoped | session_scoped
  validators: [TargetValidatorRef]
}
```

约束：

- `session_scoped` target 不能用于 `audit_required = true` 的 capability
- target_kind 必须能与 MinimalConfirmationUI 的 `EvidenceRef.kind` 一一映射（缺失需补 evidence_kind）

---

## 5. ArgumentSpec

```text
ArgumentSpec {
  name: string
  type: type_id
  required: bool
  default?: literal | computed_ref
  unit?: string                      // m / deg / s / frame / ratio / ...
  range?: { min?, max?, step? }
  enum_choices?: [literal]           // 闭集枚举
  description: i18n_key
  llm_hint?: i18n_key                // 给 LLM 的简短提示
  derive_from?: DeriveRule           // 可被引擎自动推导（用户不必显式给）
  redact_in_prompt: bool             // 敏感字段不入 prompt（如鉴权 token）
}
```

### 5.1 type_id 闭集

只允许下列类型族（可在 `argument_types` 表登记新族，但每个 type 必须有 schema）：

| 族 | 子类型 |
|----|--------|
| 标量 | bool / i32 / i64 / f32 / f64 / string |
| 标识 | stable_id / doc_uri / asset_uri |
| 几何 | vec2 / vec3 / vec4 / quat / mat4 / aabb / transform |
| 时间 | frame_index / frame_range / duration_s / smpte / fps |
| 颜色 | color_linear / color_srgb / color_temperature_k |
| 图形 | resolution / aspect / focal_mm / fstop |
| 集合 | array<T> / set<T> / map<K,V> |
| 受限 | enum<choices> / tagged_union<variants> |
| 资产 | mesh_region_ref / material_slot_ref / socket_ref / clip_ref |
| 文本 | i18n_key / phrase（仅用于 destructive 二次输入）|

禁止：`json` / `any` / `bytes`（除非进 redacted 字段）。

### 5.2 derive_from

当参数可由 EditorContext 自动推导（如"当前选择的 instance"），用 `derive_from` 标注，UI 与 LLM 可省略询问：

```text
DeriveRule {
  source: editor_context | last_capability_call | semantic_memory | clip_ref
  path: string                       // 在 source 内的字段路径
  fallback: required | use_default | error
}
```

---

## 6. PreconditionRef

```text
Precondition {
  id, kind: target_state | document_revision | role | release_phase
        | budget | cache_validity | binding_resolved | custom
  expr: PredicateAst                 // 受限 AST，禁止自由代码
  message: i18n_key                  // 失败时返回给用户 / LLM
  severity: block | warn
}
```

PredicateAst 节点闭集：

```
literal | field_ref | compare(==,!=,<,<=,>,>=) | not | and | or
| in_set | matches_regex_safelist | exists | revision_eq | role_at_least
```

不允许自由函数调用，避免 capability 之间隐式耦合。

---

## 7. EffectRef

effect 用于静态分析（"这个 capability 写了哪些字段"），让 LLM 与 transaction 调度器能预测影响。

```text
Effect {
  id, kind: write_field | create_node | delete_node | move_node
        | replace_asset | bake_cache | invalidate_cache | emit_event
        | submit_external_job
  target_kind: target_kind_id
  field_path?: string                // write_field 用
  value_origin: argument | derived | literal
  reversible_by?: verb_id            // 显式声明回滚 verb
}
```

约束：

- `reversible = true` 的 capability 必须满足：所有 effect 要么自身可逆（write_field 默认可逆），要么显式声明 `reversible_by`
- `submit_external_job` 是不可逆 effect 的标准化标记

---

## 8. PreviewSupport

```text
PreviewSupport {
  mode: none | ghost_world | overlay | numeric_diff | image_diff
  preview_cost: instant | <100ms | <1s | >1s
  preview_isolation: full | shared_runtime | shared_runtime_readonly
  produces: [PreviewArtifactKind]
}
```

UI / Transaction IR 据此决定预演路径。`none` 的 capability 不允许 `cfm` 严于 `auto`（否则用户无法预览就被强迫确认）。

---

## 9. ConfirmationPolicy

```text
ConfirmationPolicy {
  level: auto | warn | required | destructive_required
  ambiguity_amplifier: float         // 喂给 AmbiguityScorer 的乘子
  question_template_id?: i18n_key
  evidence_kinds: [EvidenceKind]
  destructive_phrase_key?: i18n_key  // destructive_required 必填
}
```

策略级联（取最严）：

1. capability 自带的 `confirmation_policy.level`
2. 项目级 override（`project.set_capability_thresholds`）
3. release_phase 收紧（见 §11）
4. 来自 inferred provenance 的额外升级（见 §12）

---

## 10. ReadAfterWriteRef

```text
ReadAfterWrite {
  view_id: string                    // ModelDocument / SceneDocument / DiagnosticsView / ...
  field_paths?: [string]
  staleness_tolerance: frames | revisions | strict
}
```

调度器在 capability 完成后**强制读回**这些视图，确保 LLM 上下文不基于过时数据继续推理。

---

## 11. ReleasePhaseGate

```text
ReleasePhaseGate {
  prealpha: allow | warn | deny
  alpha:    allow | warn | deny
  beta:     allow | warn | deny
  rc:       allow | warn | deny
  ship:     allow | warn | deny
  hotfix_exception: bool             // ship 阶段是否允许作为 hotfix 调用
}
```

CapabilityGraph 在解析每次调用时按 `ProjectDocument.release_phase` 过滤，详见 `ai-native-game-workflow-design.md` §8。

---

## 12. Provenance 处理

```text
provenance_input_allowed: [authored | inferred | baked]
provenance_output: ProvenanceTag
```

约束：

- 若 capability 的 target 当前 provenance ∉ `provenance_input_allowed`，调用被拒
- inferred 输入参与的 capability 调用结果默认标 inferred，不能写为 authored
- 升格 inferred → authored 的唯一通道是 `asset.promote_inferred_to_authored` 类 capability，required cfm
- baked 字段不能被 inferred 覆盖；必须先 invalidate cache

---

## 13. RateLimit / CostHint

```text
RateLimit {
  per_window: { count, window_s }
  scope: per_user | per_project | global
  on_exceed: defer | reject
}

CostHint {
  cpu_ms?: int
  gpu_ms?: int
  io_mb?: int
  external_call: bool
  monetary_cost?: { currency, amount }
}
```

CostHint 用于：

- LLM 在多候选间选择更便宜路径
- UI 在 destructive 二次确认前展示成本
- 调度器在过载时优先 defer 高成本 capability

---

## 14. FailureMode

```text
FailureMode {
  code: string                       // "target_not_found" / "precondition_failed" / "policy_blocked" / ...
  message: i18n_key
  retryable: bool
  suggested_recovery?: [verb_id]     // 推荐替代 capability
  diagnostic_kind: error | warn | info
}
```

所有 capability 调用失败必须返回 `FailureMode`，**禁止只抛异常**。LLM 与 UI 都依据 code 做下一步决策。

---

## 15. EvidenceKind

```text
EvidenceKind {
  kind: region | instance | shot | clip | data_row | mesh_slice | image_bbox | timeline_range
  selector_schema: type_id           // 必填，用于 UI 高亮
  thumbnail_provider?: string        // 引擎登记的缩略图回调 id
}
```

与 MinimalConfirmationUI §2 的 `EvidenceRef.kind` 同名同义；新增 evidence kind 必须在两份文档同时登记。

---

## 16. CapabilityGraph 关系

CapabilityGraph 不是孤立 capability 的集合，还包含跨 capability 的图关系：

```text
edges {
  composes: capability A 是若干 atomic capability 的有名组合
  reverses: capability A 是 capability B 的逆操作
  conflicts: capability A 与 B 不能在同一 batch 内
  prerequisites: capability A 调用前 B 必须成功
}
```

约束：

- 组合 capability 在执行时展开为 atomic 序列，全部走 Transaction IR
- 组合 capability 的 confirmation_policy 取所有子项中最严
- conflicts 边由调度器在 batch 解析期检查
- prerequisites 走 Precondition 体系，但显式登记在边上便于全局校验

---

## 17. 注册流程

新增 capability 的工程流程：

1. 在 `CapabilityRegistry` 提交 CapabilitySpec（status=experimental）
2. 在 `ai-native-capability-catalog.md` 对应章节追加 verb 行
3. 在引擎实现侧绑定 handler；handler 必须声明 effects 与 read_after_write
4. 在测试中加入：
   - schema round-trip
   - precondition 失败回归
   - reversibility 验证（reversible=true 的 verb）
   - preview correctness（preview 与 apply 结果一致或差异有界）
5. 在 `MinimalConfirmationUI` 中确认 evidence_kinds 已注册
6. CR 通过后晋升为 stable

废弃流程：

1. status 改为 deprecated，填 `superseded_by`
2. 至少一个 release 周期发出 deprecation warning
3. 升级到 removed；保留 metadata 但拒绝新调用

---

## 18. 版本与迁移

```text
VersionTable {
  registry_version: SemVer
  per_verb: map<verb_id, [SemVer]>
  migration_steps: [MigrationStep]
}

MigrationStep {
  from: verb_id@SemVer
  to:   verb_id@SemVer
  arg_remap: map<old_field, new_field | const | derive_rule>
  default_fill: map<new_field, literal | derive_rule>
  destructive: bool                  // 不可自动迁移则 true
}
```

历史 transaction 在重放时按 `MigrationStep` 自动重写 verb 调用；destructive 迁移要求人工干预，否则跳过该段重放。

---

## 19. CapabilityGraph 与 Intent IR / Transaction IR

```
NaturalLanguageIntent
  → IntentIR (LLM 输出)
  → CapabilityResolver (匹配 verb + 填 args + 校验 preconditions)
  → TransactionIR (单事务或事务序列)
  → PreviewExecutor (按 PreviewSupport 选模式)
  → ConfirmationGate (按 ConfirmationPolicy + AmbiguityScorer)
  → CommitExecutor
  → ReadAfterWrite (回灌 LLM 上下文)
```

约束：

- IntentIR 不允许自由文本 capability 调用，必须解析到具体 verb_id
- 解析失败的 IntentIR 进入 `unresolvable_intent` 队列，不静默丢弃
- CommitExecutor 写入 audit trail（`audit_required = true` 时强制）

---

## 20. 静态校验

CI 中必须运行的校验：

1. 每个 verb 的 schema 可解析
2. effects.target_kind 与 verb.target_kind 兼容
3. reversible=true 的 verb 满足 §7 reversible 约束
4. preview_support=none 的 verb 的 confirmation_policy ≤ auto
5. destructive_required 的 verb 必有 destructive_phrase_key
6. evidence_kinds 在 EvidenceKind 表中已登记
7. derive_from.source 在 EditorContext 中存在
8. enum_choices 的 literal 与目标 type 兼容
9. reverses / conflicts / prerequisites 边的两端 verb 都存在
10. registry_version 与 per_verb 的语义版本一致

校验失败阻断 capability 注册。

---

## 21. 与 LLM 的对接形式

LLM 看到的 capability 是符号化裁剪版（与 `ai-native-semantic-pipeline-design.md` §2.10 同口径）：

```text
CapabilitySymbolicView {
  verb_id, summary, scope, target_kind,
  arguments: [{ name, type, unit?, enum_choices?, description, llm_hint? }],
  reversible, preview_support.mode, confirmation_policy.level,
  failure_modes: [{ code, message, suggested_recovery? }],
  cost_estimate?
}
```

裁剪规则：

- 不含 effects / read_after_write / audit / 内部策略字段
- redact_in_prompt 字段不出现
- experimental verb 默认不在列表中
- release_phase 过滤已应用
- 按 EditorContext 与 IntentIR 的语义相关性排序，取 top-K

---

## 22. 验收标准

下列条件全部满足，本 schema 视为可交付：

1. 目录文档中所有 verb 都能用本 schema 表达，无字段缺失
2. CI 静态校验全部通过
3. 任一 verb 的 reversible=true 在测试中能完成 round-trip（apply→revert→state 一致）
4. preview_support 各模式都有至少一个示例 verb 能稳定运行
5. ReleasePhaseGate 在 ship 阶段拒绝 100% 不允许的 verb，且通过率 0 误判
6. inferred → authored 升格 100% 经 promote verb，无旁路
7. LLM 看到的 CapabilitySymbolicView 不含敏感字段（redact_in_prompt 字段缺席率 100%）
8. deprecated verb 调用 100% 写出 warning，不阻断
9. MigrationStep 在历史 transaction 重放上零数据丢失（destructive 项除外，需人工标记）

---

## 23. 不在范围

- 具体 verb 的语义与参数（见 `ai-native-capability-catalog.md`）
- IntentIR / TransactionIR 的内部数据结构（独立子文档，待落地）
- CapabilityResolver 的 LLM 提示工程
- 网络 / 多人协作下的分布式锁与 OT/CRDT
- 引擎内部 capability handler 的实现规范（per-engine 子文档）

---

## 24. 后续待办

- IntentIR / TransactionIR 详细设计
- CapabilityResolver 的歧义消解策略
- registry 的 RPC / MCP 暴露层（让外部工具按 schema 调用）
- composes 边的展开器与回滚链路
- 跨项目 capability 共享与许可机制
- LLM 评测集：给定 IntentIR，期望命中 verb 的准确率
