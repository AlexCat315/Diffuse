# SequenceDocument / Shot / Clip / Binding 详细设计

> 本文档是 `ai-native-scene-model-design.md` §4、§9、§11 的子设计。
> 范围：定义影视与游戏 cinematic 共用的时间域 authoring 模型。
> 引用：CapabilityGraph 实例见 `ai-native-capability-catalog.md` §3-§5、§6，影视工作流见 `ai-native-film-workflow-design.md`，UI 见 `ai-native-minimal-confirmation-ui-design.md`。

---

## 0. 设计前提

1. SequenceDocument 是 **authoring truth**，不是渲染中间结果，也不是 runtime evaluation 结果
2. 时间域评估走 EvaluationContext，输出 EvaluatedSceneSnapshot；SequenceDocument 不持有当前帧值
3. SequenceDocument 引用 SceneDocument 与 ModelDocument，不内联资产
4. Shot override 是 SceneDocument 之外的独立分层，不污染 scene authoring
5. 所有写操作走 Transaction IR，与总纲 §11 一致
6. 与游戏 GameplayCamera / SceneCamera 的边界由 `usage_kind` 字段强制区分（见 §10）
7. 旧 Zig 中的 `Sequence + Track` 升级为 `Sequence + Shot + Clip + Binding`，不向后兼容旧字段（迁移见 §15）

---

## 1. 文档树总览

```
SequenceDocument
├── meta (fps, time_base, duration, color_space, ...)
├── shots: [Shot]
│   ├── range (start, end, source_offset)
│   ├── camera_binding
│   ├── overrides: [ShotOverride]
│   └── tracks: [Track]
│       └── clips: [Clip]
│           └── bindings: [Binding]
├── markers: [Marker]
├── cuts: [Cut]
├── caches: [SequenceCache]
└── revision (id, parent, author, created_at)
```

每一层节点都有稳定 ID 和独立 revision；上层 revision 变更不强制下层 invalidate。

---

## 2. 时间模型

### 2.1 时间基准

```text
TimeBase {
  fps: int                         // 24 / 25 / 30 / 48 / 60 / 120
  drop_frame: bool                 // NTSC 29.97 / 59.94 才 true
  start_timecode: SMPTE            // 默认 01:00:00:00
}
```

约束：

- 文档内所有时间字段统一为 **frame index (i64)**，不存浮点秒
- 与外部交互（API / UI 显示）按 fps 转 SMPTE / 秒
- fps 改变需走 `sequence.set_fps`，引擎自动按规则重映射所有 clip range（保比例 / 保帧数二选一，required cfm）

### 2.2 时间区间

```text
FrameRange {
  start: i64                       // 包含
  end:   i64                       // 不包含（半开区间）
  duration(): end - start
}
```

所有 range 都是半开 [start, end)，避免边界 off-by-one。

### 2.3 三种坐标系

| 坐标系 | 用途 |
|--------|------|
| `sequence_frame` | SequenceDocument 内的全局时间轴 |
| `shot_frame` | shot 内局部时间轴，0 为 shot start |
| `source_frame` | clip 引用的源资产时间轴（动画 / 视频 / 音频） |

转换：

- shot_frame = sequence_frame − shot.range.start + shot.source_offset
- source_frame = shot_frame · clip.time_warp + clip.source_offset

任何 capability 的时间参数必须显式声明所属坐标系，禁止隐式默认。

---

## 3. SequenceDocument

### 3.1 字段

```text
SequenceDocument {
  id: stable_id
  name: string
  scene_doc_uri: SceneDocument 引用
  time_base: TimeBase
  frame_range: FrameRange           // 整个 sequence 长度
  resolution: { width, height }
  aspect_ratio: w:h
  color_space: linear_srgb | aces_cg | ...
  motion_blur: { shutter_angle_deg, samples }
  shots: [Shot]
  markers: [Marker]
  cuts: [Cut]
  caches: [SequenceCache]
  evaluation_policy: lazy | eager | hybrid
  provenance: authored | inferred
  revision: Revision
}
```

### 3.2 evaluation_policy

| 策略 | 行为 |
|------|------|
| lazy | 只在被请求帧附近评估，适合 Sequencer 拖动 |
| eager | 编辑后立即整段重评估，适合渲染前校验 |
| hybrid | 当前 shot eager，其他 lazy（默认） |

### 3.3 Markers / Cuts

```text
Marker {
  id, frame, kind: chapter | note | sync_point | render_split,
  label, color_token
}

Cut {
  id, frame,
  transition: hard | dissolve | fade_in | fade_out | wipe
  duration: i64                     // dissolve / fade / wipe 才有意义
  params?: { wipe_direction?, fade_color? }
}
```

