# 编辑器 UI 基础设施进度

日期：2026-03-16

本文记录 `docs/editor_ui_implementation_plan.md` 中“提交 1：基础设施”的已落地部分，避免和正在重写的主实施文档混在同一份文件里。

## 已完成

- ImGui bridge 新增：
  - `openPopup`
  - `beginPopup`
  - `isPopupOpen`
  - `beginCombo`
  - `endCombo`
  - `inputTextWithHint`
- `EditorState` 新增并接入：
  - `viewport_view_preset`
  - snapping 默认状态
  - `place_actor_category`
  - `place_actor_drag_payload`
  - 统一的 `PendingViewportDrop`
- 旧视口待处理拖拽字段已移除：
  - `pending_viewport_drop_asset_index`
  - `pending_viewport_drop_kind`
- `AssetKind.material` 与材质拖拽 payload 已补齐到编辑器层。
- Browser / Preview / Viewport 的相关枚举分支已补齐，避免后续提交继续补 switch。
- 中英文文案与图标语义常量已补到 foundation 阶段所需范围。
- 已补最小测试：
  - payload 常量
  - snapping / place actor 默认值
  - `PendingViewportDrop` 默认语义
  - 材质资产映射

## 本提交未做

- `place_actors.zig` 窗口本体
- Viewport 接收 `place_actor_drag_payload`
- snapping 真正作用到 manipulation
- Overlay 图标化 popup 改造
- Folder / Outliner 结构升级

## 下一步

按主实施文档当前顺序，下一步是“提交 2：Place Actors + 新默认布局”：

- 新增 `src/editor/ui/windows/place_actors.zig`
- 调整默认 DockBuilder 布局，把 Place Actors 放到左侧
- 在 `drawEditorUi()` 中接入新窗口
