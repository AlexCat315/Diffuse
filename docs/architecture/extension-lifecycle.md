---
path: /zh/docs/architecture/extension-lifecycle
title: '扩展点、判断管线与生命周期'
description: '扩展点、判断管线与生命周期 — GuavaStudio documentation'
locale: zh
translationKey: architecture/extension-lifecycle
category: architecture
order: 100
kind: doc
---

# 扩展点、判断管线与生命周期

> **状态：四项提案的核心路径已实现并审计（2026-10-16）。** 本文区分已实现的保证与可选后续工作；各节“提案时的现状”描述迁移前的问题。确认阶段的扩展策略、AI 聊天保留和 Editor 会话作用域重构尚未实施。

DeepSeek Harness 的插件内核 Cordis [Cordis](https://github.com/cordiverse/cordis) 有四条值得借鉴的纪律：**判断走一条管线、注册即效果、依赖用声明表达、生命周期可回滚**。本项目不复用 Cordis 运行时（TypeScript / Node，无法链接进 Swift 进程），只吸收这四条纪律。四个提案相互独立，可以分别实施、分别验收。

共同目标：把"谁在什么条件下放行 / 拒绝 / 确认"与"谁注册了什么、何时回滚"从散落的手写分支，变成所有权明确、可组合、可测试、可撤回的结构。

## 概念对照

| Cordis | 本项目现状（对应物） | 本提案吸收 |
| --- | --- | --- |
| Typed Events / waterfall | `CapabilityValidator`、`CapabilityInvocationPlanner`、Editor 分支、无头 driver 各自判断 | 提案一：统一判断管线 |
| Reversible effects（注册即返回 disposer） | 各处的 `removeAll()`、`hostGeneration`、`onInvalidation` | 提案二：`DisposalScope` |
| `inject` 依赖声明 | `imports`（宿主接口）；插件之间无依赖表达 | 提案三：`requires` 插件依赖声明 |
| 插件 mount / unmount + HMR | `inspect → authorize → load → unload` + `hostGeneration` | 提案四：WASM 插件热重载 |

## 安全前提（四条提案都不得破坏的不变量）

1. 插件必须显式 `inspect → 用户授权 → load`；代码 / WIT / 权限 / schema 哈希（`authorityDigest`）变化必须使旧授权失效。
2. 插件输入输出只走获准的 WIT 契约与 revision-bound JSON 快照；沙箱与资源限额不因本提案放宽。
3. AI 与插件的写操作永远先形成草案与事务，再经确认或自动策略提交；任何管线都不能绕过撤销栈与确认流程。
4. 不引入全局可变注册中心；所有权仍然在具体的 `Session` / Editor / `PluginHostProcessClient` 对象上，随对象生命周期释放。

---

## 提案一：统一判断管线【已实现】

> 已实现：`IntentRuntime/Pipeline/CommitPipeline.swift`（管线、决策与入口类型、标准 handler），`IntentRuntimeCoordinator` 的 `submitPlan`、`registerCommitPolicy(_:)` 与确认回执重校验；Editor 的 pending / locked 准入策略迁为注册 handler（`AIRequests.installCommitPolicies`），UI / 人工 / MCP 入口在调用点标注 `entry`；可选的 `ToolPolicy`（工具调用策略缝，见"迁移步骤"第 3 条与下节）。测试：`IntentRuntimeTests/CommitPipelineTests.swift`、`AIRuntimeTests/ToolPolicyTests.swift`、`EditorToolPolicyTests`、`EditorAIRequestPolicyTests`、`EditorAgentTransactionTests`、`EditorProjectToolsTests`。

### 提案时的现状

同一语义"在动作前后做判断"散落在至少 10 处，入口不同、互不知道彼此存在：

| 判断 | 位置 | 触发入口 |
| --- | --- | --- |
| 发布阶段 gate | `CapabilityRuntime/Release/ReleasePhaseGate.swift`，经 `CapabilityValidator.validate`、`CapabilityInvocationPlanner.init` | 全部 |
| 前置条件（实体存在、选中、可编辑、组件存在） | `CapabilityRuntime/Drafts/PreconditionChecker.swift`，经 `CapabilityValidator.validate` | 全部 |
| 审批升级与确认问题生成（写操作、destructive、歧义） | `IntentRuntime/Invocation/CapabilityInvocationPlanning.swift` 的 `plan(transaction:context:)` | 全部 |
| 插件 authority / 版本 / schema / side-effect 检查 | 同文件的 `invocationRecordDenialReason`；`AIRuntime/Tools/CapabilityExposureSessionStore.swift` 的 `snapshotAuthoritiesAreCurrent` | 全部 |
| forbidden / automatic / staged 分流 | `IntentRuntime/IntentRuntimeCoordinator.swift` 的 `submitPlannedTransaction` | 全部 |
| 播放中禁止场景编辑 | `EditorCore/Application/AI/AIRequests.swift` 的 `submitNaturalLanguageIntent`（`isSceneAuthoringEnabled`） | UI / MCP |
| 忙碌与待确认拒绝 | `EditorCore/AI/Chat/EditorAIRequestPolicy.swift` + `runPlanTransaction` | UI / MCP |
| 锁定实体检查 | `runPlanTransaction`、`resolvePendingConfirmation` | UI / MCP |
| 确认回执前重新校验（plan 重跑、锁定复查、任务目标复查） | `IntentRuntimeCoordinator.resolvePlanConfirmation`、`AIRequests.resolvePendingConfirmation` | UI / MCP |
| 无头自动确认 | `EditorUI/Launch.swift` 的 `--approve-scene-edits` → `HeadlessEditorDriver.approvePendingPreview` | headless |
| 人工意图入口 | `EditorCore/Application/AI/IntentExecution.swift` 的 `submitResolvedIntent` | UI 工具栏 |

### 问题

- 同一条策略在三个入口（编辑器 UI、MCP、无头自动化）里各写一份，新策略要改多处，容易漏；
- 无法在测试里表达"策略组合"（例如"这个入口 = 阶段 gate + 锁定检查 + 自动确认"）；
- 未来的审计、第三方策略、按项目分级授权没有稳定挂点。

### 目标

一个有序、可短路、可改写请求、注册可撤销的**提交管线** `CommitPipeline`，作为 `IntentRuntimeCoordinator` 提交路径的唯一策略缝。工具侧另有**策略缝** `ToolPolicy`，覆盖模型工具调用执行前（`Session` 工具循环、项目工具与 MCP 草案创建），见本节末。

### API（已实现）

```swift
// Engine/Sources/IntentRuntime/Pipeline/CommitPipeline.swift（已实现）

/// 提交来源。策略可据此区分入口；它不授予任何权限。
public enum CommitEntry: Sendable, Equatable {
    case ui
    case mcp(sessionID: String)
    case headless
    case human
}

/// 一次提交在管线中流转的状态。handler 返回改写后的副本；改写后的上下文也用于暂存和确认重校验。
public struct CommitRequest: Sendable {
    public var transaction: TransactionIR
    public var capabilityContext: CapabilityInvocationContext?
    public var entry: CommitEntry
    public var questions: [ConfirmationQuestion]   // 规划 / 策略累积
    public var warnings: [String]
}

public enum CommitDecision: Sendable {
    case proceed(CommitRequest)   // 继续（可改写）
    case deny(CommitDenial)       // 短路：run 抛 CommitPipelineError.denied
}

public struct CommitDenial: Sendable, Equatable {
    public enum Code: String, Sendable {
        case releasePhase, precondition, pluginAuthority, lockedEntities
        case sceneNotEditable, busy, pendingConfirmation, policy
    }
    public var code: Code
    public var reason: String
}

public struct CommitPipeline: Sendable {
    public typealias Handler = @Sendable (CommitRequest) throws -> CommitDecision
    public init(handlers: [Handler] = [])
    public func appending(_ handler: @escaping Handler) -> CommitPipeline
    /// 返回最终请求状态（含累积的 questions / warnings）。
    public func run(_ request: CommitRequest) throws -> CommitRequest
}

// IntentRuntimeCoordinator（已实现）
public func registerCommitPolicy(_ handler: @escaping CommitPipeline.Handler) -> Registration
public func submitPlan(_ transaction: TransactionIR,
                       executionContext: inout TransactionExecutionContext,
                       capabilityContext: CapabilityInvocationContext? = nil,
                       entry: CommitEntry = .ui) throws -> CapabilityInvocationResult
```

与早期草案的取舍：

- **执行顺序**：注册的入口策略先运行，标准 gate 随后。现状里 Editor 的 pending / locked 检查发生在协调器之前，先注册后标准可保持拒绝次序不变；标准 gate 永远执行，因此入口策略无法绕过任何验收。
- 没有单独的 `.requireApproval`：策略可以提升 `transaction.approvalPolicy` 或追加 `questions`；任何非空问题列表都会强制进入确认。破坏性问题留在第二轮，其他策略/规划问题保留在第一轮，不得丢弃。
- 内置顺序封装在 `CommitPipeline.standard(planner:)`（internal，每次提交按当前 planner 组装）；`resolvePlanConfirmation` 的确认回执重校验只跑标准 gate，不跑入口策略（pending 确认在回执阶段天然仍存在，不能作为拒绝条件）。

### 内置 handler 与迁移映射

| 判断 | 复用现有实现 | 安装方 | 状态 |
| --- | --- | --- | --- |
| `releasePhase` | `ReleasePhaseGate.deniedReason` | `standard` | ✅ |
| `precondition` | `PreconditionChecker.check` | `standard` | ✅ |
| `pluginAuthority` | `invocationRecordDenialReason` 中的检查部分 | `standard` | ✅ |
| `approvalEscalation` | planner 的写操作 / destructive / 歧义升级规则 | `standard` | ✅ |
| `pendingConfirmation` | `EditorPlanSubmissionError.pendingConfirmation` | Editor `installCommitPolicies` | ✅ |
| `lockedEntities` | `EditorPlanSubmissionError.lockedEntities` | Editor `installCommitPolicies` | ✅ |
| 播放中 / 忙碌 | `submitNaturalLanguageIntent` 的预检 + `EditorAIRequestPolicy` | 预检保留 | 保留 |
| 无头自动确认 | `HeadlessEditorDriver.approvePendingPreview` | 确认阶段 | 保留 |

两点说明：

- **播放中与忙碌仍留在预检**：它们发生在规划之前（未产生事务、会话请求尚未入队），语义是"这个请求根本不该开始"，不是"这个事务不该提交"；能力级"场景不可编辑"已由 planner 前置条件覆盖。
- **无头自动确认不迁入本管线**：它是确认阶段的策略（第一轮可逆确认自动接受、破坏性问题仍显式等待），把它改写成 `approvalPolicy = .automatic` 会绕过两轮确认与破坏性门槛。它保留在 `HeadlessEditorDriver`；如果将来确认阶段需要可注册策略，应新增独立缝，而不是复用提交管线。

### 迁移步骤

1. **纯重构【已完成】**：引入管线与决策类型；内置 handler 逐条包裹现有调用（`requireCapabilityContext` → planner → `rejectForbiddenPolicy`），外部行为完全不变（`IntentRuntime` 全族测试未改断言即通过）；`submitPlan` 与 `resolvePlanConfirmation` 的确认回执重校验都改走同一条标准管线。
2. **入口迁移【已完成】**：Editor 的 pending / locked 检查迁为注册 handler；UI（AI 规划）、人工（工具栏 / 快捷键）、MCP 三条路径在调用点标注 `entry`（`.ui` / `.human` / `.mcp(sessionID:)`），散落分支删除。
3. **工具调用策略缝【已完成】**`ToolPolicy`：在模型工具调用执行前评估，用于审计与执行前拒绝。实现与缝隙位置见下节。

### 验收

- 现有行为不变：`IntentRuntime` 全族、`Transaction verification`、`CapabilityRuntimeTests`、`AI capability exposure`、`AI workflow authority`、`PluginRuntime security boundary`、Editor 构建、`Editor AI request policy`（7，含 pending / locked / 确认阶段复检）、`Agent authoring transactions`（2）、`AI and MCP project workspace`（3）全部通过（2026-10-16）；
- 已完成的新增（`CommitPipelineTests`）：handler 顺序、首个 deny 短路、请求改写与确认材料累积、标准管线的上下文要求、forbidden 拒绝、注册策略先于标准 gate 且可撤销、策略问题强制确认、改写上下文保留和两轮问题不丢失；
- `ToolPolicy` 新增（`AIRuntimeTests/ToolPolicyTests`）：空策略直通 / 改写 / 首个 deny 短路 / handler 错误传播、会话拒绝作为工具结果回给模型且规划继续、草案创建的拒绝与改写；Editor 集成（`EditorToolPolicyTests`）：注入策略在项目工具执行前拦截（拒绝无文件副作用、MCP 写调用只评估一次、内置只读适配器使用改写参数）；
- 待做（可选）：确认阶段的可注册策略（如有真实需求）。

### ToolPolicy（工具调用策略缝，已实现）

与 `CommitPipeline` 同构但位置更早、粒度更细（每次工具调用；覆盖 `CommitPipeline` 看不到的只读调用与草案创建）：

```swift
// AIRuntime/Tools/ToolPolicy.swift（已实现）
public struct ToolCall: Sendable, Equatable { name / arguments(JSON) / origin }
public enum ToolCallOrigin: Sendable, Equatable { case agentSession, mcp }
public enum ToolPolicyDecision: Sendable { case allow(ToolCall), deny(ToolPolicyDenial) }
public struct ToolPolicyDenial: Sendable, Equatable { code / reason }
public enum ToolPolicyError: Error, Sendable, Equatable { case denied(ToolPolicyDenial), invalidRewrite }
public struct ToolPolicy: Sendable {
    public typealias Handler = @Sendable (ToolCall) throws -> ToolPolicyDecision
    public func evaluate(_ call: ToolCall) throws -> ToolCall   // 有序、首个 deny 短路；空策略直通
}
```

Editor 集成中每次调用评估一次，缝隙位置：

| 缝隙 | 覆盖 | origin |
| --- | --- | --- |
| `Session` 两种推理循环与 `handleCapabilityToolCall` | 能力工具、`search_capabilities`、`submit_plan`、内联 `execute_edit_plan` / `find_entities` | `.agentSession` |
| `EditorApplication.executeProjectTool` | 项目工具（助手与 MCP 的共用入口） | 调用方传入 |
| `CapabilityExposureSessionStore.createDraft` | MCP 写草案 | `.mcp` |
| `MCPIntegration.mcpInvokeCapability` | MCP 只读能力调用 | `.mcp` |

拒绝语义：助手会话把拒绝作为**工具结果**回给模型（"Tool call denied: …"，模型可换路继续，不算会话失败，见 `ToolPolicyTests.sessionDenialIsAnObservation`）；MCP 返回失败结果。改写语义：只允许改写 arguments，工具名和 origin 改变会抛出 `invalidRewrite`；改写后的参数仍须通过 JSON 和能力 schema 校验。会话不能在改写无效时退回执行原参数。项目工具的策略由宿主 executor 在实际执行前评估，独立使用 `Session` 的宿主也必须在其项目工具适配器安装策略；`Session(toolPolicy:)` 不替代这个边界。

注入方式：`Session(toolPolicy:)`、`CapabilityExposureSessionStore(toolPolicy:)`、`EditorApplication(toolPolicy:)`（默认 `nil` = 直通；Editor 默认注入审计策略）。首个注册方 `AI/Tools/Audit.swift` 的 `EditorToolAudit.policy`：对**可变**项目工具调用做非阻断审计（LogSystem `com.guava.editor.tool-audit`，只记 origin / 工具名 / 参数键名 / 字节数，不复制载荷）；执行前拒绝留给后续真实需求注册。

---

## 提案二：注册与撤销成对、按作用域释放【已实现】

> 实现位置：`CapabilityRuntime/Support/Disposal.swift`（`Registration` / `DisposalScope`）、`AIRuntime/Tools/CapabilityExposureSessionStore.swift`（Entry 作用域）。测试：`CapabilityRuntimeTests/DisposalScopeTests.swift`。

### 提案时的现状

撤销靠手写、分散、重复，靠"记得调用"：

| 位置 | 现状 |
| --- | --- |
| `CapabilityExposureSessionStore.replaceRegistry` / `setWorkflowScope` / `replacePluginAuthorities` | 三处各自 `drafts.removeAll()` + `sessions.removeAll()`，逻辑相同、复制三份 |
| `removeSession`、`purgeExpired`、`sessionEntry` 驱逐 | 第四、五处同样的清理 |
| `CapabilityDraftStore` | actor 内 TTL + `consume` / `removeAll`，创建者与释放者没有配对关系 |
| `EditorApplication.activatePluginExecutor` | 换插件即换 `Session`、取消在飞请求、清空聊天历史——一次全量重建 |
| `PluginHostProcessClient` | `generation` + `onInvalidation` 取消挂起请求；Editor 收到回调后全量失效所有绑定 |

项目里此前没有通用的"注册即效果"原语；提案二实现了 `DisposalScope` / `Registration`，Entry 的草案清理已迁移；其余应用点的状态在下文逐项标明。

### 目标

一个最小、无领域依赖的原语：**每次注册 / 分配返回撤销句柄；句柄交给最近生命周期的作用域，作用域按逆序统一回滚**。不引入全局容器，不改变任何现有 fail-closed 语义。

### API

```swift
// Engine/Sources/CapabilityRuntime/Support/Disposal.swift（已实现）
// 位置：放在 CapabilityRuntime——它是 IntentRuntime / AIRuntime / PluginRuntime
// 共同依赖的最低层；不新开模块。

/// 一次注册的撤销句柄。幂等：重复 dispose 只执行一次 teardown；所有并发调用等待同一次完成。
public struct Registration: Sendable {
    public init(_ revoke: @escaping @Sendable () async -> Void)
    public func dispose() async
}

/// 逆序回滚的作用域。归最近的生命周期对象所有，不是全局单例。
public final class DisposalScope: @unchecked Sendable {
    public init()
    /// 注册撤销动作；返回的 Registration 可提前单独撤销。
    @discardableResult
    public func track(_ revoke: @escaping @Sendable () async -> Void) -> Registration
    /// 接管一个已有句柄（所有权转移）。
    public func track(_ registration: Registration)
    /// 按注册的逆序执行全部撤销；并发释放等待同一任务；下一代在前一代完成后释放。
    public func disposeAll() async
}
```

teardown 闭包是 `async`，因为草稿清理需要 `await` 到 `CapabilityDraftStore` actor。`dispose` / `disposeAll` 等待清理完成；同一句柄并发释放不允许提前返回。`disposeAll` 原子摘取当前一代，释放期间新增注册留给下一次释放；重叠的代际清理串行执行。作用域要求所有者显式调用，不依赖异步 deinit；teardown 不得递归等待自身的 dispose。

### 应用点

- **`CapabilityExposureSessionStore`【已实现】**：每个 `Entry` 持有一个 `DisposalScope`，创建时登记一次 `drafts.removeAll()`；`replaceRegistry` / `setWorkflowScope` / `replacePluginAuthorities` / `removeSession` / `activeEntry` 过期丢弃 / `sessionEntry` 驱逐 / `purgeExpired` 七条路径全部改为 `scope.disposeAll()`，teardown 不再手写 `removeAll`（唯一一次登记在 `sessionEntry`）。
- **`CapabilityDraftStore`【已实现（作为上一条的注册）】**：草稿清理作为 Entry 作用域的注册；DraftStore 自身的 TTL 与 `consume` 语义不变。
- **`PluginHostProcessClient`【暂缓】**：当前请求交换是同步的、回调只有单一 `onInvalidation`，没有可回滚的多注册点；等出现挂起请求集合或 async 请求管线时再接入。
- **`EditorApplication.activatePluginExecutor`【待办】**：插件 executor 重建时，旧会话的注册（观察、工具、请求）统一回滚，而不是散落 cancel + 清空。

### 验收

- 行为不变：`CapabilityRuntimeTests`（含 `Disposal scope`）、`AI capability exposure`、`AI workflow authority`、`PluginRuntime security boundary`、`IntentRuntime` 全族、Editor 构建已通过；本次验证范围以文末命令为准（2026-10-16）；
- 新增：重复 dispose 幂等、逆序回滚、释放后可复用、句柄转移、并发注册不丢失、并发 dispose 等待完成与跨代清理有序；
- 代码层面：`CapabilityExposureSessionStore` 的 teardown 路径不再直接调用 `drafts.removeAll()`。

---

## 提案三：插件依赖用声明表达【已实现】

> 已实现：`PluginRuntime/Contract/Requirements.swift`（`PluginRequirement`、violation / 错误、`PluginRequirementResolver`）、`Contract/PluginManifest.swift`（`requires` 字段与校验）、`PluginAuthorization.swift`（授权绑定 `requires`）、Editor `Plugins.enablePlugin` / `disablePlugin`（启用解析、停用拒绝）。测试：`PluginRuntimeTests/PluginRequirementTests.swift`。真实宿主的提供方/依赖方夹具在 `EditorPluginReloadTests` 中验证；组合层的环由纯值测试验证。

### 提案时的现状

- `plugin.json`（`PluginRuntime/Contract/PluginManifest.swift`）此前只有 `id / version / name / description / access / imports / composable_host_capabilities`，**没有插件间依赖字段**；
- 能力组合靠手工：`PluginCapabilityRegistryBuilder.build(base:bindings:)` 要求调用方给出完整 `bindings` 数组，`CapabilityRegistry.appending` 顺序由代码决定；
- 加载顺序与前置关系只存在于宿主目录约定和文档里，不进入契约；缺依赖时表现为运行时"能力找不到"。

### 已实现的契约

```json
{
  "id": "studio.gizmo",
  "version": 2,
  "name": "Gizmo",
  "access": "reversibleWrite",
  "imports": ["guava:scene/query"],
  "requires": [
    { "kind": "plugin", "id": "studio.core", "minimum_version": 2 },
    { "kind": "capability", "id": "studio.core.draw" }
  ]
}
```

```swift
// PluginRuntime/Contract/Requirements.swift（已实现）
public struct PluginRequirement: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case plugin, capability }
    public var kind: Kind
    public var id: String
    public var minimumVersion: Int?   // 对应插件版本或能力契约最低版本
}
```

> 实现取舍：草案里用过 `"plugin:studio.core@>=1"` 迷你语法；最终改为结构化对象，与 manifest 其余字段同为 Codable 值，不再引入第二套字符串解析器。

### 加载与组合规则（已实现，相对草案做了收紧）

1. **校验**：格式、重复（同 kind+id）、自引用（plugin 自指或 capability 指向自身的单个 WIT 导出；不同的嵌套插件 ID 不算自引用）在包校验阶段拒绝，归入 `PluginManifestValidationError`。
2. **解析**：启用是**增量**的——新插件只能在全部依赖已挂载时启用，缺失依赖整体拒绝并逐条列出。
3. **排序与组合边界**：Editor 增量启用要求依赖先挂载；`PluginCapabilityRegistryBuilder` 还在组合完整绑定集时按依赖逐步解析，拒绝缺失、版本不足及无解析进展的环，输入数组无需预排序。重建不能把失去依赖的插件继续暴露。
4. **组合**：`capability:` 依赖按"内置能力 + 已启用插件契约"的版本表解析；`plugin:` 依赖比较已启用插件的 manifest 版本。
5. **权限**：`requires` 不改变 `access` / `imports`，不触发自动授权；被依赖插件仍需自己的 `PluginAuthorizationRecord`。`requires` 同时绑定进 `PluginAuthorizationRecord`（比较与 `authorityDigest` 都包含它），所以改动依赖列表会使旧授权失效、需要重新授权。
6. **停用**：`disablePlugin` 同时检查 plugin 依赖与该插件实际 WIT 契约 ID 上的 capability 依赖，存在依赖方时**拒绝**并列出（不根据 ID 前缀猜测归属，不级联卸载）；调用方先停用依赖方。撤销授权若因依赖或忙碌被拒，保留仍挂载插件的授权记录。
7. **fail-closed**：校验或解析失败不发布新绑定；授权记录必须包含 `requires`，缺字段的旧记录直接拒绝解码并要求重新授权，不维护兼容解码层。manifest 可以省略这个可选配置，默认无依赖。

### 验收

- `PluginRuntimeTests`（覆盖 manifest 缺省、校验拒绝、缺失/版本不足、两类依赖方、授权往返与缺字段拒绝、组合环拒绝）全部通过（2026-10-16）；
- Editor 构建通过；`EditorPluginAuthorizationStoreTests`（3）、`EditorPluginManagementSecurityTests`（3）通过；
- 顺带修复：`PluginRuntimeTests.builtExecutable` 改为在多个 scratch 目录候选中取**最新构建**的宿主二进制（此前会被 `.build/studio` 的旧副本抢先命中）。

---

## 提案四：WASM 插件热重载【已实现】

> 已实现：`Application/Plugins/Reload.swift` 的 `EditorApplication.reloadPlugin(id:)`（同 authority 重挂载）、`CapabilityExposureSessionStore` 的收窄失效、管理面板"Reload"按钮（`reloadPluginFromManagement`，stale 时自动转入重新授权流程）、dev 目录监视（`--watch-plugins` / `GUAVA_WATCH_PLUGINS=1`，默认关闭）、无头/MCP 脚本化 `reload_plugin`、Editor 级集成测试 `EditorPluginReloadTests`。顺带修复 `PluginHostProcessClient.unloadPlugin(at:)` 对空响应的误判（每次卸载都会误报 `communicationFailed`，此前 `disablePlugin` 一直带着这个假错误）。

### 现状（提案时）

- 流程：`inspectPlugin` → 用户授权（`PluginAuthorizationRecord`，绑定代码 / WIT / 权限 / schema 哈希）→ `enablePlugin` → `PluginHostProcessClient.loadPlugin` → `PluginExecutionBinding`（含 `hostGeneration` 与 `authorityDigest`）→ 重建 `PluginCapabilityExecutor` → `activatePluginExecutor` **全量重建**：换 `Session`、取消在飞请求、清空聊天历史；
- `GuavaPluginHost` 重启：`onInvalidation` → 所有绑定失效；
- 任一插件的 authority 变化：`CapabilityExposureSessionStore` 丢弃**全部**会话与草稿；
- 已有的安全基础是好的：`hostGeneration`、`authorityDigest`、使用点双重校验（`invocationRecordDenialReason`、`snapshotAuthoritiesAreCurrent`）。

### 已实现的语义

**一步重挂载（`reloadPlugin`）**：对已启用插件重新 `inspect`，`PluginAuthorizationRecord.isStillValid` 通过才继续；随后同一 `hostGeneration` 内 `unload + load`，先构建新 executor，再发布匹配的绑定、authority 与组件声明。AI Session 激活仍采用原有的取消与重建步骤。卸载开始后的任一步失败（含 unload 失败）→ 撤下目标与递归依赖方并释放组件声明（`discardAfterFailedReload`），返回显式错误；不保留缺依赖的绑定。检查/授权失败发生在卸载前，不改变当前挂载；package 已变化时抛 `pluginAuthorizationStale`，且**在 unload 之前**抛出，旧绑定保留（源包变化后宿主仍拒绝 prepare，不保证旧构建可继续执行），用户走既有管理流程重新授权。

**收窄失效（scoped invalidation）**：`replaceRegistry` / `replacePluginAuthorities` 不再一律清空会话——

- 非插件策略身份变化（域名、阶段、上限等，`enabledPluginIDs` 除外）→ 整体失效（保守）；
- 插件 authority 变化 / 被停用 / 被移除，或 snapshot 中契约变化 → 丢弃相关会话；authority、契约、非插件策略身份均未变时保留；
- 纯内置会话不因插件目录增删本身而失效。保留会话可继续发现新插件并创建草案：验证使用本次 registry 值，不能沿用 DraftStore 创建时的旧注册表。所有跨 actor 等待在返回草案/确认材料前重查 Entry 身份，避免返回已撤销的一代。

> 更正早期草案的一处内部矛盾：编辑 `component.wasm` 必然改变 `componentHash`，即 **authority 必变、必须重新授权**——这是安全模型的要求，不是遗漏。"authority 未变的一步重挂载"覆盖的是同构建的恢复场景（重拷包、宿主状态复位、故障重挂载），它的价值在于**不再牵连其他插件的会话与草稿**。开发循环因此是：改码 → 一次重新授权 → 重挂载。

### 安全不变量（均保持）

- 重挂载**仅**在 `authorityDigest` 完全一致时允许；任何差异都要求重新授权；
- 启用、停用、重载互斥执行，重叠操作明确拒绝；先构建 executor，再发布匹配的 registry / authority；暴露会话在 actor 中一起替换二者；
- 旧草稿在使用点继续双重校验（现状已有，不依赖失效的完整性）；
- 卸载前检查失败保留旧绑定；卸载开始后失败撤下目标及失去依赖的插件，错误必须可见；宿主故障还须清除全部失效绑定和组件声明；
- 自动重载绝不自动授权。文件监视默认关闭，仅显式 dev 启动参数开启。

### 入口（已实现）

1. **管理面板**："Reload" → `reloadPluginFromManagement`；stale 时进入 `inspectPluginForManagement`。用户批准后先检查依赖并停用旧绑定，再启用获准的新包；依赖方仍在时拒绝替换，用户需先停用它们。
2. **dev 目录监视**：`Application/Plugins/Monitor.swift` 的 `PluginPackageMonitor` 以轮询方式监视已启用包的 `plugin.json` / `capabilities.wit` / `component.wasm`；变化后同 authority 自动重挂载，authority 变化则走管理面板重新授权。默认关闭，`--watch-plugins` / `GUAVA_WATCH_PLUGINS=1` 开启；绑定变化经 `activatePluginExecutor` 重设监视集合并重置快照。遇到正在执行的插件更新时等待后处理本次文件变化；监视器归 `PluginSession` 所有，shutdown 时停止。监视基于文件大小和修改时间，不能保证发现保留这两项属性的字节替换；每次实际加载仍重新校验内容哈希。
3. **无头 / MCP**：Editor `handleMCPAction` 新增 `reload_plugin`（参数 `plugin_id`），GuavaMcp 暴露同名工具；与按钮共用同一套门（package 必须匹配存储授权）。
4. **会话保留（可选，未做）**：第一版仍保留 `activatePluginExecutor` 的 AI Session 重建与聊天清空。
5. **Editor 级集成测试**：`EditorPluginReloadTests` 用真实 `GuavaPluginHost` + 运行时编译的 fixture 包覆盖 enable → reload（同 generation）→ 改包被拒（旧绑定仍在）→ 管理面板重新授权并替换 → disable；另测 capability 依赖阻止停用/撤权、重叠更新拒绝、宿主代际丢失后的目标及依赖方回滚。

### 验收

- `CapabilityExposureTests`：收窄失效的四种场景；
- `EditorPluginReloadTests`：真实宿主端到端（含宿主二进制定位与 WAT 编译夹具）；
- `PluginRuntimeTests`（含 typed unload、停止后代际失效与重复故障回归）、`WorkflowScopeTests`（3）、Editor 构建、`EditorPluginAuthorizationStoreTests`（3）、`EditorPluginManagementSecurityTests`（3）、`guava-dev validate mcp-protocol`（工具清单新增 `reload_plugin`）全部通过（2026-10-16）。

---

## 实施顺序与依赖

| 顺序 | 提案 | 依赖 | 行为变化 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 二：`DisposalScope` | 无 | 无（纯结构） | ✅ 已实现（2026-10-15） |
| 2 | 一：`CommitPipeline` | 二（注册撤销） | 无（纯重构包一层） | ✅ 已实现（2026-10-16，含 `ToolPolicy`） |
| 3 | 三：`requires` | 无 | 有（新增契约字段） | ✅ 已实现（2026-10-16） |
| 4 | 四：热重载 | 一 + 二 | 有（开发流程） | ✅ 已实现（2026-10-16） |

各项可独立验收；本次审计同时验证跨提案的依赖、确认与撤销边界。

## 明确不做

- 不引入运行时 DI 容器或全局服务定位；Cordis 的 profile / bundle / patch 配置分层不落地；
- 不做 Swift 代码的动态装载；插件重载覆盖 WASM 及纯声明包，声明式重载只替换领域快照；
- 不改变插件授权、沙箱、资源限额语义；
- 不为兼容保留双轨：迁移完成即删除旧分支（遵循仓库 AGENTS.md 的迁移约定）。

## 验收入口

```sh
swift test --package-path Engine --filter 'CapabilityRuntimeTests|IntentRuntimeTests|PluginRuntimeTests|AIRuntimeTests'
swift test --package-path Editor --filter 'EditorPluginReloadTests|EditorToolPolicyTests|EditorPluginAuthorizationStoreTests|EditorPluginManagementSecurityTests|EditorAIRequestPolicyTests|EditorAgentTransactionTests|EditorProjectToolsTests|EditorDiagnosticsTests|WorkstationTests'
swift build --package-path GuavaMcp
swift run --package-path Tools/Developer guava-dev validate mcp-protocol
swift run --package-path Tools/Developer guava-dev maintainability
npm --prefix Platforms/Web/Plugins test
```

本次审计在 macOS 验证：Engine 447 项、Editor 26 项、Web 单元测试 6 项；GuavaMCP 构建、MCP 协议检查与维护性检查通过。跨平台运行结论仍须由各平台 CI / 真机 gate 验证。

## 插件平台的声明式生命周期

平台契约已支持无运行时包、版本化贡献点及资源哈希授权。声明式包的检查、启用、停用与重载直接由编辑器处理，不经过 WASM 宿主；每个编辑器会话独立持有主题目录，目录变更通过主题环境重绘，不触发全窗口重建或 AI 会话替换。

统一 `PluginManager`、按贡献注册的 `Registration` / `DisposalScope`、事件激活和领域失效收窄仍按 `specs/plugin-platform/tasks.md` 阶段 2 推进。当前 `activation` 只校验声明格式，运行时继续使用现有加载方式。资源、主题契约和命令见 [插件执行](plugin-execution.md)。
