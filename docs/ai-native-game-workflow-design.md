# Session 在游戏开发工作流中的行为模式

> 本文档是 `architecture.md` 的配套文档，描述 Session 在游戏/交互式项目上下文中如何理解 World、响应 Signal、生成 Proposal、从 UserCorrection 学习。总纲概念（World、Session、Signal、Proposal、Edit、UserCorrection）以 `architecture.md` 为准，本文档不重复定义。

---

## 1. 概述：游戏上下文对 Session 意味着什么

当 `Session.WorkflowContext` 标识为游戏/交互项目时，Session 的理解框架从"场景外观"转向"玩家体验"。

Session 在游戏上下文中持续维护的理解包括：

- **关卡流动性**：玩家路径是否连通、是否存在死角、视线与掩体的分布是否支持预期的遭遇节奏
- **遭遇设计意图**：每个区域设计给哪种冲突类型（遭遇战、解谜、探索缓冲），资源点与挑战点的间距是否合理
- **玩家体验曲线**：当前关卡阶段的紧张—放松节律，与 `WorkflowContext.target_experience` 的偏差
- **数值平衡感知**：通过 WorldView 中的 inferred 层属性（敌人密度、掩体覆盖率、资源分布）推断当前难度倾向
- **脚本模式**：当前项目用哪些 trigger 类型、action 惯用搭配、事件命名风格

Session 不是在"调用功能"——它持续在 World 中共同创作，每次 Signal 到来时，它从 WorldView 出发，结合 WorkflowContext 和 ConversationHistory，理解设计师想要什么，再生成 Proposal。

---

## 2. Game WorkflowContext

`Session.WorkflowContext` 在游戏模式下包含以下字段：

```
GameWorkflowContext
├── level_phase: Blockout | EncounterDesign | Polish | Balance | Ship
│     // 当前处于哪个关卡阶段，决定 Session 的注意力重心
├── gameplay_intent
│   ├── genre: String              // "third_person_shooter" | "puzzle_platformer" | ...
│   ├── win_condition: String      // "reach_exit" | "eliminate_all" | "survive_60s"
│   ├── player_count: Int          // 1 | 2–4 | MMO
│   └── pacing: String             // "tight_action" | "exploration" | "puzzle_heavy"
├── target_experience: String      // 设计师用自然语言描述的体验目标
│     // 例："让玩家在第一次进入时感到被包围，但总有一条出路"
├── known_constraints
│   ├── nav_mesh_baked: Bool       // NavMesh 是否已 bake，影响 Session 能否推断可达性
│   ├── performance_budget: String // "mobile_low" | "console_high" | ...
│   └── scripting_registry: [ActionID]  // 当前项目注册了哪些 gameplay action
└── playtest_observations: [PlaytestSummary]
      // 最近几次 playtest 的摘要，Session 用于推断什么在起作用
```

Session 在工作流阶段切换时（例如从 Blockout 进入 EncounterDesign）自动更新 WorkflowContext，并在 WorldView 的 `active_context` 中记录阶段转变。

---

## 3. 典型 Signal 模式

### 3.1 NaturalLanguage：设计师描述问题

**Signal：**
```
NaturalLanguage(
  text: "这个区域感觉太开阔了，玩家一进来就被打死",
  locale: zh_CN
)
```

Session 收到后，查询 WorldView 中该区域的实体：掩体体块数量、spawn point 位置、视线遮挡关系（inferred 层）、敌人密度。结合 `WorkflowContext.gameplay_intent.pacing = "tight_action"` 和 `target_experience`，Session 推断：问题不只是掩体数量，而是入口视线曝露时间过长，导致玩家在建立空间认知前已经暴露。

**Proposal：**
```
Proposal {
  semantic_intent: "在区域入口增加 L 型掩体序列，打断 spawn 到 entry 的直接视线",
  steps: [
    WorldDelta { op: entity.create, role: "cover_volume",
                 authored: { transform: Entry+3m_left, size: [2,1.5,0.4],
                             shape: "L_barrier" } },
    WorldDelta { op: entity.create, role: "cover_volume",
                 authored: { transform: Entry+5m_right, size: [1.5,1.5,0.4] } },
    WorldDelta { op: relationship.add, kind: "blocks_sightline",
                 from: cover_vol_01, to: spawn_point_main }
  ],
  reasoning: "入口正对主 spawn，玩家进入瞬间全暴露。两个错位掩体建立视线遮断，
              保留两条绕行路线，符合 tight_action 节奏中'有压力但有解法'的体验目标。",
  confidence: 0.82,
  approval_policy: RequiresApproval
}
```

### 3.2 DirectManipulation：设计师移动实体

**Signal：**
```
DirectManipulation(
  entity: spawn_point_02,
  delta: { transform.position: [+8m, 0, +3m] }
)
```

这个操作本身是一次 Edit（设计师直接编辑）。Session 观察到这次 Edit 后，更新 WorldView 中 spawn_point_02 与周边掩体、视线的关系推断。

