# Observation Bus 详细设计

> **定位**：本文档描述 World 变更流的技术实现，对应 `architecture.md` 中 World 的 WorldEvent 机制。
>
> Observation Bus 是 World 向所有订阅者广播变更的基础设施。Session 通过订阅 Observation Bus 增量维护 WorldView，而非轮询或全量快照。
>
> 本文不重复定义 Session、Proposal、Edit 结构；这些见 `architecture.md`。

---

## 0. 设计前提

1. AI 与编辑器不应通过"轮询整份文档"获得状态变化，事件流是唯一的增量来源。
2. 事件是事实的广播，不是命令。订阅者不能通过事件反向控制发出者。
3. 所有事件类型来自闭集 `EventKindRegistry`，禁止自由字符串 kind。
4. 事件 payload 是结构化记录，禁止裸 JSON / `bytes` / `any`。所有可能的二进制（截图、向量、ply 数据）必须改为 handle。
5. 事件不携带渲染图与 embedding；它们留在产物存储里，事件只给 handle + content_hash。
6. 事件可丢失（在背压或断连时），订阅者必须能用 `resync` 拉到一致状态。Bus 不承诺"全有序全送达"，只承诺"按 stream 单调递增 + 提供 resync"。
7. Bus 是单向广播；发布失败不回滚生产侧业务。事件持久化与业务事务是两个写路径，靠 outbox 对齐。

---

## 1. 顶层结构

```
ObservationBus
├── EventKindRegistry        # 闭集事件类型表
├── StreamRegistry           # 命名 stream（partition 维度）
├── Publisher                # 业务侧写入端
├── Subscriber               # 订阅端 + 过滤器
├── Backpressure             # 节流 / 合并 / 丢弃策略
├── Persistence              # outbox + ring + cold log
├── Resync                   # 订阅者补齐工具
├── Bridge                   # 跨进程 / 跨机网关
└── SymbolicView             # 给 LLM 的事件符号化裁剪层
```

---

## 2. EventKindRegistry

事件类型是闭集，编译期注册，运行期不可改。

```text
EventKindSpec {
  id: EventKindId,                     // e.g. "transaction.applied"
  domain: Domain,                      // project / scene / sequence / model / asset / transaction / diagnostics / ui / runtime
  payload_schema: PayloadSchemaId,     // 指向 schema registry，闭集
  cardinality: per_tick | per_change | per_batch,
  ordering: per_aggregate | per_stream | none,
  redact_in_prompt: bool,              // 进 LLM 视图前是否裁字段
  retention: RetentionClass,           // hot / warm / cold / ephemeral
  replayable: bool,                    // 能否进入 cold log 回放
  added_in: Version,
  deprecated_in: Option<Version>,
}
```

### 2.1 域与命名

事件 id 形如 `<domain>.<noun>.<verb>`，三段式。允许的 domain 来自闭集，与总纲 §12.1 对齐：

| domain | 例 |
|---|---|
| `project` | `project.opened`、`project.closed` |
| `scene` | `scene.changed`、`scene.entity.added`、`scene.entity.removed` |
| `sequence` | `sequence.changed`、`sequence.shot.changed` |
| `model` | `model.semantic.changed`、`model.geometry.changed` |
| `asset` | `asset.import.finished`、`asset.bake.finished`、`asset.promoted` |
| `transaction` | `transaction.staged`、`transaction.applied`、`transaction.discarded`、`transaction.failed` |
| `diagnostics` | `diagnostics.changed`、`diagnostics.warning.raised` |
| `ui` | `selection.changed`、`focus.changed`、`confirmation.requested`、`confirmation.resolved` |
| `runtime` | `runtime.tick`、`runtime.metric.sampled`、`runtime.crash` |

`ui.confirmation.requested` 与 `ui.confirmation.resolved` 必须与 `ai-native-minimal-confirmation-ui-design.md` 的 Question / Resolution schema 引用一致。

### 2.2 禁止的 kind 形态

- 没有 domain 前缀的（`anything_changed`）
- 域 = `custom` / `misc` / `other`
- 同一 domain 下 noun 不在闭集（CapabilityGraph 的 target_kinds 与 Observation Bus 的 noun 集合通过校验对齐）

---

## 3. EventEnvelope

每条事件都是 envelope + payload 两段。Envelope 字段固定，payload 由 `payload_schema` 决定。