Cut 不是 shot 边界——shot 边界天然是 cut，但 Cut 可以单独描述跨 shot 的转场效果。

---

## 4. Shot

### 4.1 字段

```text
Shot {
  id: stable_id
  name: string                      // sc010_sh020 等
  range: FrameRange                 // 在 sequence 上的位置
  source_offset: i64                // shot_frame=0 对应的内部偏移（用于 retime）
  camera_binding: Binding           // 必选，指向一个 cinematic camera asset
  default_scene_view: SceneViewRef? // shot 默认观察哪一段 scene
  overrides: [ShotOverride]
  tracks: [Track]
  notes: string?
  status: planning | blocking | lighting | rendering | final | locked
  provenance: authored | inferred
  revision: Revision
}
```

### 4.2 status 与 capability 过滤

`status` 决定哪些 capability 可用：

| status | 可写范围 |
|--------|----------|
| planning | 全部 |
| blocking | 全部，destructive 升级为 required |
| lighting | 限制 transform / range 大改，光照与构图自由 |
| rendering | 仅允许 light / cut / clip retime 微调 |
| final | 仅允许 marker / note |
| locked | 全部禁写，需 `shot.unlock`（owner 角色） |

引擎在 CapabilityGraph 过滤层应用此规则。

### 4.3 ShotOverride

```text
ShotOverride {
  id,
  target_kind: scene_instance | component_field | material_param
             | light_param | camera_param,
  target_ref: { doc_uri, target_id, field_path? },
  value_kind: absolute | additive | multiplicative,
  value: any,                       // schema 由 target 决定
  blend_in_frames?: i64,
  blend_out_frames?: i64,
  ease: linear | ease_in | ease_out | ease_in_out | step,
  source: authored | proposal | inferred,
  proposal_id?: id                  // 来自 AI 提案时回指
}
```

约束：

- override **不修改** SceneDocument，仅在 EvaluationContext 中合成
- 同一 target 多 override 按 **track 顺序 → ShotOverride 内排序** 解析
- absolute 优先级最高，后续 additive / multiplicative 在其上叠加
- 离开 shot range 后 override 不生效（除非由 blend_out 平滑）

---

## 5. Track

### 5.1 字段

```text
Track {
  id, name,
  kind: animation | camera | audio | event | subscene | fx
      | lighting | post_process | data,
  mute: bool
  solo: bool
  lock: bool
  color_token: string
  clips: [Clip]
  group?: track_group_id            // UI 折叠用
}
```

### 5.2 kind 闭集

不允许自定义 track kind。新增需走引擎注册流程，并在本文档登记。每种 kind 的 clip 必填字段见 §6.3。

### 5.3 mute / solo / lock 语义

- mute：评估时跳过该 track 的所有 clip
- solo：当 sequence 中存在任意 solo track，仅 solo track 参与评估
- lock：禁止 capability 写入；UI 仍可读

solo / lock 状态属于编辑会话偏好，**不写入 SequenceDocument 持久化**（避免不同 reviewer 互相干扰）。mute 则是文档级，参与渲染。

---

## 6. Clip

### 6.1 通用字段

```text
Clip {
  id, name,
  shot_range: FrameRange            // 在所属 shot 内的局部 range
  source_offset: i64                // 源资产起点偏移
  time_warp: float                  // 1.0 默认；retime 用
  enabled: bool
  blend_in_frames: i64
  blend_out_frames: i64
  ease: linear | ease_in | ease_out | ease_in_out | step
  weight: float [0,1]
  bindings: [Binding]
  payload: ClipPayload              // 由 track.kind 决定
  provenance: authored | inferred | baked
}
```

### 6.2 时间约束

- shot_range 必须落在 shot.range 内（含端点）
- time_warp 0 视为静止帧（hold first frame），负值非法
- blend_in + blend_out ≤ shot_range.duration

### 6.3 ClipPayload by track.kind

| track.kind | payload 关键字段 |
|------------|-------------------|
| animation | `clip_asset_uri`（指向 PerformanceClipDocument 或 AnimationClip）, `additive: bool`, `root_motion: bake | strip | passthrough` |
| camera | `camera_asset_uri`, `keyframes?: CameraKeyframe[]`, `framing_recipe?: FramingRecipeRef` |
| audio | `audio_uri`, `gain_db`, `pan`, `bus`, `sync_marker_id?` |
| event | `event_id`（来自 GameplayActionRegistry 中允许在 sequence 中触发的子集），`args` |
| subscene | `nested_sequence_uri`, `iso_time_base: bool` |
| fx | `fx_asset_uri`, `params`, `seed?` |
| lighting | `lighting_proposal_uri | inline_overrides[]`, `usage_kind: cinematic` |
| post_process | `pp_chain_uri`, `params` |
| data | `data_table_branch_id`, `apply_scope: shot | until_clip_end` |

