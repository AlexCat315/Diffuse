# AI 原生影视工作流设计

> 本文档隶属于 `architecture.md`，描述 Session 在影视工作流上下文（film WorkflowContext）中的行为模式。
> 时间轴层（Shot / Clip / Binding）的数据结构详见 `ai-native-sequence-document-design.md`。
> 本文档不描述"AI 调用能力序列"——它描述 Session 对叙事意图的持续理解，以及它如何通过 Signal / Proposal 参与影视创作。

---

## 1. 概述：影视语境中的 Session

Session 是 AI 在 World 中的持续存在，不是请求处理器。当项目的 WorkflowContext 为影视模式时，Session 理解以下事实：

**它在创作一部叙事性作品。** 它知道：

- **镜头结构**：当前 WorldView 中哪个 Shot 是活跃的，它在 Sequence 中的位置，与前后镜头的叙事关系
- **表演意图**：角色此刻的情感状态，对白节奏，肢体语言的叙事功能
- **镜头语言**：景别、运镜、构图规则不是孤立参数，是导演陈述叙事立场的语法
- **光照设计意图**：灯光不是亮度数值，是情绪、时间、空间的表达手段
- **叙事阶段**：当前处于 blocking、performance、lighting 还是 review 阶段，不同阶段的 Proposal 粒度不同

Session 不区分"NL 路径"和"规划器路径"。无论输入来自自然语言、参考图、直接操作还是 WorldEvent，都进入同一推理过程，结合 WorldView 和 ConversationHistory 产出 Proposal。

---

## 2. Film WorkflowContext

Session 的 `WorkflowContext` 在影视模式下包含以下状态：

```
FilmWorkflowContext
├── active_sequence: SequenceID        // 当前编辑的 Sequence
├── active_shot: ShotID?               // 当前焦点镜头（可为空，表示在 Sequence 级操作）
├── narrative_phase
│   ├── blocking                       // 角色位置、镜头位摆放
│   ├── performance                    // 表演、mocap、lip-sync
│   ├── camera_language               // 景别、运镜、构图
│   ├── lighting                       // 光照设计
│   └── review                         // Dailies / 批注回灌
├── director_intent: String?           // 本次会话开始时导演陈述的意图，自然语言
├── reference_anchors: [ReferenceAnchor]
│   // 本次工作阶段累积的参考图及其语义摘要，Session 持续引用
└── locked_shots: [ShotID]             // 已锁定不允许 Session 主动修改的镜头
```

`director_intent` 由导演在会话开始时（或任意时刻）通过 NaturalLanguage Signal 设定，Session 将其保存在 ConversationHistory 并在后续所有 Proposal 的 `reasoning` 中引用。

`narrative_phase` 影响 Proposal 的 `approval_policy`：
- `blocking` 阶段：Session 可以批量提议位置变更，`approval_policy = RequiresApproval`
- `lighting` 阶段：每盏非 key-light 的新增灯具必须单独 `approval_policy = RequiresApproval`
- `review` 阶段：Session 只提议，不允许 `approval_policy = Automatic`

---

## 3. 典型 Signal 模式

### 3.1 NaturalLanguage：叙事语言转化为多维度 Proposal

**场景**：导演口述对镜头的感受，Session 同时推理摄影、光照、表演三个维度。

```
Signal.NaturalLanguage {
  text: "这个镜头需要更紧张的感觉，现在太平静了",
  locale: zh-CN
}
```

Session 查询 WorldView，得知：
- active_shot 是 Shot-07，景别为 MS（中景），主角正面朝镜头
- key light 色温 5600K，强度适中
- 当前没有摄像机运动

Session 不会把"紧张感"拆解为固定功能调用，而是推理：紧张感可以通过更紧的景别（CU）压迫观众空间、稍硬的侧光强化阴影、轻微手持感产生不稳定性。Session 产出一个 Proposal，包含三组 steps，每组可独立接受或拒绝：

```
Proposal {
  id: "prop-shot07-tension-001",
  author: AI(session_id),
  semantic_intent: "通过景别收紧、光照戏剧化、运镜不稳定性增强 Shot-07 的紧张感",
  confidence: 0.78,
  approval_policy: RequiresApproval,
  reasoning: "导演的意图是'紧张'。紧张感的镜头语言通常包括：(1) 景别压缩减少呼吸空间，(2)
              高对比侧光让面部产生强烈明暗分割，(3) 轻微手持增加视觉不稳定性。三者叠加但
              不宜同时最大化，建议分步确认。",
  steps: [
    WorldDelta {
      step_id: "step-01-framing",
      description: "景别从 MS 收为 CU",
      target: Shot-07.camera_binding,
      change: camera.frame_subject(subject=角色A, framing=CU, composition_rule=rule_of_thirds)
    },
    WorldDelta {
      step_id: "step-02-light",
      description: "key light 向侧移 35°，色温降至 4200K 增加冷硬感",
      target: Shot-07.shot_override.key_light,
      change: {
        transform.azimuth: +35°,
        color_temperature: 4200,
        intensity_multiplier: 1.2
      }
    },
    WorldDelta {
      step_id: "step-03-movement",
      description: "摄像机添加轻微手持模拟",
      target: Shot-07.camera_binding.movement,
      change: camera.set_movement(kind=handheld, amplitude=0.3)
    }
  ]
}
```

