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

> **状态：设计提案，未实现。** 本文的"现状"对应当前代码；"目标 / 草案"是待评审、分步实施的内容。实施完成前，`docs/architecture/gaps.md` 式的"已实现 / 未实现"标记不适用于本文。

DeepSeek Harness 的插件内核 Cordis [https://github.com/cordiverse/cordis](cordis) 有四条值得借鉴的纪律：**判断走一条管线、注册即效果、依赖用声明表达、生命周期可回滚**。本项目不复用 Cordis 运行时（TypeScript / Node，无法链接进 Swift 进程），只吸收这四条纪律。四个提案相互独立，可以分别实施、分别验收。

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

## 提案一：统一判断管线

### 现状

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

一个有序、可短路、可改写请求、注册可撤销的**提交管线** `CommitPipeline`，作为 `IntentRuntimeCoordinator` 提交路径的唯一策略缝。第二阶段可选增加**工具策略缝** `ToolPolicy`，覆盖模型工具调用执行前（`Session` 工具循环与 MCP 草稿创建）。

### API 草案

```swift
// Engine/Sources/IntentRuntime/Pipeline/CommitPipeline.swift（草案）

/// 一次提交的输入。handler 可以整体替换它。
public struct CommitRequest: Sendable {
    public var transaction: TransactionIR
    public var capabilityContext: CapabilityInvocationContext?
    public var entry: CommitEntry
}

/// 提交来源只用于策略判断与诊断，不授予任何权限。
public enum CommitEntry: Sendable, Equatable {
    case ui
    case mcp(sessionID: String)
    case headless
    case human          // 工具栏 / 快捷键等本地人工入口
}

public enum CommitDecision: Sendable {
    case proceed(CommitRequest)                      // 可改写（补上下文、附加证据）后继续
    case requireApproval([ConfirmationQuestion])     // 升级为确认（复用现有两轮确认机制）
    case deny(CommitDenial)                          // fail-closed
}

public struct CommitDenial: Sendable, Equatable {
    public enum Code: String, Sendable {
        case releasePhase, precondition, pluginAuthority, lockedEntities
        case busy, pendingConfirmation, sceneNotEditable, policy
    }
    public var code: Code
    public var reason: String
}

/// 不可变快照式管线：组合发生在构造点，运行不可变。
public struct CommitPipeline: Sendable {
    public typealias Handler = @Sendable (CommitRequest) throws -> CommitDecision
    public init(handlers: [Handler] = Self.standard)
    /// 内置：阶段 gate → 前置条件 → 插件 authority → 审批升级。
    public static let standard: CommitPipeline
    public func run(_ request: CommitRequest) throws -> CommitOutcome
}

public struct CommitOutcome: Sendable {
    public var request: CommitRequest
    public var questions: [ConfirmationQuestion]
    public var warnings: [String]
}
```

长期存活的注册（例如 Editor 在后台为某个项目追加策略）通过提案二的 `Registration` 撤销：

```swift
// 由持有者（Editor 的项目会话）管理；管线本身仍是值。
public mutating func register(_ handler: CommitPipeline.Handler) -> Registration
```

### 内置 handler 与迁移映射

| handler | 复用现有实现 | 默认安装方 |
| --- | --- | --- |
| `releasePhase` | `ReleasePhaseGate.deniedReason` | `standard` |
| `precondition` | `PreconditionChecker.check` | `standard` |
| `pluginAuthority` | `invocationRecordDenialReason` 中的检查部分 | `standard` |
| `approvalEscalation` | planner 的写操作 / destructive / 歧义升级规则 | `standard` |
| `lockedEntities`、`sceneNotEditable`、`pendingConfirmation`、`busy` | Editor 现有分支 | Editor 注册 |
| `headlessAutoApproval` | `--approve-scene-edits`（仅自动确认可逆预览；破坏性仍走显式确认） | 无头启动时注册 |

### 迁移步骤

1. **纯重构**：引入管线与决策类型；内置 handler 逐条包裹现有调用，外部行为完全不变（现有测试必须全绿）。
2. Editor / MCP / 无头把各自分支迁成注册 handler；删除散落分支，只保留管线一个入口。
3. （可选，第二阶段）`ToolPolicy`：在 `AIRuntime` 工具循环（`Session.infer` 的工具调用处理）与 MCP 草稿创建前设同样的管线语义，用于审计与执行前拒绝。

### 验收

- 现有：`swift test --package-path Engine`（`CapabilityRuntimeTests`、`IntentRuntimeTests`、`AIRuntimeTests`）、`swift test --package-path Editor`（`EditorAIRequestPolicyTests` 等）全部通过；
- 新增：handler 顺序、短路、请求改写、注册撤销；同一策略在 UI / MCP / 无头三种入口行为一致；无头自动确认不会放行破坏性操作。

---

## 提案二：注册与撤销成对、按作用域释放

### 现状

撤销靠手写、分散、重复，靠"记得调用"：

| 位置 | 现状 |
| --- | --- |
| `CapabilityExposureSessionStore.replaceRegistry` / `setWorkflowScope` / `replacePluginAuthorities` | 三处各自 `drafts.removeAll()` + `sessions.removeAll()`，逻辑相同、复制三份 |
| `removeSession`、`purgeExpired`、`sessionEntry` 驱逐 | 第四、五处同样的清理 |
| `CapabilityDraftStore` | actor 内 TTL + `consume` / `removeAll`，创建者与释放者没有配对关系 |
| `EditorApplication.activatePluginExecutor` | 换插件即换 `Session`、取消在飞请求、清空聊天历史——一次全量重建 |
| `PluginHostProcessClient` | `generation` + `onInvalidation` 取消挂起请求；Editor 收到回调后全量失效所有绑定 |

项目里目前没有通用的"注册即效果"原语（已确认 Engine 源码中无 `DisposalScope` / `Registration` 类实现）。

### 目标

一个最小、无领域依赖的原语：**每次注册 / 分配返回撤销句柄；句柄交给最近生命周期的作用域，作用域按逆序统一回滚**。不引入全局容器，不改变任何现有 fail-closed 语义。

### API 草案

```swift
// Engine/Sources/CapabilityRuntime/Support/Disposal.swift（草案）
// 位置：放在 CapabilityRuntime——它是 IntentRuntime / AIRuntime / PluginRuntime
// 共同依赖的最低层；实现时如需更底层可移入 EngineKernel，不新开模块。

/// 一次注册的撤销句柄。幂等：重复 dispose 无副作用。
public struct Registration: Sendable {
    private let revoke: @Sendable () -> Void
    public init(_ revoke: @escaping @Sendable () -> Void)
    public func dispose()
}

/// 逆序回滚的作用域。归最近的生命周期对象所有，不是全局单例。
public final class DisposalScope: @unchecked Sendable {
    public init()
    /// 注册撤销动作；返回的 Registration 可提前单独撤销。
    @discardableResult
    public func track(_ revoke: @escaping @Sendable () -> Void) -> Registration
    /// 接管一个已有句柄（所有权转移）。
    public func track(_ registration: Registration)
    /// 按注册的逆序执行全部撤销；幂等；释放后仍可继续 track。
    public func disposeAll()
}
```

### 应用点

- **`CapabilityExposureSessionStore`**：每个 `Entry` 持有一个 `DisposalScope`；`replaceRegistry` / `setWorkflowScope` / `replacePluginAuthorities` / `removeSession` / `purgeExpired` 统一改为 `scope.disposeAll()`。五处手写 `removeAll` 收敛为一处。
- **`CapabilityDraftStore`**：草稿创建时登记撤销；`consume` / 到期 / 会话移除共用同一释放路径。
- **`PluginHostProcessClient`**：把 generation 存活的注册（挂起请求、回调）挂到 generation 作用域；host 重启即 `disposeAll()`，现有 `onInvalidation` 语义不变。
- **`EditorApplication`**：插件 executor 重建时，旧会话的注册（观察、工具、请求）统一回滚，而不是散落 cancel + 清空。

### 验收

- 行为不变：`CapabilityRuntimeTests`、`AIRuntimeTests`、`Editor` 插件测试全绿；
- 新增：重复 dispose 幂等、逆序回滚、释放后可复用、并发注册安全（actor / 锁边界）；
- 代码层面：`CapabilityExposureSessionStore` 中手写 `removeAll()` 的数量降为零。

---

## 提案三：插件依赖用声明表达

### 现状

- `plugin.json`（`PluginRuntime/Contract/PluginManifest.swift`）只有 `id / version / name / description / access / imports / composable_host_capabilities`，**没有插件间依赖字段**；
- 能力组合靠手工：`PluginCapabilityRegistryBuilder.build(base:bindings:)` 要求调用方给出完整 `bindings` 数组，`CapabilityRegistry.appending` 顺序由代码决定；
- 加载顺序与前置关系只存在于宿主目录约定和文档里，不进入契约；缺依赖时表现为运行时"能力找不到"。

### 目标

让"谁能和谁一起装载、谁先谁后"进入 manifest 契约：装载时解析、缺失与环显式报错、组合按图排序。**依赖只表达能力需求，不授予任何权限**。

### 草案

```json
{
  "id": "studio.gizmo",
  "version": 2,
  "name": "Gizmo",
  "access": "write",
  "imports": ["guava:scene/query"],
  "requires": [
    "plugin:studio.core",
    "capability:studio.core.draw"
  ]
}
```

```swift
// PluginRuntime/Contract/PluginManifest.swift（草案）
public struct PluginRequirement: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case plugin, capability }
    public var kind: Kind
    public var id: String
    public var minimumVersion: Int?   // 可选；只表达能力契约最低版本
}
```

### 加载与组合规则

1. **校验**：格式、重复、自引用在 `validatePackage` 阶段拒绝，归入现有 `PluginManifestValidationError`。
2. **解析**：启用集合 + 待启用插件的 `requires` 求闭包；缺失依赖报出完整依赖链，不启用任何半套。
3. **排序**：拓扑序装载；环直接拒绝。
4. **组合**：`PluginCapabilityRegistryBuilder` 按拓扑序逐 binding 追加；`capability:` 依赖要求该能力已在 registry 中（内置或先前插件提供）。
5. **权限**：`requires` 不改变 `access` / `imports`，不触发自动授权；被依赖的插件仍需自己的 `PluginAuthorizationRecord`，未授权即拒绝启用依赖方（不自动启用）。
6. **fail-closed**：任何解析或装载失败都回到"全部未装载"，不允许部分挂载。

### 迁移

- manifest 增加**可选** `requires`（缺省 = 无依赖，旧包继续合法）；实现与测试同步更新，不加兼容别名；
- `PluginRuntimeTests` 增加：缺失依赖、循环、版本不足、依赖方未授权四种拒绝用例；
- `Engine/build/plugin-studio-fixtures` 之外新增一个依赖示例包（两个插件，一依赖一提供）；
- `docs/architecture/plugin-execution.md` 增加 `requires` 一节。

### 验收

- 现有 `PluginRuntimeTests`、`scripts/check-guava-mcp-protocol.py` 行为不变；
- 新用例全部通过；启用顺序在日志中可验证（按拓扑序 load）。

---

## 提案四：WASM 插件热重载

### 现状

- 流程：`inspectPlugin` → 用户授权（`PluginAuthorizationRecord`，绑定代码 / WIT / 权限 / schema 哈希）→ `enablePlugin` → `PluginHostProcessClient.loadPlugin` → `PluginExecutionBinding`（含 `hostGeneration` 与 `authorityDigest`）→ 重建 `PluginCapabilityExecutor` → `activatePluginExecutor` **全量重建**：换 `Session`、取消在飞请求、清空聊天历史；
- `GuavaPluginHost` 重启：`onInvalidation` → 所有绑定失效；
- 任一插件的 authority 变化：`CapabilityExposureSessionStore.replacePluginAuthorities` 丢弃**全部**会话与草稿；
- 已有的安全基础是好的：`hostGeneration`、`authorityDigest`、使用点双重校验（`invocationRecordDenialReason`、`snapshotAuthoritiesAreCurrent`）。

### 目标

- **开发循环**：改 `component.wasm` → 重新 inspect → authority 未变则一步重挂载（不重新授权、不重启编辑器）；authority 变了则展示差异并要求重新授权（维持现状语义）。
- **挂载 / 卸载语义**：binding 即挂载记录；卸载按注册逆序回滚（host calls、能力、组件声明、registry 行）——由提案二的 `DisposalScope` 承载。
- **失效范围最小化**：只失效受影响插件的快照与草稿；无关会话不因某一个插件变化而被丢弃。

### 时序（草案）

```text
文件变化（仅 dev 模式监视）
  → inspect（host: validatePackage + discover）
      ├─ authorityDigest 未变
      │    → host: unload + load（同一 generation 语义）
      │    → 重建 bindings / registry（提案三的拓扑组合）
      │    → scoped invalidate：仅丢弃引用该 plugin 的 snapshots / drafts
      │    → 完成，无需用户操作
      └─ authorityDigest 变化
           → 标记为 stale，UI 展示 diff（哈希 / imports / access / 能力列表）
           → 用户重新授权后走现流程替换 binding；未授权期间旧能力不可用
```

### 安全不变量

- 自动重挂载**仅**在 `authorityDigest` 完全一致时允许；任何差异都要求重新授权；
- registry 重建与 authority 替换必须作为一次原子提交（复用现有 `replaceRegistry` / `replacePluginAuthorities` 的"替换而非增量修改"语义）；
- 旧草稿在使用点继续双重校验（现状已有，不依赖热重载的失效完整性）；
- 任一步失败 → 未挂载 + 显式错误；不允许"半挂载"状态；
- 自动重载绝不自动授权。文件监视默认关闭，仅显式 dev 启动参数开启。

### 实施步骤

1. **host 侧**：复用现有 `unload` / `load` RPC；如需避免中间窗口，可增加 `reload`（unload + load 在同一 generation 内完成）。
2. **Editor 侧**：把 `enablePlugin` / `disablePlugin` 的公共部分抽成对称的 `mount` / `unmount`；`reload = unmount + mount`；`invalidatePluginsAfterHostRestart` 不变。
3. **scoped invalidate**：`CapabilityExposureSessionStore` 增加"按 plugin 移除会话"的入口，依据 snapshot 中 `contracts.source.pluginID` 与 authority 判定；释放走提案二的作用域。
4. **会话保留**：是否保留无关 AI 会话与聊天历史，取决于工具定义是否按请求从快照组装；实施前先用测试确认，保守做法是**第一版保留现有重建行为**，只收窄草稿 / 快照的失效范围。
5. **dev 循环**：目录监视 + 手动"重新加载"按钮；无头模式提供脚本化 reload 入口。

### 验收

- `PluginRuntimeTests`：相同 authority 重挂载成功、变化被拒绝、失败回滚、generation 推进；
- Editor：`enable → reload → 能力列表更新`，无关会话草稿保留；host 重启全量失效语义不变；
- 无头：构建 fixture → reload → `search_capabilities` 结果反映新版本，且旧草稿被拒绝。

---

## 实施顺序与依赖

| 顺序 | 提案 | 依赖 | 行为变化 |
| --- | --- | --- | --- |
| 1 | 二：`DisposalScope` | 无 | 无（纯结构） |
| 2 | 一：`CommitPipeline` | 二（注册撤销） | 无（纯重构包一层） |
| 3 | 三：`requires` | 无 | 有（新增契约字段） |
| 4 | 四：热重载 | 一 + 二 | 有（开发流程） |

每一步独立提交、独立验收；任一步不落地不影响其余。

## 明确不做

- 不引入运行时 DI 容器或全局服务定位；Cordis 的 profile / bundle / patch 配置分层不落地；
- 不做 Swift 代码的动态装载——热重载只适用于 WASM 插件；
- 不改变插件授权、沙箱、资源限额语义；
- 不为兼容保留双轨：迁移完成即删除旧分支（遵循仓库 AGENTS.md 的迁移约定）。

## 验收入口

```sh
swift test --package-path Engine
swift test --package-path Editor
python3 scripts/check-guava-mcp-protocol.py
python3 scripts/validate-crystal-rush-mcp.py
```
