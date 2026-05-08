# Confirmation UI：作为学习协议的设计

> 本文档描述 Confirmation 在新架构中的定位与 UI 实现。  
> 架构总纲见 `architecture.md`。本文档属于 Phase 3 实现范围。

---

## 1. 核心重定位

旧设计把 Confirmation 视为安全门：用户对 AI 提案说是或否。  
这是错的。

**Confirmation 是学习协议。** 每次用户与确认界面的交互，都在产生 Signal——具体是 `UserCorrection` Signal，传入 `Session.learn()`。

三种结果，学习价值完全不同：

| 结果 | 发生了什么 | 产生的学习数据 |
|------|-----------|--------------|
| **accept** | Edit 应用，无修正 | `Edit { correction_delta: nil }` — AI 猜对了 |
| **reject** | 提案丢弃 | `UserCorrection(proposed, actual=nil)` — AI 猜错了，但不知道正确答案是什么 |
| **modify** | 用户改了部分步骤再接受 | `Edit { correction_delta: Δ }` + `UserCorrection(proposed, actual)` — **最富价值的信号** |

modify 路径是整个系统最重要的数据来源。AI 提议 A，用户改成 B，`A → B` 这个 delta 精确揭示了 AI 的误解在哪里。这个数据在任何离线标注流程中都无法产生。

架构图（来自 `architecture.md`）：

```
Proposal
    ├── accept ──► World.apply(proposal.steps)
    │                    └── Edit { correction_delta: nil }
    │                           └── Session.update(edit)
    │
    ├── reject ──► UserCorrection(proposed, actual=nil)
    │                    └── Session.learn()
    │
    └── modify ──► World.apply(actual_delta)
                        └── Edit { correction_delta: actual_delta − proposed_delta }
                               └── Session.learn(UserCorrection)  ← 最重要
```

---

## 2. UI 设计原则

UI 的核心目标不是"让用户快速点 OK"，而是**让用户的修改意图被精确捕获**。

### 2.1 展示 semantic_intent，不只是步骤列表

每个 Proposal 都有 `semantic_intent`（自然语言描述）。UI 必须把它显示在最显眼位置：

```
AI 的理解："把所有点光源亮度调低一半"
```

如果用户看到这句话就知道 AI 理解错了（比如用户其实只想调某个镜头里的灯），他可以在查看步骤之前就直接拒绝或修改意图描述。

### 2.2 步骤粒度可操作

每个 WorldDelta 步骤单独显示，用户可以：
- 勾选/取消单个步骤（产生 `rejectedStepIDs`）
- 查看步骤详情（调了哪个实体的哪个属性，从什么值到什么值）
- 调整步骤内的参数值（产生 `addedSteps` 或修改后的 delta）

### 2.3 展示 reasoning（可折叠）

`Proposal.reasoning` 默认折叠，展开后用户看到 AI 为什么这么做，从而做出更精确的修正而不是整体拒绝。

### 2.4 修改路径是一等公民

UI 不是 [接受] / [拒绝] 两个按钮，三条路径对等呈现：**应用**（全部接受）、**修改后应用**（步骤编辑模式）、**拒绝**（可附说明）。

---

## 3. UserCorrection 数据结构

```swift
struct UserCorrection: Signal {
    var proposalID:      ProposalID
    var proposedDelta:   WorldDelta          // AI 原始提案
    var actualDelta:     WorldDelta?         // 实际应用的 delta，reject 时为 nil
    var acceptedStepIDs: [StepID]
    var rejectedStepIDs: [StepID]
    var addedSteps:      [WorldDelta]        // 用户新增的步骤
    var adjustedSteps:   [StepID: WorldDelta] // 用户改了参数的步骤
    var rejectionNote:   String?
}
```

具体数据示例——AI 提议调四盏灯，用户只接受了两盏并改了亮度值：

```swift
UserCorrection(
    proposalID: "prop_4a8f",
    proposedDelta: WorldDelta([
        .setProperty(entity: "light_01", key: "intensity", value: 0.5),
        .setProperty(entity: "light_02", key: "intensity", value: 0.5),
        .setProperty(entity: "light_03", key: "intensity", value: 0.5),
        .setProperty(entity: "light_04", key: "intensity", value: 0.5),
    ]),
    actualDelta: WorldDelta([
        .setProperty(entity: "light_01", key: "intensity", value: 0.5),
        .setProperty(entity: "light_03", key: "intensity", value: 0.3),
    ]),
    acceptedStepIDs: ["step_01"],
    rejectedStepIDs: ["step_02", "step_04"],
    addedSteps: [],
    adjustedSteps: ["step_03": .setProperty(entity: "light_03", key: "intensity", value: 0.3)],
    rejectionNote: nil
)
```

Session 收到后可以推断：light_02/light_04 不在意图范围内；light_03 的目标亮度是 0.3 而非 0.5。

---

## 4. 交互流程

### 4.1 状态机

```
pending → reviewing → [modifying] → confirming → done
```

### 4.2 UI 线框图

**pending 态**（Proposal 刚到，尚未打开）：