```text
EventEnvelope {
  event_id: EventId,                   // 全局唯一 (stream_id, seq) 派生
  kind: EventKindId,
  stream_id: StreamId,                 // 见 §4
  seq: u64,                            // 同 stream 单调递增
  causal_seq: Option<u64>,             // 触发本事件的上游 seq（同 stream 内）
  monotonic_ts_ns: u64,                // 进程单调时钟，仅本进程内可比
  wall_ts_utc: i64,                    // UTC 毫秒，跨进程对齐
  origin: Origin,                      // 见 §3.1
  causation_id: Option<TransactionId>, // 由哪个 IntentTx 引发
  correlation_id: Option<CorrelationId>,// 跨服务追踪
  provenance: Provenance,              // authored / evaluated / runtime / baked / inferred
  payload_ref: PayloadRef,             // 见 §3.2
  schema_version: u32,
}
```

### 3.1 Origin

```text
Origin {
  process: editor | runtime | render_farm | tool,
  host: HostId,
  user: Option<UserId>,                // editor 进程必填
  agent: Option<AgentId>,              // 由 AI agent 触发时填
}
```

### 3.2 PayloadRef

payload 不一定内联：

| 形态 | 用途 |
|---|---|
| `Inline { record: PayloadRecord }` | 小型结构化记录（< 4KB） |
| `Handle { store: StoreKind, key: String, content_hash: Hash }` | 大型记录（diff、批量 patch、metric 块） |

订阅者按需 `bus.read_payload(payload_ref)` 拉取。Handle 形态确保 envelope 总是小、可索引、可持久化。

> 渲染图、embedding、几何数据**禁止**作为 payload。它们存在各自的 store（ImageStore / EmbeddingStore / GeometryStore），事件只引用 handle。

---

## 4. StreamRegistry

stream 是 partition 维度，决定事件的顺序边界。

```text
StreamSpec {
  id: StreamId,                        // e.g. "scene:<scene_id>"
  scope: ProjectScope | SceneScope | SequenceScope | AssetScope | RuntimeScope | GlobalScope,
  ordering_guarantee: per_seq,
  retention: RetentionClass,
  cross_process: bool,
}
```

### 4.1 默认 stream 划分

| stream | 内容 |
|---|---|
| `global` | project 级、agent / user 级 |
| `scene:<id>` | 该 scene 的所有变更与 selection |
| `sequence:<id>` | 该 sequence 的剪辑 / shot 变更 |
| `asset:<id>` | 单一 asset 的导入 / bake / promote |
| `transaction` | 全局事务流（staged / applied / discarded） |
| `diagnostics` | 诊断与警告 |
| `runtime:<session_id>` | 一次 play 会话的 tick / metric |

跨 stream 没有顺序保证。订阅者如果需要"先看到 transaction.applied 再看到 scene.changed"，只能按 `causation_id` 关联，不能依赖时间戳。

---

## 5. Publisher

发布端 API 收敛到三个动作：

```text
bus.publish(kind, stream, payload, options) -> EventId
bus.publish_batch(kind, stream, [payload], options) -> [EventId]
bus.publish_with_outbox(kind, stream, payload, txn_handle) -> EventId
```

### 5.1 与业务事务的对齐（outbox）

业务写入（如 `transaction.applied` 后真正改 SceneDocument）与事件发布必须原子。约束：

1. 业务事务在提交前把事件写入同一存储的 `outbox` 表。
2. 事务提交后，由 OutboxRelay 异步把事件刷到 Bus。
3. Relay 故障重试基于 `event_id` 幂等，订阅者必须按 `(stream_id, seq)` 去重。

未走 outbox 的发布（如 runtime tick）允许丢失，但必须在 EventKindSpec 标 `cardinality = per_tick`。

### 5.2 禁止

- 在 publish 回调里再调用 publish（同步链调用），必须经过 OutboxRelay 或显式 task。
- 在持有锁的临界区内 publish。
- 把 `publish` 失败当作业务失败（业务侧只决定是否进 outbox）。

---

## 6. Subscriber

订阅 API：

