# MinimalConfirmationUI 详细设计

> 本文档是 `ai-native-scene-model-design.md` §7、`ai-native-semantic-pipeline-design.md` §2.7、`ai-native-scene-from-image-design.md` §2.12、`ai-native-game-workflow-design.md`、`ai-native-film-workflow-design.md` 共用的子设计。
> 适用范围：所有 `AmbiguityScorer` 判定为 NeedsConfirmation 时由用户进行最小确认的统一 UI。
> UI token 与组件契约对接 `guava-ui-design-system.md`。

---

## 0. 设计前提

1. UI 是流水线唯一的"打断用户"出口，必须把"打断"的成本降到最低
2. 同一批 ambiguity 必须**一次性问完**，不允许反复弹窗
3. 默认操作必须**单键 / 单点**可完成
4. 任意时刻可"跳过"，跳过项进入 `pending_review`，不丢失
5. 不识别用户身份则不让其确认 `cfm = required` 及以上的项
6. UI 永远只是**协议消费者**，不持有业务状态；状态属于 `AmbiguityScorer` 与 capability 层
7. 视觉层走 `guava-ui-design-system.md` 的 token，不在本文档定义颜色 / 字号

---

## 1. 调用契约

UI 的输入由 `AmbiguityScorer` 通过 Observation Bus 事件 `ConfirmationRequested` 触发：

```text
ConfirmationRequest {
  batch_id,
  origin: pipeline_id           // semantic | scene_from_image | game | film | ...
  correlation_id,
  questions: [Question],
  context_snapshot_uri,         // 引擎瞬时状态快照（可读不可写）
  expires_at?: timestamp,
  required_role?: viewer | editor | reviewer | owner
}
```

UI 的输出通过 `ConfirmationResolved` 事件返回：

```text
ConfirmationResolution {
  batch_id, correlation_id,
  answers: [Answer],
  user_id, decided_at, duration_ms,
  partial: bool                 // true 表示有 skipped 项
}
```

约束：

- UI **不直接调 capability**，只产出 Answer
- Answer 由 `AmbiguityScorer` 的 commit 阶段翻译成 Transaction IR
- batch 关闭后再补答必须新发 ConfirmationRequest，不接受过期 batch 的 Answer

---

## 2. Question / Answer schema

```text
Question {
  id,                                    // 在 batch 内唯一
  kind: choose_one | choose_many | confirm_region | toggle_scope
      | name_alias | adjust_value | resolve_conflict | approve_destructive,
  prompt_short,                          // ≤ 60 字
  prompt_detail?,                        // 可折叠
  evidence: [EvidenceRef],               // 用于视口高亮 / 缩略图
  options?: [Option],                    // choose_* 用
  default_option?: option_id,
  shortcut_hint?: KeyHint,
  severity: info | warn | destructive,
  reversible: bool,
  ambiguity_score: float [0,1],
  source_proposal_ids: [id]
}

Option {
  id, label_short, label_detail?,
  preview_thumbnail_uri?, evidence_overlay_uri?,
  side_effect_summary?: string
}

EvidenceRef {
  kind: region | instance | shot | clip | data_row | mesh_slice | image_bbox,
  doc_uri, target_id,
  highlight: { color_token, decoration: outline | fill | dashed | flash }
}

Answer {
  question_id,
  outcome: accepted | rejected | skipped | renamed | scoped | adjusted,
  picked_option_id?,
  alias?,
  scope?: asset | instance | shot_override,
  adjusted_value?,
  note?: string
}
```

设计点：

- `evidence` 是 UI 与编辑器的**唯一**联动通道（高亮、相机聚焦），不通过 selection 副作用
- `default_option` 必须可单键 accept；不存在 default 时不允许单键 accept
- `severity = destructive` 必须强制二次输入（见 §6）

---

## 3. 入口与展示形态

UI 三种形态，按 batch 大小与 origin 自动选择：

| 形态 | 触发条件 | 展示位置 |
|------|----------|----------|
| Inline Hint | 单 question + severity=info + reversible=true + 当前 viewport 可见 evidence | 视口顶部 1 行条带，可单键 enter accept |
| Side Sheet | 1 ≤ N ≤ 8 questions，或含 evidence 需要交互 | 编辑器右侧 sheet，宽度自适应 |
| Batch Review | N > 8 questions，或来自 ship / destructive 类 batch | 全屏 review 面板 |

形态切换约束：

- 同一 batch 不在三种形态间跳转，初次决定后稳定
- Side Sheet / Batch Review 关闭即视为 partial = true（剩余项 skipped）
- Inline Hint 不允许 destructive question 出现（被升级为 Side Sheet）

---

## 4. Side Sheet 布局

按 `guava-ui-design-system.md` 的 surface 阶梯：

- 容器：`surfaceFloating`（L3）
- question 卡片：`surface`（L1） + 1px `outline`
- 选中态：`accentMuted` halo + `accent` 1.5px 描边
- destructive：`error` 描边 + `errorContainer` 背景

结构：

