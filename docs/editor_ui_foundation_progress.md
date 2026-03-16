# 编辑器 UI 基础设施进度

日期：2026-03-17

本文记录 `docs/editor_ui_implementation_plan.md` 中各提交的已落地部分。

## 提交3已完成：Viewport 投放工作流

### 已完成

- **history.zig 新增 spawnAt 函数**：
  - `spawnEmptyEntityAt(transform)`
  - `spawnCameraEntityAt(transform)`
  - `spawnPrimitiveAt(primitive, transform)`
  - `spawnPointLightAt(transform)`
  - `spawnSpotLightAt(transform)`
  - `spawnDirectionalLightAt(transform)`
- **viewport.zig 拖放处理**：
  - 添加 `place_actor_drag_payload` 接收
  - 实现基于地平面 (y=0) 的射线相交计算投放位置
  - 失败时回退到默认 spawnTransform 逻辑
- **修复样式变量类型错误**：
  - `item_spacing` 需要 Vec2 类型

### 本提交未做

- Snapping 真正作用到 manipulation
- Overlay 图标化 popup 改造

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
- `layout.zig` 新增 Inspector 双列属性表辅助函数
- Inspector 面板按钮紧凑化：
  - 全宽按钮改为小按钮
  - 使用 sameLine 紧凑排列

### 本提交未做

- Viewport 接收 `place_actor_drag_payload` 投放逻辑（已在提交3完成）
- snapping 真正作用到 manipulation

## 下一步

按主实施文档当前顺序，后续工作可包括：

- 材质编辑器独立窗口
- Scene Hierarchy 树形视图增强
- 其他 UI 优化

## 额外完成

### Scene Hierarchy 增强：Folder 创建

- 在 Scene Hierarchy 右键菜单 Create 中添加 Folder 选项
- Folder 本质上是一个空实体，用于组织场景层级
- 用户可以将实体拖拽到 Folder 下进行分组

### 资产预览

- 资产预览功能已相当完善
- 支持纹理预览、模型信息、材质信息
- 支持缩略图大小调节

## 提交4已完成：Viewport 吸附(Snapping)

### 已完成

- **manipulation.zig 吸附功能**：
  - 平移吸附 (translation_snap_enabled)：按 translation_snap_step 整数倍对齐
  - 旋转吸附 (rotation_snap_enabled)：按 rotation_snap_step_degrees 整数倍对齐
  - 缩放吸附 (scale_snap_enabled)：按 scale_snap_step 整数倍对齐
- **Viewport Overlay 菜单**：
  - 新增 Snap 子菜单
  - 可独立控制 Translation/Rotation/Scale 吸附开关