```text
bus.subscribe(spec: SubscriptionSpec) -> SubscriptionHandle

SubscriptionSpec {
  id: SubscriptionId,                  // 持久化身份，重连时定位 cursor
  filter: FilterAst,
  delivery: at_least_once | best_effort,
  start_from: latest | from_seq(stream_id, seq) | from_snapshot(snapshot_id),
  buffer_policy: BufferPolicy,         // 见 §7
  ack_mode: auto | manual,
}
```

### 6.1 FilterAst

过滤器是闭集 AST，禁止自由代码 / 正则注入。

```text
Filter =
  | KindIn([EventKindId])
  | StreamIn([StreamId])
  | OriginProcessIn([ProcessKind])
  | ProvenanceIn([Provenance])
  | CausationIn([TransactionId])
  | And([Filter])
  | Or([Filter])
  | Not(Filter)
```

匹配在发布侧完成（broker 端），订阅者只收到匹配后的事件。

### 6.2 Cursor 与 ack

- `at_least_once` 模式下，subscriber 需要 `ack(stream_id, seq)`，未 ack 的会重投（最多 N 次后转 dead-letter，见 §7.4）。
- `best_effort` 模式下，无 ack；订阅者断线即丢失，重连按 `latest` 起跑，必要时调 §8 resync。

---

## 7. Backpressure

事件源（runtime tick、scene drag）可能远快于订阅者。背压策略由 SubscriptionSpec.buffer_policy 决定，不在 Bus 全局做选择。

### 7.1 BufferPolicy

| 策略 | 行为 | 适用 |
|---|---|---|
| `BoundedQueue { size }` | 满则阻塞发布者（仅同进程） | editor 内本地订阅 |
| `DropOldest { size }` | 满则丢最早 | runtime metric |
| `DropNewest { size }` | 满则丢新 | low-priority diagnostics |
| `Coalesce { size, key_fn }` | 满则按 key 合并 | `scene.changed` 按 entity_id 合并 |
| `RateLimit { per_sec }` | 令牌桶限速 | 推给 LLM 的事件源 |
| `WindowBatch { window_ms }` | 时间窗合并成 batch | UI 刷新驱动 |

合并规则在 EventKindSpec 提供 `coalesce_hint`：

```text
coalesce_hint: Option<{
  key_fields: [FieldPath],            // 按这些字段聚合
  reducer: keep_last | merge_set | sum | union_diff,
}>
```

### 7.2 高频事件的强制策略

以下 kind 必须配合非全送达策略，registry 在校验阶段拒绝 `BoundedQueue`：

- `runtime.tick`
- `runtime.metric.sampled`
- `scene.entity.transform_changed`
- `selection.changed`（高频拖拽）

### 7.3 Slow consumer

每个订阅有 `max_lag_seq`。超过阈值：

1. 订阅状态置 `slow`，发 `diagnostics.warning.raised`。
2. 持续超过 `disconnect_lag` 则强制断开，cursor 留在原位等重连。
3. 重连后必须先 §8 resync 才可继续，不允许"接着推"。

### 7.4 Dead-letter

`at_least_once` 投递重试 N 次仍失败的事件，进入 dead-letter stream `dl:<original_stream>`，原 envelope 保留 + 错误原因。诊断面板可读，不参与正常订阅。

---

## 8. Resync

订阅者在以下时刻需要 resync：

- 首次订阅且需要"当前快照 + 增量"
- 断线重连且 cursor 落后于持久化窗口
- 收到 `bus.gap_detected` 提示

Resync 流程：

```
subscriber.request_snapshot(scope) -> {
  snapshot_ref: Handle,
  cursor: { stream_id, seq }
}
subscriber.consume(snapshot_ref)
subscriber.subscribe(start_from = from_seq(cursor))
```

snapshot 由各 store（SceneStore / SequenceStore / ModelStore）实现 `materialize_snapshot(scope)`，Bus 不持有业务状态。Bus 只保证：snapshot 的 cursor 之后的事件能拿到（在 retention 窗口内）。

snapshot ref 也是 handle 形态，不内联 envelope。

---

## 9. Persistence

三层存储：

| 层 | 介质 | 保留 | 用途 |
|---|---|---|---|
| `outbox` | 与业务库同库 | 直到 relay 成功 | 与业务事务原子 |
| `ring` | 进程内环形 + 共享内存 | 分钟级 | 同机订阅、低延迟 |
| `cold_log` | append-only 文件（per stream） | 由 RetentionClass 决定 | 回放、审计、训练数据 |