用户接受 step-01 和 step-02，拒绝 step-03（认为手持感不符合这部片的风格），则产生：

```
UserCorrection {
  proposed: prop-shot07-tension-001,
  actual: WorldDelta{ step-01 + step-02 },
  accepted_steps: ["step-01-framing", "step-02-light"]
}
```

Session 从这个 UserCorrection 学习：该项目倾向于通过景别和光照传递紧张感，而不是摄像机不稳定性。这个偏好写入 ConversationHistory，影响后续同类 Proposal。

---

### 3.2 ReferenceImage：参考剧照驱动光照提议

**场景**：导演拖入一张参考剧照，希望复现其光影风格。

```
Signal.ReferenceImage {
  image: <剧照图像数据>,
  intent: "参考这张剧照的光影，特别是窗口逆光的处理方式"
}
```

Session 分析参考图，提取：
- 主光源来自画面右侧高位，推断为窗口自然光
- 人物轮廓有明显 rim light，与背景分离
- 阴影面保留了少量 fill，整体对比约 4:1

Session 产出：

```
Proposal {
  id: "prop-refimg-window-backlight-001",
  author: AI(session_id),
  semantic_intent: "复现参考图的窗口逆光结构：高位侧逆 key + 柔和 fill + rim 边缘光",
  confidence: 0.71,
  approval_policy: RequiresApproval,
  reasoning: "参考图的光源动机是室内窗光（高位、侧逆方向），面部阴影面有明显信息保留，
              判断 fill ratio 约 1:4。rim light 用于人物与背景分离。当前场景的 key
              方向与此差异 ~110°，需要大幅重置。",
  steps: [
    WorldDelta { description: "重置 key light 为高位右侧逆光 (azimuth=145°, elevation=55°)",
                 target: Shot-active.shot_override.key_light, ... },
    WorldDelta { description: "添加左侧柔 fill (intensity = key * 0.25)",
                 target: Shot-active.shot_override, change: lighting.add_fill(...) },
    WorldDelta { description: "添加逆光 rim (azimuth=310°, elevation=20°, intensity=0.6)",
                 target: Shot-active.shot_override, change: lighting.add_rim(...) }
  ]
}
```

这个参考图被存入 `WorkflowContext.reference_anchors`，Session 在后续同场景的镜头中会主动引用它作为光照一致性基准。

---

### 3.3 DirectManipulation：用户直接操作教会 Session 构图偏好

**场景**：用户在视口中手动拖动摄像机，重新框定构图。

```
Signal.DirectManipulation {
  entity: Shot-09.camera_binding,
  delta: PropertyDelta {
    transform: { position: Δ(-0.8, 0.2, 0), rotation: Δ(0°, -12°, 0°) },
    focal_length_mm: 50 → 85
  }
}
```

这个 Signal 不需要 Session 产出 Proposal（用户已直接 apply），但 Session 更新 WorldView 并从中学习：

- 用户把焦距从 50mm 推到 85mm，构图更压缩
- 用户略微下移并左转摄像机，让主体更偏左、头顶留白减少

Session 将这次操作记录为 `Edit`（provenance.author = Human），并推断：该导演倾向于**更长焦、更少头顶留白的构图风格**。后续涉及 `camera.frame_subject` 的 Proposal 将自动偏向 85mm 以上焦段，减少构图中的头顶 headroom。

这就是 UserCorrection 的变体：用户没有接受/拒绝任何 Proposal，但直接操作本身就是最强的偏好信号。

---

### 3.4 WorldEvent：时间轴位置变化更新叙事上下文

**场景**：编辑在时间轴上跳转，Session 感知到当前焦点镜头变化。

```
Signal.WorldEvent {
  event: WorldEvent.timeline.changed(shot_id: Shot-03)
}
```

Session 更新 `WorkflowContext.active_shot = Shot-03`，查询 WorldView：
- Shot-03 是一个确立镜头（EWS），位于序列开头，用于建立空间关系
- Shot-03 的 shot_override 中尚无 cinematic light（继承 scene default）