event clip 在 sequence 评估器中触发，与 runtime gameplay 事件共享注册表，但执行上下文标 `cinematic`。

---

## 7. Binding

Binding 把 clip 内的抽象目标（"主角骨骼"）解析到当前 SceneDocument 中的具体 instance。

### 7.1 字段

```text
Binding {
  id,
  abstract_role: string             // "main_character" / "key_light" / "hero_prop"
  resolved_target: {
    doc_uri,                        // SceneDocument
    target_id,                      // instance / component / socket
    sub_path?                       // bone path / blendshape name / parameter name
  }
  required_capabilities: [string]   // 例如 ["skeleton:humanoid", "socket:hand_l"]
  fallback_strategy: skip | proxy | error
  resolution_status: bound | unbound | conflict | stale
  resolved_at?: timestamp
}
```

### 7.2 解析时机

- 编辑时：UI 提交后立刻解析，失败进入 MinimalConfirmationUI
- 评估时：再次校验 resolved_target 仍然有效，stale 则按 fallback_strategy 处理
- 渲染前：所有 Binding 必须 `bound`，否则提交 `render.submit_*` 报错

### 7.3 重绑定

- `binding.rebind` 走 capability，required cfm
- rebind 历史保留在 binding 的 audit log（不在本文档展开）
- 原 abstract_role 不变，便于 clip 与重绑定解耦

### 7.4 与 GameplayBinding 的隔离

- SequenceDocument 的 Binding 不影响 runtime gameplay
- 同一 character instance 可同时被 GameplayBinding 与 SequenceBinding 引用
- 当 sequence 处于评估状态时，cinematic 绑定优先；退出后 gameplay 接管

---

## 8. ShotOverride 与 SceneDocument 的合成规则

EvaluationContext 在求值帧 `f` 时按以下顺序合成：

```
1. SceneDocument.authored      （baseline）
2. PrefabDocument 应用          （asset → prefab → instance override 的常规链）
3. SequenceDocument.shots[s].overrides   （s 是包含 f 的 shot）
4. shots[s].tracks[t].clips[c]           （按 track 顺序、clip 顺序）
5. caches[*]（命中则替换求值结果）       （见 §11）
```

约束：

- 任一步产出的字段都带 provenance 链；`EvaluatedSceneSnapshot` 中可回溯
- override 不会写回 SceneDocument
- AI 修改 SceneDocument 与修改 shot override **是不同 capability**，目录中分别登记

---

## 9. SequenceCache

```text
SequenceCache {
  id, kind: physics | cloth | fluid | hair | gi | particle | render_proxy
  shot_id, clip_id?,
  range: FrameRange                 // cached 的真实范围（可短于 shot range）
  storage_uri,
  source_revision: Revision         // 烘焙时的 shot revision
  invalidation_policy: strict | tolerant
  hit_strategy: exact | nearest_frame | interpolate
}
```

约束：

- strict：source_revision 不匹配立即失效
- tolerant：source_revision 不匹配时仍可读，但标 `stale_cache` 进 diagnostics
- 渲染 final 必须 strict
- 缓存写入由 `bake.*` capability 执行（见目录 §10）

---

## 10. usage_kind 与摄像机 / 光照边界

为避免游戏与影视场景的灯 / 摄相互污染：

```text
usage_kind: cinematic | gameplay | both
```

应用规则：

| usage_kind | runtime 启用 | sequencer 启用 |
|------------|--------------|----------------|
| cinematic | 否 | 是 |
| gameplay | 是 | 否 |
| both | 是 | 是 |

- 灯：写入 SceneDocument 时必填 usage_kind；shot override 默认 cinematic
- 摄像机：cine_camera asset 必为 cinematic；shot 引用的 camera_binding 强制 cinematic 或 both
- runtime 评估器忽略 cinematic-only 节点；sequencer 评估器忽略 gameplay-only 节点
- both 节点在两侧都参与评估，参数差异通过 ShotOverride 表达

---

## 11. Revision 与并发

```text
Revision {
  id, parent_id, author, created_at,
  base_doc_revision: SceneDocument.revision_id,
  base_seq_revision: SequenceDocument.revision_id,
  intent_log_ref?, transaction_ids: [...]
}
```