### 9.1 RetentionClass

| 等级 | ring | cold_log |
|---|---|---|
| `hot` | 是 | 30 天 |
| `warm` | 是 | 7 天 |
| `cold` | 否 | 7 天 |
| `ephemeral` | 是（小） | 否 |

`ephemeral` 严禁用于 `transaction.*`、`asset.*`、`*.promoted`，registry 阶段校验。

### 9.2 回放

`bus.replay(stream_id, from_seq, to_seq)` 从 cold_log 读取，按原 seq 与 envelope 重放给指定 subscription。回放事件 envelope 携带 `replay = true` 标记，避免触发副作用订阅者（如再次写库）误处理。

回放模式下：

- OutboxRelay 不参与
- Backpressure 仍然生效
- 写入侧订阅者必须读取 `replay` 标记并自我屏蔽

---

## 10. 跨进程 / 跨机边界

Bus 在三个进程边界之间桥接：editor、runtime、render_farm。

### 10.1 拓扑

- 同机：进程间走共享内存 ring + 本地 socket。
- 跨机：经 BridgeNode，使用结构化二进制协议（CBOR / Cap'n Proto，待选型）。
- BridgeNode 是 Bus 的逻辑成员，复用 EventKindRegistry，不允许在桥上"重命名"事件。

### 10.2 跨进程允许集

不是所有事件都跨进程。EventKindSpec 增加 `cross_process_allowed: bool`：

| 事件 | 跨进程 |
|---|---|
| `transaction.applied` | 是（agent 需要看见 editor 的修改） |
| `selection.changed` | 仅在 editor ↔ agent 之间 |
| `runtime.tick` | 否（流量太大，仅本机） |
| `runtime.metric.sampled` | 是（farm → editor） |
| `confirmation.requested` | 是（agent → editor UI） |

跨进程禁止的事件，bridge 在源端就丢弃（不进网络）。

### 10.3 时钟

跨机不能信任 monotonic_ts_ns；订阅者按 `(stream_id, seq)` + `wall_ts_utc` 排序，且明确 wall_ts 仅作展示，不作因果判断。因果判断走 `causal_seq` 与 `causation_id`。

---

## 11. 与 Context Memory Index 的对接

Memory 不是 Bus 的订阅者之一就行；二者关系强约束：

1. Memory 的所有"last diffs / unresolved issues"条目必须能反查到一个或多个 `event_id`。
2. Memory 的失效（GC）以 stream cursor 为下界：cursor 之前已被 Memory 折算的事件可被裁剪。
3. Memory 不能凭事件构造 authored / baked provenance；它只承载 envelope 携带的 provenance。
4. Memory 写入必须是 envelope 的下游，而不是平行写入业务库——避免与 outbox 路径打架。

Memory 是 Session.WorldView 的内部状态，见 `architecture.md`。

---

## 12. 与 CapabilityGraph 的对接

CapabilityGraph 的两个字段直接约束 Bus：

- `side_band_emits: [EventKind]`：声明 capability 执行时会广播哪些事件。Bus 在执行 transaction 完成后，对照声明集校验：
  - 实际发出但未声明 → 警告 + 进 `diagnostics.warning.raised`
  - 声明但未发出 → 静默允许（不强制必发）
- `read_after_write: [EventKind]`：声明调用方应在收到这些事件后再读回结果。AI agent 的执行框架据此 await。

CI 校验：side_band_emits 中的所有 EventKind 必须存在于 EventKindRegistry，否则 capability 注册失败。

---

## 13. 与 MinimalConfirmationUI 的对接

Confirmation UI 通过两个事件与 Bus 闭合：

- `ui.confirmation.requested`：由 AmbiguityScorer 发起，payload 是 Question 引用（handle，UI 端取整对象）。
- `ui.confirmation.resolved`：由 UI 发起，payload 是 Resolution 引用。

约束：

1. 这两个事件 stream = `global`，cross_process_allowed = true。
2. 不允许携带任何用户键入文本明文的同时 `redact_in_prompt = false`：destructive 二次输入的字面值在进入 LLM 视图前必须被裁掉（见 §15）。
3. resolution 的 `causation_id` 必须等于 originating Intent 的 transaction_id。

---

## 14. 失败模式与降级

