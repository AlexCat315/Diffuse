# 编辑器 UI 基础设施进度

日期：2026-03-17

本文记录 `docs/editor_ui_implementation_plan.md` 中各提交的已落地部分。

## 提交2已完成：Place Actors + 新默认布局

### 已完成

- 新增 `src/editor/ui/windows/place_actors.zig` 面板：
  - 四个分类 Tab：Basics、Lights、Shapes、VFX
  - Actor 条目列表（Empty、Camera、Cube、Sphere、Plane、Point Light、Spot Light、Directional Light）
  - 搜索过滤功能
  - 拖拽发射 `place_actor_drag_payload`
- 调整默认 DockBuilder 布局：
  - 左侧：Place Actors
  - 右侧上方：Scene (Outliner)
  - 右侧下方：Details (Inspector)
  - 底部：Content Browser
  - 中心：Viewport
- Viewport 浮动工具条优化：
  - 添加 `no_background` 标志
  - 降低背景透明度从 0.72 到 0.6
- 新增 i18n 翻译：
  - `spot_light`、`directional_light` 消息 ID
  - 对应中英文翻译
- `layout.zig` 新增 Inspector 双列属性表辅助函数：
  - `beginInspectorPropertyTable()`
  - `endInspectorPropertyTable()`
  - `drawInspectorPropertyRow()`

### 本提交未做

- Viewport 接收 `place_actor_drag_payload` 投放逻辑
- Inspector 双列排版完整改造（大按钮移到右键菜单）
- snapping 真正作用到 manipulation

## 下一步

按主实施文档当前顺序，下一步是"提交 3：Viewport 投放工作流"：

- Viewport 接收 `place_actor_drag_payload`
- 地平面求交 / 失败回退逻辑
- `history` 中新增 `...At(transform)` 生成入口