Session 不主动发出 Proposal，但更新 `active_context`，准备在下一个 Signal 到来时，以 Shot-03 的叙事位置（序列开场确立镜头）为基准推理。如果下一条 Signal 是 NaturalLanguage "灯光感觉不对"，Session 会知道这指的是 Shot-03 的 scene-level light，而不是某个 shot override。

---

## 4. 典型 Proposal 模式

### 4.1 多镜头光照一致性 Proposal

当 `narrative_phase = lighting` 时，Session 可以跨镜头提议光照一致性：

```
Proposal {
  id: "prop-lighting-consistency-scene03",
  semantic_intent: "统一 Scene-03 内 Shot-05 到 Shot-09 的 key light 方向，保持画面内太阳方位一致",
  confidence: 0.85,
  approval_policy: RequiresApproval,
  reasoning: "Session 检测到 Shot-05 的 key 方向（azimuth=220°）与 Shot-07（azimuth=155°）
              差异 65°，超过合理误差。两镜头在叙事上连续（同一地点同一时段），不应有此差异。
              Shot-06 方向居中，推断为编辑操作时未同步更新。",
  steps: [
    WorldDelta { description: "Shot-06 key light azimuth 对齐至 220°", target: Shot-06... },
    WorldDelta { description: "Shot-07 key light azimuth 对齐至 220°", target: Shot-07... }
  ]
}
```

### 4.2 表演与镜头语言协同 Proposal

```
Proposal {
  id: "prop-perf-camera-sync-shot11",
  semantic_intent: "当角色转身的动作峰值（第 847 帧）与镜头推进同步，强化情绪节拍",
  confidence: 0.66,
  approval_policy: RequiresApproval,
  reasoning: "当前摄像机推进开始于第 820 帧，角色转身峰值在第 847 帧，两者错位 27 帧导致
              视觉重心分散。将摄像机推进延迟到第 840 帧开始，使推进高潮（+7 帧）与转身
              峰值对齐，产生'镜头跟着情绪走'的感觉。",
  steps: [
    WorldDelta {
      description: "摄像机 dolly-in 起始帧从 820 移至 840",
      target: Shot-11.camera_binding.movement_keyframes,
      change: { start_frame: 820 → 840 }
    }
  ]
}
```

---

## 5. 学习信号：UserCorrection 在影视语境中的含义

每次用户对 Proposal 的 `modify` 操作都产生 `UserCorrection`，Session 将其解读为导演审美偏好的具体表达。

**典型学习场景：**

| UserCorrection 内容 | Session 学习到的偏好 |
|---------------------|----------------------|
| 拒绝手持摄像机运动 | 该项目倾向稳定机位，避免 handheld |
| 把 fill ratio 从 1:4 改为 1:6 | 导演喜欢更高对比度，更戏剧化的阴影 |
| 把 CU 景别改回 MS | 这段叙事需要保留演员肢体语言，不宜过紧 |
| 把色温从 4200K 改为 3800K | 该场景的情绪色语言比 Session 预期的更冷 |
| 把 dolly-in 改为 static | 导演不希望用摄像机运动强调这个情绪节拍 |

这些 UserCorrection 不是错误修正，是导演美学语言的真实样本。Session 持续积累后，在同一项目后续镜头的 Proposal 中自动反映这些偏好，无需导演重复陈述。

**重要约束**：Session 学习的偏好存在 `ConversationHistory` 和 `WorldView`，不跨项目迁移——每个项目有自己的美学语言。

---

## 6. 与 World 时间轴层的关系

影视工作流中，Session 操作的对象主要是 World 的时间轴层。核心数据结构详见 `ai-native-sequence-document-design.md`，此处只说明与 Session 行为直接相关的边界：

**Session 读取时间轴层的方式：**

Session 通过 `WorldView.entity_index` 查询当前 Sequence 中所有 Shot 的语义角色（确立镜头、反应镜头、插入镜头等），以及每个 Shot 的 `shot_override` 状态（是否有 cinematic light、camera binding 是否已设置等）。这让 Session 知道哪些镜头已完善，哪些处于空白状态。

**Session 提议时间轴变更的方式：**

所有对 Shot / Clip / Binding 的变更都通过 `WorldDelta` 表达，进入 Proposal 的 `steps` 列表。Session 不直接写入时间轴，只提议。

**shot_override 层的重要性：**

cinematic light、cine camera transform、角色临时位置覆盖，全部写在 `shot_override` 层，不污染 World 的 `authored` 层（SceneDocument 主体）。Session 始终优先写 `shot_override`，只有导演明确要求时才提议修改 `authored` 层。

**Session 不处理的内容：**

帧级别的渲染调度（RenderJob 提交）和烘焙结果（`provenance = baked`）不经过 Session 的 Proposal 流程，由渲染系统直接操作。Session 可以感知这些状态（通过 `WorldEvent`），但不提议修改已烘焙的结果。
