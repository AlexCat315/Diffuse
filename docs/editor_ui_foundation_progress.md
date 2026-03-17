# 编辑器 UI 基础设施进度

日期：2026-03-17

本文同步 `docs/editor_ui_implementation_plan.md` 的真实落地状态，只记录当前分支已经实现并验证过的内容。

## 已完成：提交 2 Place Actors + 新默认布局

- 新增 `src/editor/ui/windows/place_actors.zig` 面板，包含分类、搜索、拖拽和点击生成入口。
- 默认 DockBuilder 布局已切到经典编辑器布局：
  - 左侧 `Place Actors`
  - 右侧上方 `Scene`
  - 右侧下方 `Details`
  - 底部 `Content Browser`
  - 中间 `Viewport`
- `drawEditorUi()` 已接入新窗口和新布局。
- Inspector 通用双列属性表 helper 已在 `src/editor/ui/layout.zig` 中提供。

## 已完成：提交 3 Viewport 投放工作流

- `src/editor/actions/history.zig` 已提供 `spawn...At(transform)` 系列入口。
- Viewport 已接收 `place_actor_drag_payload`，并基于地平面求交优先决定投放位置。
- 交点不可用时会回退到默认 `spawnTransform()`。
- 模型拖放也已经改成按落点放置，而不是固定出生点。
- 生成动作接入 undo/redo 快照链路。

## 已完成：提交 4 Viewport 紧凑 Overlay 与 Snapping

- Viewport 左上 Overlay 已改成图标按钮 + popup，而不是旧的文字 `beginMenu`。
- popup 打开时会正确占用输入，避免误触视口相机控制。
- Translation / Rotation / Scale snapping 都是真实现，并且基于 manipulation origin 相对吸附。
- `Ctrl+Shift+T` / `Ctrl+Shift+R` / `Ctrl+Shift+S` 已真实绑定到三类吸附开关。
- 自由 orbit / look 后会把 `viewport_view_preset` 更新为 `.custom`。

## 已完成：提交 5 Inspector 工业化

- Inspector 顶部摘要区已改成常驻双列表单，固定展示：
  - Selection Count
  - Entity ID
  - Name
  - Component Filter
- `Material` / `Camera` / `Light` section 已统一切到 property table 布局。
- `Transform` 保留专用四色三轴 scrub 表格，没有退回普通表单。
- `Identity` / `Mesh` 也已切到统一属性网格。
- 旧的 Inspector toolbar 和过时 helper 已清理，主路径只保留一套实现。
- 搜索过滤、右键 header context menu、材质实例化和贴图赋值链路保持可用。

## 已完成：提交 6 Outliner 结构优化

- Folder 已是显式语义，不再复用 `editor_only` 伪装。
- `engine.scene.Entity` / scene 序列化已经包含 `is_folder`。
- Folder 可创建、复制、序列化，并且 hierarchy 图标已独立显示。
- Scene Hierarchy 拖拽现在会按当前 selection 计算 roots，只移动根节点，不重复搬运父子链。
- 将多选拖到目标节点时会批量 reparent，并保持原有多选集不被压缩成单选。
- 拖到自身后代的非法目标会被阻止，不会制造 parent cycle。
- 树节点首列图标槽已经固定宽度，避免不同类型节点文本起点抖动。
- `visible / frozen / locked` 三列现在使用统一按钮外框尺寸和列宽，行对齐更稳定。

## 已完成：提交 7 主题与字体校准

- ImGui 全局 style 已收敛到更克制的冷灰参数：
  - `WindowRounding = 4`
  - `ChildRounding = 4`
  - `FrameRounding = 3`
- `WindowPadding` / `FramePadding` / `CellPadding` / `ItemSpacing` / `IndentSpacing` 已统一收口，不再维持上一版偏圆偏松的数值。
- Viewport、Outliner 和 Asset Browser 中几个局部按钮 roundings 已降到同一档位，避免全局样式和局部控件割裂。
- 字体加载策略已整理为：
  - 优先查找 `assets/ui/fonts` 下的项目字体
  - 找不到时回退系统 UI / CJK 字体
  - 最后兜底 ImGui 默认字体
- 当前仓库尚未提交 `assets/ui/fonts` 实际字体文件，因此本分支运行时会落到“系统字体或 ImGui 默认字体”分支；这是当前真实状态，不是已内置完成。
- `Reset Dock Layout` 和 `Load Default Layout` 入口已统一走同一 helper，Settings 与 Menu Bar 不再各自分叉逻辑。

## 验证状态

2026-03-17 已重新执行：

- `zig build`
- `zig build test`
- `zig build validate`

结果：

- 三条命令全部通过。
- `validate` 输出为 `资产验证: assets=35, outputs=20, deps=1, issues=0`。

备注：

- 当前会话未做 headed UI 截图回放，因此视觉结论仍建议在后续桌面验收里补一轮人工确认。

## 下一步

下一项应进入 `提交 8：辅助增强`，优先完成：

- Browser material 一等资产支持
- Material 拖拽到实体 / Viewport 的工作流
- 面包屑与资产工作流细节收口