Session 从这次移动中学到：设计师倾向于将 spawn 放在有侧翼掩体的位置，而不是开阔的正面进入点。这条偏好写入 Session 的 ConversationHistory，影响后续同类 Proposal 的生成方式。

如果这次移动导致两个 spawn 距离过近（Session 根据 WorkflowContext 中的 encounter_spacing 推断），Session 可以主动发出一个低优先级 Proposal：

```
Proposal {
  semantic_intent: "spawn_point_01 和 spawn_point_02 现在间距 4m，可能导致敌人同时出现在同一视野",
  steps: [],   // 没有自动变更步骤，只是提示
  reasoning: "按当前 pacing=tight_action，建议 spawn 间距 ≥ 12m 以保证分批遭遇节奏。",
  confidence: 0.65,
  approval_policy: RequiresApproval
}
```

### 3.3 WorldEvent：Playtest 会话开始

**Signal（由引擎发出，通过 World 变更流进入 Session）：**
```
WorldEvent(
  event: playtest_session.started(
    session_id: "ps_2024_0312_001",
    participants: [human_player_01],
    scene_revision: 447
  )
)
```

Session 收到此 WorldEvent 后，切换到**观察模式**：

- 暂停主动 Proposal 生成（不在玩家操作中打扰）
- 开始订阅 telemetry 类 WorldEvent（死亡事件、路径数据、卡顿点）
- 在 `WorkflowContext.playtest_observations` 中积累数据

后续 WorldEvent 持续进入：
```
WorldEvent(event: player.died(position: [34, 0, -12], cause: "enemy_ranged", elapsed: 23s))
WorldEvent(event: player.died(position: [35, 0, -11], cause: "enemy_ranged", elapsed: 41s))
WorldEvent(event: playtest_session.ended(session_id: "ps_2024_0312_001", completed: false))
```

Playtest 结束后，Session 退出观察模式，基于积累的 WorldEvent 数据生成诊断 Proposal（见第 6 节）。

### 3.4 UserCorrection：设计师修改了 Session 的提案

**背景：** Session 提议在走廊中段增加一个圆柱掩体（Proposal A）。设计师确认时，选择了 modify 而不是 accept——没有放圆柱掩体，而是在该位置抬高了地形，增加了一个高台。

**UserCorrection 信号：**
```
UserCorrection(
  proposed: Proposal_A,   // semantic_intent: "在走廊中段增加掩体"
  actual: WorldDelta {    // 实际发生的变更
    op: entity.modify,
    entity: terrain_section_03,
    authored: { elevation: +1.8m, shape: "raised_platform_4x4" }
  },
  accepted_steps: []      // 没有接受 Proposal_A 的任何步骤
)
```

Session 从这个 UserCorrection 中学到：

- 这位设计师在需要掩护时，**优先考虑地形高差而非独立掩体体块**
- 高台几何（`raised_platform`）是该设计师的惯用词汇
- 后续遇到同类情境，Session 应优先提议地形变更而非放置掩体实体

这条学习更新记录在 Session 的 ConversationHistory 和 WorldView 的 `active_context` 中，下次 Session 处理"这个区域需要掩护点"类 Signal 时，会直接提议地形方案。

## 4. 典型 Proposal 模式

### 4.1 遭遇区域重构

```
Proposal {
  id: "prop_encounter_rework_zone_b",
  author: AI(session_id: "sess_proj_alpha"),
  semantic_intent: "将 B 区改造为不对称遭遇：防守方有高地，进攻方有侧翼包抄路线",
  steps: [
    WorldDelta { op: entity.create, role: "platform",
                 authored: { transform: ZoneB_north+2m_elev, size: [6,0.3,4] } },
    WorldDelta { op: entity.create, role: "cover_volume",
                 authored: { transform: ZoneB_south_flank, size: [1.5,1.2,0.4] } },
    WorldDelta { op: entity.create, role: "cover_volume",
                 authored: { transform: ZoneB_south_flank+3m, size: [1.5,1.2,0.4] } },
    WorldDelta { op: relationship.add, kind: "provides_sightline_advantage",
                 from: platform_01, to: zone_b_center }
  ],
  reasoning: "当前 B 区完全对称，双方无战术差异。不对称布局让防守方有高地优势，
              但侧翼开放给进攻方绕后，形成战术博弈而非纯数值比拼。
              符合 WorkflowContext.target_experience 中'每次遭遇都有解法'的目标。",
  confidence: 0.78,
  approval_policy: RequiresApproval
}
```

### 4.2 数值平衡调整（分支操作）

```
Proposal {
  id: "prop_balance_enemy_hp_branch",
  author: AI(session_id: "sess_proj_alpha"),
  semantic_intent: "在独立分支上降低精英敌人血量 15%，验证是否改善 zone_d 通过率",
  steps: [
    WorldDelta { op: gameplay.fork_data_table,
                 table: "enemy_stats", branch_name: "elite_hp_test_0312" },
    WorldDelta { op: gameplay.modify_data_table_row,
                 branch: "elite_hp_test_0312", row: "enemy_elite",
                 column: "max_health", value: 255 }   // 原值 300
  ],
  reasoning: "zone_d 的 playtest 通过率为 23%（3 次 playtest，9 次尝试，2 次通关）。
              精英敌人是唯一 DPS 检查点。在分支上测试，不影响主表，
              验证后再决定是否合并。",
  confidence: 0.71,
  approval_policy: RequiresApproval
}
```