- 每次成功 apply 的 Transaction IR 产出新 revision
- 多人编辑同一 sequence 通过 base_revision 检查冲突
- 冲突解决走 MinimalConfirmationUI 的 `resolve_conflict` question
- shot / track / clip 的 revision 独立，避免一人改 light、一人改 retime 时互相阻塞

---

## 12. 持久化与序列化

### 12.1 文件布局

```
project/
  sequences/
    seq_010/
      sequence.json                 // SequenceDocument 元 + shots / cuts / markers
      shots/
        sh_020/
          shot.json                 // Shot + tracks 索引
          tracks/
            cam_main/
              track.json
              clips/
                clip_*.json
            anim_hero/
              ...
          overrides/
            *.json
          caches/
            *.bin (binary)
            *.meta.json
      audit/
        revisions.log
```

### 12.2 序列化原则

- 所有 ID 稳定，不依赖文件路径或顺序
- JSON 字段排序固定（便于 git diff）
- 二进制 cache 与 meta 分文件存储
- 不引入隐式依赖：clip 引用 asset 一律用 uri，不靠相对路径推断

---

## 13. 与 AI 流水线的对接

| 流水线 | 写入位置 |
|--------|----------|
| `ai-native-semantic-pipeline-design.md` | ModelDocument（间接影响 binding 的 required_capabilities） |
| `ai-native-scene-from-image-design.md` | SceneDocument（不直接进 SequenceDocument） |
| `ai-native-film-workflow-design.md` §2 ShotPlanning | SequenceDocument 全部层级 |
| `ai-native-film-workflow-design.md` §4 Camera Language | shot.camera_binding + camera ShotOverride + camera Clip |
| `ai-native-film-workflow-design.md` §6 Lighting Design | lighting Track + ShotOverride |
| `ai-native-game-workflow-design.md` cinematic 子集 | 同上，但 status 与 capability 过滤更严 |

---

## 14. 验收标准

下列条件全部满足，本设计视为可交付：

1. 给一段 60 帧 sequence，包含 3 shot、2 cut、1 dissolve、5 track，能稳定按 §8 规则评估出 EvaluatedSceneSnapshot
2. 改 fps 24→30 后 retime 模式（保比例 / 保帧数）按 cfm 选择正确执行，所有 clip range 合法
3. ShotOverride 不污染 SceneDocument（apply override → revert → SceneDocument revision 不变）
4. cinematic light 不在 runtime 评估器出现，gameplay light 不在 sequencer 评估器出现
5. solo / lock 状态切换不写入文档，关闭工程后不残留
6. binding stale 时按 fallback_strategy 行为正确，且渲染提交被阻断
7. cache 在 strict 策略下 source_revision 不匹配 100% 失效
8. 多人同时编辑同一 shot 不同 track 不互相阻塞，不同人改同 clip 触发 resolve_conflict question

---

## 15. 与旧 Zig 的迁移

旧 Zig 的 `Sequence + Track` 结构与新模型不向后兼容。迁移策略：

1. 旧 `Sequence` → 新 `SequenceDocument`，整段视为单一 shot（auto_shot）
2. 旧 `Track` → 新 `Track`，kind 按 payload 推断；推断失败标 `kind=unknown`，进入 PendingReviewQueue
3. 旧 `Track` 上的关键帧 → 新 `Clip`（每段连续关键帧打包为一个 clip）
4. 旧的"全局事件"轨 → 新 `event` track
5. 迁移产物 provenance = `inferred`，必须 reviewer 升格为 authored
6. 迁移工具走 `sequence.import_legacy` capability（required cfm），不可批量自动化

迁移期间允许两套文档共存，但同一项目不允许同时存在新旧 SequenceDocument 引用同一 shot 内容。

---

## 16. 不在范围

- 渲染队列调度细节（见 `ai-native-film-workflow-design.md` §7 与 RenderJobDocument 子文档）
- 音频混音器 / 总线设计（音频 clip 仅声明 bus，不定义 bus 拓扑）
- DI / 调色 LUT 管线
- 实时虚拟制片的 LED 墙时序同步
- VR / 立体声格式

---

## 17. 后续待办

- ClipPayload 各 kind 的完整 schema 拆分子文档
- Binding 的角色解析策略库（人形 / 四足 / 多目标编队）
- Cache 的存储格式与压缩策略
- 跨 sequence 的引用与共享（pre-vis ↔ final 复用 shot 列表）
- 与版本控制系统的合并策略（JSON diff / merge driver）
- 多人协作的实时同步协议（OT / CRDT 选型）