```
┌────────────────────────────────────────────────────────┐
│ Header: "5 项需要确认 · 来自 semantic_pipeline"   [×] │
│ Progress: ●●○○○                                        │
├────────────────────────────────────────────────────────┤
│ Q1 [region] 这两个高亮区域是耳朵吗?                    │
│   ◯ 是    ◯ 不是    ◯ 重命名…    ◯ 跳过                │
│   evidence: region_07 / region_08 (在视口已高亮)       │
│   shortcut: ↩ 接受默认 · 1/2/3 选项 · S 跳过           │
├────────────────────────────────────────────────────────┤
│ Q2 ...                                                 │
├────────────────────────────────────────────────────────┤
│ Footer:  [全部默认] [全部跳过] [应用 (3/5)]            │
└────────────────────────────────────────────────────────┘
```

关键约束：

- Header 固定显示来源 pipeline，让用户知道"是谁在问"
- Footer 的"应用"按钮始终显示已答 / 总数，避免误以为已答完
- Progress dots 对应 question 顺序，可点击跳转

---

## 5. 键盘流（核心）

UI 以键盘为主、鼠标为辅。默认绑定：

| 键 | 行为 |
|----|------|
| `↩` Enter | 接受当前 question 的 default_option（若有） |
| `1` … `9` | 选当前 question 的第 N 个 option |
| `S` | 跳过当前 question |
| `R` | 重命名 / 自由输入（kind 支持时） |
| `D` | 展开 prompt_detail / evidence_overlay |
| `↓` `↑` | 上下切换 question |
| `←` `→` | 在当前 question 的 options 间移动 |
| `Tab` | 在 [options / scope toggle / footer] 之间循环 |
| `Esc` | 关闭面板（剩余 skipped） |
| `⌘⏎` / `Ctrl+Enter` | 应用所有已答 |
| `⌘⇧⏎` / `Ctrl+Shift+Enter` | 应用 + 把"未答全部接受 default"（destructive 不在此范围） |
| `⌘.` / `Ctrl+.` | 把当前 batch 推迟到 pending_review 队列 |

约束：

- 焦点环必须可见（满足 §10 可访问性）
- destructive question 禁用 Enter / 数字键的"快速 accept"，必须经 §6 二次输入
- 快捷键冲突时本 UI 优先级高于编辑器全局快捷键，关闭后归还

---

## 6. Destructive 二次确认

针对 `severity = destructive` 或 capability `cfm = destructive_required`：

1. option 卡片不出现"接受"按钮，改为"输入短语"输入框
2. 短语来自 question 的 `confirm_phrase`（如 "delete prefab" / "merge branch"）
3. 输入正确才解锁"应用"按钮
4. 输入错误 N 次后冷却 30 秒，避免连点
5. 应用后写入 audit trail（`ReleaseAuditDocument` 或对应域 audit）

短语必须本地化，但比对时**忽略首尾空白与大小写**，不容忍其他差异。

---

## 7. Evidence 联动

UI 与编辑器视口的联动遵循只读契约：

- UI 在显示某 question 时，编辑器自动按 `evidence` 高亮相应目标
- 高亮颜色用 `accent` ramp，不复用 selection（避免污染用户原选择）
- UI 关闭时高亮自动清理
- evidence 类型为 `mesh_slice` 时调用 `MeshTopologySlice` 的局部展示，不展开全模型
- evidence 类型为 `image_bbox` 时打开图像浮窗，可缩放，不修改原图
- evidence 类型为 `data_row` 时聚焦到对应 DataTable 行，不进入编辑模式

UI 不允许通过 evidence 联动触发任何写操作。

---

## 8. 跳过、推迟与 pending_review

跳过 / 推迟项进入 `PendingReviewQueue`：

```text
PendingReviewItem {
  item_id, batch_id, question, snapshot_uri,
  origin_pipeline, created_at, age_warn_at,
  related_doc_revisions: [...]
}
```

行为：

- 编辑器侧栏显示 `Pending Review` 计数
- 单击进入"重新发起"流程：UI 重新弹出仅含此项的 batch
- 关联的 doc revision 已变更超过阈值时，标 `stale`，要求用户先决定保留 / 丢弃
- 项目可配置最大队列长度，超出按 LRU 淘汰并写 diagnostics

---

## 9. 失败与降级

| 场景 | 策略 |
|------|------|
| evidence 引用的目标已被删除 | 用 placeholder 显示"目标已不存在"，禁止 accept，仅允许 skip |
| context_snapshot 过期 | UI 顶部出现 stale 警告，accept 按钮要求二次确认 |
| capability 在 batch 期间被项目策略禁用（如进入 ship） | 整个 batch 标 `policy_blocked`，options 灰显，仅允许 skip |
| Observation Bus 断连 | UI 锁定为只读，提示"等待恢复"，不发出 Resolution |
| 用户角色不足 | 整批 batch 显示"需要 reviewer 权限"，附"请求审阅"按钮 |
| 多用户同时打开同一 batch | 后到者显示"已有人在处理"，进入只读跟随模式 |

UI 永远不会"假装应用成功"，未确认的状态永远透明可见。

---