---

## 5. 学习信号：UserCorrection 在游戏上下文中的作用

UserCorrection 是 Session 在游戏项目中积累设计师"语言"的主要机制。每次设计师修改或拒绝 Proposal，Session 获得的不仅是"这次错了"，而是具体的设计词汇偏好。

### 5.1 几何词汇学习

| Session 提议 | 设计师实际做的 | Session 学到 |
|-------------|---------------|-------------|
| 放置独立掩体体块 | 改造地形高差 | 该设计师偏好地形几何而非独立道具 |
| 增加 L 型障碍物 | 改为弧形墙体 | 该项目美术词汇中弧形优于直角 |
| 缩短走廊 | 加宽走廊保留长度 | 该设计师优先保留路径长度，用宽度解决视线问题 |

### 5.2 难度偏好学习

Session 通过观察设计师对平衡提案的 accept/modify/reject 模式，推断项目的难度基调：

- 设计师持续调高敌人血量 → Session 后续平衡提案的起始点上移
- 设计师多次拒绝"降低难度"提案 → Session 推断 target_experience 要求挑战性，调整 reasoning 的出发点
- 设计师接受了某次"增加侧翼出口"提案 → Session 学到该设计师认为"逃路"是这个项目的必要设计元素

### 5.3 脚本模式学习

当设计师修改 Session 提议的 gameplay script 节点时（例如把 `on_player_enter` trigger 改为 `on_player_linger_3s` trigger），Session 记录这次 UserCorrection，后续在同类场景中主动使用延时触发模式。

---

## 6. Playtest Loop：Session 的观察与反馈

### 6.1 Session 在 Playtest 中的角色

Session 通过 World 变更流接收 playtest 期间产生的全部 WorldEvent。它不控制 playtest 过程，只观察。

```
Playtest 期间 Session 接收的 WorldEvent 类型：
  ├── player.died(position, cause, elapsed_since_spawn)
  ├── player.reached_checkpoint(checkpoint_id, elapsed)
  ├── player.input_idle(duration)          // 玩家停止输入，可能迷路或困惑
  ├── trigger.activated(trigger_id, count) // 某触发器被激活的次数
  ├── fps.dropped_below_threshold(zone_id, min_fps, duration)
  └── playtest_session.ended(completed, reason)
```

### 6.2 Playtest 结束后的诊断 Proposal

Playtest 结束后，Session 退出观察模式，基于积累的 WorldEvent 生成一批诊断 Proposal。每个 Proposal 必须引用具体的观察数据作为 reasoning 依据。

**示例：**

```
Proposal {
  semantic_intent: "Zone B 存在重复死亡热点，建议增加进入缓冲空间",
  steps: [ ... ],
  reasoning: "3 次 playtest 中，[34,0,-12] 附近记录 5 次死亡，
              均发生在进入 Zone B 后 30 秒内，cause 均为 enemy_ranged。
              该位置距最近掩体 9m，超过 tight_action 节奏下的推荐曝露距离（≤4m）。",
  confidence: 0.88,
  approval_policy: RequiresApproval
}
```

### 6.3 观察积累对 WorkflowContext 的更新

每次 Playtest 结束，Session 更新 `WorkflowContext.playtest_observations`，这影响后续 Signal 的处理方式：

- 如果多次 playtest 显示同一区域持续有问题，Session 在处理相关 Signal 时会主动提及这个背景
- 如果 playtest 显示某个设计决定有效（例如加了高台后该区域死亡率下降），Session 将其作为正向参考，在类似情境中复用该模式

### 6.4 Session 不做的事

- 不自动应用 Playtest 产生的 Proposal：所有变更必须经 Proposal → 用户 Confirmation → Edit 流程
- 不在 Playtest 进行中推送 Proposal：观察模式期间 Session 只收集，不打扰
- 不基于单次 Playtest 做强结论：Session 在 reasoning 中标注样本量，避免以单次数据过度调整

---

## 7. 与架构总纲的对应

| 本文涉及的行为 | 总纲概念 |
|--------------|---------|
| Session 理解关卡流动性、遭遇意图 | `Session.WorldView` + `WorkflowContext` |
| 设计师自然语言描述问题 | `Signal.NaturalLanguage` |
| 设计师移动实体 | `Signal.DirectManipulation` → Edit（人类作者） |
| Playtest 数据进入 Session | `Signal.WorldEvent`（引擎产生的变更流） |
| 设计师修改 Session 提案 | `Signal.UserCorrection` → `Session.learn()` |
| Session 提议掩体、地形、脚本变更 | `Proposal` + `WorldDelta` |
| 提案应用后写入历史 | `Edit`（含 `correction_delta` 如有修改） |
| Session 学习设计师几何词汇偏好 | `UserCorrection` → `ConversationHistory` 更新 |