| 故障 | 行为 |
|---|---|
| OutboxRelay 故障 | 业务正常提交，事件累积在 outbox；恢复后按 `event_id` 幂等补发 |
| Bridge 断连 | 远端订阅者收 `bus.gap_detected`，重连后 §8 resync |
| 持久化磁盘满 | 拒绝新事件入 cold_log，发 `diagnostics.warning.raised`；ring 仍工作；保留窗口被动缩短 |
| 单 subscriber 卡死 | 见 §7.3，标 slow → 断开，不影响他人 |
| EventKindRegistry 加载失败 | Bus 启动失败，进程不可用（事件流不可能"部分可用"） |
| payload schema 反序列化失败 | envelope 投递成功，订阅者侧 `read_payload` 返回 `SchemaMismatch`，不重试 |
| 时钟跳变 | wall_ts 异常仅打告警，不影响 seq 顺序 |

---

## 15. 给 LLM 的符号化视图

LLM 不直接订阅 Bus。它通过 `EventSymbolicView` 拿到裁剪后的窗口：

```text
EventSymbolicView {
  window: { stream_id, from_seq, to_seq, max_count },
  events: [SymbolicEvent],
}

SymbolicEvent {
  kind: EventKindId,
  stream_id: StreamId,
  seq: u64,
  causation_id: Option<TransactionId>,
  provenance: Provenance,
  summary: StructuredSummary,          // 由 payload 经 redact 与摘要后得到
}
```

裁剪规则：

1. `redact_in_prompt = true` 的字段被替换为 handle ref + 类型标签。
2. 任何向量、embedding、handle 到 image/geometry 一律不进 summary，只留"存在性"指示。
3. 用户键入的自然语言只允许出现在符合 capability `prompt_safe_inputs` 白名单的字段里。
4. `runtime.tick` / `runtime.metric.sampled` 不进入符号化视图，必要时由 Memory 折算成统计量再喂 LLM。

---

## 16. 实现顺序

1. EventKindRegistry + EventEnvelope + 基础 publish/subscribe（同进程 ring）
2. Outbox + 业务事务对齐（先服务 transaction.* 与 asset.*）
3. Cold log + replay（先服务 transaction stream，用于回放调试）
4. BackpressurePolicy 全集（先 BoundedQueue / DropOldest / Coalesce）
5. Resync + snapshot 协议（与 SceneStore / SequenceStore 联调）
6. BridgeNode（editor ↔ agent in-proc 桥优先；跨机延后）
7. SymbolicView 与 LLM agent 对接
8. Dead-letter 与诊断面板
9. Session 订阅与 WorldView 增量更新的端到端验证

---

## 17. 验收标准

1. 任何 publish 都能在 envelope 上回放出 origin / provenance / causation_id。
2. EventKindRegistry 在 CI 完成完整性校验，未声明 kind / 域错位均阻断。
3. transaction.applied 与对应 SceneStore 写入在崩溃-恢复后保持原子（outbox 重放不重复也不漏）。
4. 单 subscriber 卡死不影响其他订阅者的延迟分布。
5. 高频 stream 在订阅侧按 buffer_policy 表现可观测（合并 / 丢弃 / 限速 计数公开为 metric）。
6. Resync 流程能从冷启动恢复到与发布端一致的状态，不依赖人工对账。
7. LLM 视图中不出现任何 vector / image bytes / 渲染图 handle 之外的二进制。
8. 跨机 bridge 断连后重连，订阅者状态完整恢复，无重复消费。
9. Confirmation 流程的 requested → resolved 关联可追溯到 originating Proposal，并正确生成 UserCorrection。

---

## 18. 不在范围

- WorldDelta / Edit 字段定义（见 `architecture.md`）
- Session.WorldView 内部结构（Session 实现细节）
- 跨机协议字节级编码选型（待 Phase D 实施时定）
- Audit log / 合规导出格式（后续单独文档）

---

## 19. 后续待办

- 给出 EventKindRegistry 的初始全集（与 §2.1 各 domain 的具体 noun 闭集）
- 跨机 bridge 协议的具体二进制选型与版本协商
- Session 订阅端的 resync 协议与 WorldView 初始化流程
- replay 模式下哪些副作用订阅者是"必须屏蔽"、哪些是"可重入"，做一份分类表
- 与渲染 farm 的 metric 协议对齐（runtime.metric.sampled 的 payload schema）