```
┌─────────────────────────────────────────────────┐
│ ⬡ AI 提案就绪  "把所有点光源亮度调低一半"   [查看] │
└─────────────────────────────────────────────────┘
```

**reviewing 态**（展开查看步骤）：

```
┌────────────────────────────────────────────────────────────┐
│ AI 理解："把所有点光源亮度调低一半"                          │
│ 置信度 ████████░░ 0.82        [▸ 查看推理]                  │
├────────────────────────────────────────────────────────────┤
│ 共 4 步                                               [全选] │
│                                                              │
│  ☑  light_01 · intensity  1.0 → 0.5                         │
│  ☑  light_02 · intensity  1.0 → 0.5                         │
│  ☑  light_03 · intensity  0.6 → 0.3                         │
│  ☑  light_04 · intensity  0.8 → 0.4                         │
│                                                              │
│  [预览已开启，视口正在显示 Ghost World 效果]                  │
├────────────────────────────────────────────────────────────┤
│             [拒绝]    [修改步骤]    [应用 ↩]                 │
└────────────────────────────────────────────────────────────┘
```

**modifying 态**（用户点了"修改步骤"）：

```
┌────────────────────────────────────────────────────────────┐
│ 修改模式 — 调整后点"应用"                                    │
├────────────────────────────────────────────────────────────┤
│  ☑  light_01 · intensity  1.0 → [0.5 ____]                  │
│  ☐  light_02 · intensity  1.0 → 0.5       (已取消)          │
│  ☑  light_03 · intensity  0.6 → [0.3 ____]                  │
│  ☐  light_04 · intensity  0.8 → 0.4       (已取消)          │
│                                                              │
│  [+ 添加步骤]                                                │
├────────────────────────────────────────────────────────────┤
│             [取消]                [应用修改后版本 ↩]          │
└────────────────────────────────────────────────────────────┘
```

**confirming 态**（应用后的简短反馈）：

```
┌─────────────────────────────────────────────────┐
│ ✓ 已应用 2/4 步  · 差异已记录为学习信号   [撤销] │
└─────────────────────────────────────────────────┘
```

### 4.3 键盘绑定

| 键 | 行为 |
|----|------|
| `↩` Enter | 全部接受并应用 |
| `E` | 进入修改模式 |
| `R` | 拒绝提案 |
| `D` | 展开/折叠推理链 |
| `Space` | 切换当前步骤的选中状态 |
| `↑` `↓` | 在步骤间移动焦点 |
| `Esc` | 推迟到 pending_review，不丢弃 |

---

## 5. 歧义消解：先问还是先提

Session 在生成 Proposal 之前，需要判断自己是否足够确定用户意图。  
**不确定时应该先问，而不是提案再等用户改。** 改的成本比澄清高。

判断规则：

```
if proposal.confidence < 0.6:
    → 发出 ClarificationRequest，等用户补充后再生成 Proposal

if proposal.confidence in [0.6, 0.85):
    → 生成 Proposal，但在 reviewing 态显示"置信度中等"警告
      并主动提示用户检查 semantic_intent 是否正确

if proposal.confidence >= 0.85:
    → 直接生成 Proposal，视口预览，等待确认
```

歧义澄清 UI（在命令输入行内联，不弹模态）：

```
你说"调暗灯光" — 是指：
  ① 当前场景全部点光源    ② 当前选中的灯    ③ 某个镜头里的灯
  [① ↩]  [② 2]  [③ 3]  [自由回答 R]
```

澄清后 Session 生成高置信度 Proposal，走正常确认流程。问答写入 `ConversationHistory`，后续相似请求不再重复问。

---

## 6. 批量确认

复杂多步骤工作可能产生多个 Proposal 排队等待。  
批量模式不是把所有 Proposal 合并成一个大表单，而是**保留个体可操作性**：

```
┌────────────────────────────────────────────────────────────┐
│ 待确认提案  3 个                              [全部接受 ↩]  │
├────────────────────────────────────────────────────────────┤
│  1 ▸ "把点光源调暗一半"           4 步   置信 0.82   [展开] │
│  2 ▸ "给主角模型加环境光遮蔽"     2 步   置信 0.91   [展开] │
│  3 ▸ "调整摄像机曝光补偿 +0.3"    1 步   置信 0.95   [展开] │
├────────────────────────────────────────────────────────────┤
│  [逐个审查]      [跳过全部]      [全部接受 ↩]              │
└────────────────────────────────────────────────────────────┘
```

行为约定：

- **全部接受**：每个 Proposal 各自产生 `Edit { correction_delta: nil }`，三条学习记录
- **逐个审查**：按顺序进入单 Proposal 的 reviewing 态，审完自动跳下一条
- 单独展开某条：可在批量视图中直接展开并修改，不影响其他条
- 跳过某条：进入 `pending_review`，不阻塞其他条的应用
- 批量中如有置信度 < 0.6 的 Proposal：自动排到末尾并加警告标签，不混入高置信队列

每条 Proposal 独立产生 UserCorrection，Session 可从中发现跨提案模式（如用户总是拒绝某类操作）。
