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

## 已部分完成：提交 6 Outliner 结构优化

- Folder 已是显式语义，不再复用 `editor_only` 伪装。
- `engine.scene.Entity` / scene 序列化已经包含 `is_folder`。
- Folder 可创建、复制、序列化，并且 hierarchy 图标已独立显示。
- 还未完成的部分是“多选只移动 selection roots 的批量拖拽重设父子关系”。

## 验证状态

2026-03-17 已重新执行：

- `zig build`
- `zig build test`
- `zig build validate`

结果：

- 三条命令全部通过。
- `validate` 输出为 `资产验证: assets=35, outputs=20, deps=1, issues=0`。

## 下一步

下一项应进入 `提交 6：Outliner 结构优化`，优先完成：

- 多选根节点批量拖拽重设父子关系
- 仅移动 selection roots，避免父子链重复搬运
- 阻止拖到自身后代
- 最后再做 hierarchy 行对齐细节收口