## 10. 可访问性

强制约束：

1. 全部交互可仅用键盘完成
2. 焦点环对比度 ≥ 3:1，焦点位置永远可见（不被滚动遮挡）
3. 颜色不是唯一信号：severity 同时用图标 + 文字
4. 文字最小尺寸跟随系统字号设定，不写死 px
5. 屏幕阅读器：每个 question 暴露 `role="group"`，含 prompt_short / prompt_detail / option 列表
6. 高亮联动同步发出无障碍通知（"已聚焦到 region_07，位于模型顶部"）
7. 动效（progress dot 切换、destructive 抖动）尊重 `prefers-reduced-motion`
8. 颜色主题随系统切换，不在 UI 内单独配置

---

## 11. 视觉规范（与 design system 的接合点）

不在本文档复述 token 值，仅列绑定关系：

| UI 元素 | token |
|---------|-------|
| 容器（Side Sheet / Batch Review） | `surfaceFloating` / `surfaceOverlay` |
| Question 卡片 | `surface` + `outline` |
| 焦点 question | `accentMuted` halo + `accent` 边 |
| 当前 option | `accentMuted` 背景 |
| destructive 卡片 | `errorContainer` + `error` 边 |
| Inline Hint | `surfaceVariant` 条带 |
| 文本（主） | `onSurface` |
| 文本（次） | `onSurfaceVariant` |
| 禁用文本 | `onSurfaceMuted` |
| 快捷键提示 | `onSurfaceMuted` + 等宽字体 token |
| 进度点 | active = `accent`，rest = `outlineVariant` |

新增 token 的请求统一进 `guava-ui-design-system.md`，本文档不私自扩展。

---

## 12. 国际化

- prompt_short / prompt_detail 走 i18n 资源 key，不在 question payload 内嵌固定语言
- 短语二次确认按 locale 切换匹配规则；中文短语忽略全角 / 半角差异，英文忽略大小写
- 数字 / 单位按 locale 格式化（如尺寸 `0.45 m` / `45 cm`），但 Answer 内回填用规范化值（米 + 浮点）

---

## 13. 性能预算

- UI 首屏渲染 ≤ 80 ms（Side Sheet）/ ≤ 150 ms（Batch Review）
- evidence 联动高亮 ≤ 16 ms（不卡帧）
- 单 batch question 数硬上限 200，超出强制分批
- 任意 question option 数硬上限 8，超出折叠"更多…"

---

## 14. 与各域文档的对接

| 来源 | 触发条件 | 典型 question kind |
|------|----------|--------------------|
| `ai-native-semantic-pipeline-design.md` §2.6 | region 标签冲突 / 低置信 | choose_one / confirm_region / name_alias |
| `ai-native-scene-from-image-design.md` §2.12 | 资产候选歧义 / 位姿二义 / 光照多解 | choose_one / resolve_conflict / toggle_scope |
| `ai-native-game-workflow-design.md` §3 | ScriptValidator 多轮失败 | resolve_conflict / approve_destructive |
| `ai-native-game-workflow-design.md` §6 | 数值表 merge 冲突 | resolve_conflict / approve_destructive |
| `ai-native-film-workflow-design.md` §6 | 多光提案需要逐项确认 | choose_many |
| `ai-native-film-workflow-design.md` §8 | annotation → capability 候选选择 | choose_one |
| `ai-native-capability-catalog.md` `cfm = destructive_required` | 任意调用方 | approve_destructive |

各域文档发起 question 时只关心 schema，不关心 UI 形态选择。

---

## 15. 验收标准

下列条件全部满足，视为可交付：

1. 一批 5 个 info 级 question 可在 ≤ 5 秒内全部用键盘走完
2. destructive question 100% 经过二次输入才能 apply，且短语错误冷却生效
3. 任一 evidence 在显示时正确高亮，UI 关闭后高亮全部清理
4. partial 关闭后 skipped 项 100% 出现在 PendingReviewQueue
5. 屏幕阅读器可朗读完整 question 与 option 列表，朗读顺序符合视觉顺序
6. context_snapshot 过期场景中 UI 不会发出错误 Resolution
7. UI 不依赖任何业务模块，可在 mock pipeline 下独立启动
8. 视觉 token 100% 来自 `guava-ui-design-system.md`，无硬编码颜色

---

## 16. 不在范围

- 协作评论 / 多人异步 review（属于影视 ReviewDocument，单独 UI）
- 长文本编辑（短语二次确认仅做匹配，不做内容编辑）
- 通知中心（pending_review 是数据，通知是另一套通道）
- AI 辅助回答 question 自身（避免无限递归）

---

## 17. 后续待办

- batch 打分算法：决定 Inline / Sheet / Batch Review 的边界值
- PendingReviewQueue 的项目级配额与告警策略
- destructive 短语库的本地化与可配置
- evidence 联动在多窗口 / 多 viewport 下的目标选择策略
- 与 `Observation Bus` 的事件 backpressure（高频 batch 涌入时如何节流）
- UI 自身的 telemetry：每类 question 的平均决策时长、跳过率、修改率
