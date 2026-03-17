# Guava Editor UI 修改实施方案

本文是当前编辑器 UI 改造的实施文档，整合了两轮需求：

1. Viewport Overlay 图标化、折叠、拖拽工作流与精确编辑
2. Place Actors 面板与“拖到视口即生成”场景搭建体验
3. Details / Inspector 工业化排版
4. Outliner 层级管理与文件夹系统
5. Docking Layout、主题与字体统一

本文不只是需求复述，而是基于当前代码库现状给出的落地方案、前置改造项、优先级重排和验收标准。

## 1. 本轮目标

本轮修改的总目标不是单点“变漂亮”，而是让编辑器形成接近工业引擎的基础工作流：

- 左侧可以拖拽放置 Actor
- 中间 Viewport 可以接收投放并完成精确摆放
- 右侧 Outliner / Details 承担结构与属性编辑
- 底部 Content Browser 提供资产浏览
- 视口编辑具有吸附、视角切换、紧凑工具链和可靠的输入隔离

换句话说，本轮最高优先级是“场景搭建工作流”，其次才是“视觉 polish”。

## 2. 现状校准

在开始修改前，必须先校准当前代码真实状态，避免基于错误前提重做。

### 2.1 Viewport 现状

- `src/editor/ui/viewport.zig` 已有顶部图标工具条。
- Viewport 左上已有悬浮 Overlay window，内部用文本菜单承载：
  - `View`
  - Render Mode
  - `Overlay`
- 当前 Overlay 依赖 `state.viewport_overlay_hovered` 阻止相机输入穿透。
- 右上已经不是简单文字方向按钮，而是自定义 bridge 暴露的 3D ViewCube 控件。
- 当前没有位移 / 旋转 / 缩放吸附状态，也没有对应后端吸附逻辑。

结论：

- Overlay 不是从零开始做，而是从“文本菜单悬浮层”升级为“更紧凑的工业风图标菜单”。
- ViewCube 不是空白项，因此“是否替换为 ImGuizmo::ViewManipulate”不是最高优先级。
- 真正缺失的是 Snapping、投放语义、以及更少遮挡的控制方式。

### 2.2 场景搭建入口现状

- 当前没有独立的 Place Actors 面板。
- 当前创建对象主要来自：
  - 快捷键
  - Scene Hierarchy 窗口上下文菜单
- 现有历史动作接口已经能生成：
  - Empty
  - Camera
  - Cube
  - Sphere
  - Plane
  - Point Light
- Content Browser 已支持部分资产拖拽：
  - `model`
  - `texture`
- Viewport 已能接收部分资产拖拽，但 `model` 仍然默认生成为“相机前方 3 米”，不是真正的“拖到哪放到哪”。

结论：

- Place Actors 面板不是补一个窗口标题就够了，它必须和 Viewport 投放逻辑、默认布局、历史记录、实体生成入口一起设计。

### 2.3 Inspector 现状

- Inspector 已有搜索过滤 `inspector_filter_buffer`。
- Header 右键菜单已经存在，复制 / 粘贴 / 删除逻辑已打通。
- Transform 区当前已经不是最原始的 ImGui 堆叠样式，而是 4 列 table：
  - 标签列
  - X
  - Y
  - Z
- Transform 的 X / Y / Z 轴已经有颜色标签。
- Transform 数值控件已经使用 `dragFloat`，已有 Scrubbing 基础。
- 非 Transform 区域仍以 `labelText + 控件` 为主，信息密度和对齐度不统一。

结论：

- Inspector 不是从“完全原生堆叠风格”开始。
- 本轮目标应改为“把现有局部工业化能力扩展到整个 Details 面板”，而不是推翻重写。

### 2.4 Outliner 现状

- 当前 Scene Hierarchy 已经支持：
  - 单选 / Ctrl / Shift 多选切换
  - 实体拖拽重设父子关系
  - 冻结 / 锁定 / 显隐
  - 动态实体图标
- 图标已基于组件类型动态分配：
  - Camera
  - Light
  - Mesh
  - Object
- 当前没有“纯管理用文件夹”实体语义。
- 当前拖拽重设父子关系主要以单实体为中心，不是完整的多选根节点批量拖拽。

结论：

- 类型图标不是缺失项，而是“对齐和扩展项”。
- 真正缺的是 Folder 语义和批量拖拽父子逻辑。

### 2.5 Layout / Theme / Font 现状

- `src/engine/ui/imgui_bridge.cpp` 已有默认 DockBuilder 布局。
- 当前默认布局大致为：
  - Center: Viewport
  - Left: Scene
  - Right: Details
  - Bottom: Content Browser
  - Top: Global Toolbar dock target
- 当前已有深灰偏冷主题，颜色并不是纯黑或紫色。
- 当前已经设置：
  - `FrameBorderSize = 0`
  - 较明显的 rounding
  - 平台英文字体 + CJK 字体合并
- 当前字体不是统一内置资产，而是优先寻找系统字体。

结论：

- 主题系统不是空白项，因此“换深灰主题”不是最高优先级。
- 真正优先的是“布局骨架改成 Place Actors / Viewport / Outliner / Details / Content Browser 的经典工作区”。
- 字体统一若要真正跨平台一致，必须从“系统字体探测”升级为“项目内置字体资源”。

## 3. 重新设计后的优先级

本轮优先级重排如下。

### P0：场景搭建主工作流

这是本轮最高优先级，必须最先落地。

- 新增 Place Actors 面板
- Viewport 接收 Place Actor 拖拽
- 增加射线 / 地平面 / 命中回退的投放逻辑
- 重构默认 Dock 布局，给 Place Actors 留左侧固定位置

原因：

- 这是 UE/Unity 级编辑器最核心的“搭场景”入口。
- 没有这一层，后续 Overlay、Inspector 再漂亮，也只是“更好看的属性编辑器”。

### P1：Viewport 工具链与精确编辑

- 紧凑 Overlay 菜单
- Translation / Rotation / Scale Snapping
- 更稳定的 ViewCube / 视图预设状态

原因：

- 这是每天都在用的高频操作。
- 和场景搭建主工作流强耦合，优先级仅次于 P0。

### P2：Inspector 工业化排版

- 全局双列属性布局
- 统一 label / control 对齐
- Transform 行为和视觉增强

原因：

- Details 面板是第二高频编辑区域。
- 但它不阻塞“创建与摆放”主工作流，因此排在 P0/P1 之后。

### P3：Outliner 结构优化

- Folder Entity / Editor Folder
- 多选拖拽父子关系
- 图标 / 行对齐增强

原因：

- 对复杂场景管理非常重要。
- 但在基础场景搭建和精确编辑未稳定前，优先级略低。

### P4：主题与视觉校准

- Dock 细节比例微调
- 颜色与圆角校准
- 字体资源内置化

原因：

- 当前主题已经接近目标方向，不属于阻塞项。
- 这一层应该建立在主工作流稳定后再做。

### P5：上一版文档中遗留的辅助增强

例如：

- Browser 中 `material` 作为一等资产
- Material 资产拖拽到实体 / 视口
- 更复杂的资产工作流提示

说明：

- 这些依然值得做，但相较于 Place Actors 面板，本轮不是最高优先级。
- 可以作为 P0-P4 落稳后的下一批增强项。

## 4. 前置改造

以下改造是多个工作流的共同依赖，应先完成。

### 4.1 ImGui bridge 补强

建议在以下文件补 API：

- `src/engine/ui/imgui_bridge.h`
- `src/engine/ui/imgui_bridge.cpp`
- `src/engine/ui/imgui.zig`

#### 必补接口

- `openPopup(id)`
- `beginPopup(id)`
- `endPopup()`
- `inputTextWithHint(label, hint, buffer)`

#### 建议补接口

- `isPopupOpen(id)`
- `beginCombo(label, preview)`
- `endCombo()`
- `setNextWindowSizeConstraints(...)`

说明：

- Viewport 的图标菜单最适合使用“图标按钮 + popup”而不是继续直接展示文字 `beginMenu()`。
- Inspector 和 Browser 的搜索输入框会明显受益于 hint。

### 4.2 EditorState 扩展

在 `src/editor/core/state.zig` 中建议补以下状态。

#### 4.2.1 Viewport 视图预设状态

```zig
pub const ViewportViewPreset = enum {
    perspective,
    top,
    side,
    custom,
};
```

新增字段：

```zig
viewport_view_preset: ViewportViewPreset = .perspective,
```

用途：

- Overlay 中显示当前视图状态
- 用户手动旋转后切到 `custom`

#### 4.2.2 Snapping 状态

```zig
translation_snap_enabled: bool = false,
translation_snap_step: f32 = 10.0,
rotation_snap_enabled: bool = false,
rotation_snap_step_degrees: f32 = 15.0,
scale_snap_enabled: bool = false,
scale_snap_step: f32 = 0.1,
```

说明：

- 默认值可以按编辑器常见习惯设置。
- 后续可在 UI 中提供步进预设。

#### 4.2.3 Place Actors 状态

建议新增：

```zig
pub const PlaceActorCategory = enum {
    basics,
    lights,
    shapes,
    vfx,
};

pub const PlaceActorKind = enum {
    empty,
    camera,
    cube,
    sphere,
    plane,
    point_light,
    spot_light,
    directional_light,
};
```

新增状态字段：

```zig
place_actor_category: PlaceActorCategory = .basics,
```

并增加 drag payload：

```zig
pub const place_actor_drag_payload = "guava.editor.place_actor";
```

#### 4.2.4 Viewport 待处理投放状态

当前单独的 `pending_viewport_drop_asset_index` 和 `pending_viewport_drop_kind` 不足以表达 Place Actors 和精确投放。

建议改成统一结构：

```zig
pub const PendingViewportDrop = struct {
    source_kind: enum {
        asset,
        place_actor,
    },
    asset_index: ?usize = null,
    actor_kind: ?PlaceActorKind = null,
    pixel: ?[2]u32 = null,
    target_entity: ?engine.scene.EntityId = null,
    world_position: ?[3]f32 = null,
};
```

### 4.3 图标与 i18n

#### 图标建议

在 `src/editor/ui/icons.zig` 中补：

- toolbar:
  - `camera`
  - `material`
  - `overlay`
  - `snap_translate`
  - `snap_rotate`
  - `snap_scale`
  - `folder`
- place actors:
  - `empty`
  - `camera`
  - `cube`
  - `sphere`
  - `plane`
  - `point_light`
  - `spot_light`
  - `directional_light`

#### i18n 建议

在 `src/editor/i18n/message_id.zig` 和 locale 中补：

- `place_actors`
- `basics`
- `shapes`
- `vfx`
- `view_presets`
- `render_modes`
- `overlay_options`
- `translation_snap`
- `rotation_snap`
- `scale_snap`
- `search_components`
- `search_place_actors`
- `custom_view`
- `folder`
- `new_folder`

## 5. P0：Place Actors 与场景搭建主工作流

这是本轮最优先工作流。

## 5.1 目标

让用户能在左侧选择或拖拽基础 Actor，并在 Viewport 中直接投放到合理位置。

## 5.2 新增窗口

新增文件：

- `src/editor/ui/windows/place_actors.zig`

主入口：

```zig
pub fn drawPlaceActorsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void
```

窗口标题：

- 中文：`放置 Actor`
- 英文：`Place Actors`

建议 stable id：

- `place_actors_panel`

## 5.3 面板结构

建议使用左右两段或上下两段的轻量布局。

### 左侧分类

- Basics
- Lights
- Shapes
- VFX

首版可直接做成：

- 一列 tab 按钮
- 不需要先做完整 tree 或可折叠目录

### 右侧条目

每个条目显示：

- 图标
- 标题
- 一行短说明

首批推荐条目：

- Empty
- Camera
- Cube
- Sphere
- Plane
- Point Light
- Spot Light
- Directional Light

VFX 首版可以为空或仅预留占位，不应阻塞主流程。

## 5.4 拖拽发起

每个条目绑定 `beginDragDropSource` 或当前 bridge 中的 `dragDropSourceU64`。

如果继续沿用 `u64` 载荷，建议直接传 `@intFromEnum(PlaceActorKind)`。

推荐 helper：

- `drawPlaceActorCard(...)`
- `emitPlaceActorDragPayload(kind)`

## 5.5 Viewport 接收投放

修改：

- `src/editor/ui/viewport.zig`

在 viewport image 上接收 `place_actor_drag_payload`。

### 推荐投放算法

#### 首选：地平面交点

对鼠标位置构造视口射线，与世界 `y = 0` 或编辑器配置平面求交。

适用：

- 基础物体
- 大部分 lights
- 空节点

#### 次选：命中场景表面

如果未来补齐真正的场景 Raycast，可以优先命中模型表面或碰撞体。

#### 兜底：相机前方生成

如果本次没有交点或视线几乎平行地面，回退到现有 `spawnTransform()` 逻辑，保证拖拽不会失败。

## 5.6 后端生成接口整理

现有 `history.zig` 中已经有：

- `spawnEmptyEntity`
- `spawnCameraEntity`
- `spawnPrimitive`
- `spawnPointLight`

但它们当前使用统一 `spawnTransform(state, layer_context)`。

建议新增带 transform 参数的版本，例如：

- `spawnEmptyEntityAt(state, layer_context, transform)`
- `spawnCameraEntityAt(...)`
- `spawnPrimitiveAt(...)`
- `spawnPointLightAt(...)`
- `spawnSpotLightAt(...)`
- `spawnDirectionalLightAt(...)`

说明：

- Place Actors 面板和 Viewport drop 不应继续依赖“相机前方 3 米”的默认生成逻辑。
- 原有无参版本可以继续保留，内部转发到 `...At(spawnTransform(...))`。

## 5.7 与 Layout 的联动

Place Actors 落地后，默认布局必须同步改，否则新增窗口没有合理位置。

P0 阶段就应同时改 DockBuilder：

- Left: `Place Actors`
- Center: `Viewport`
- Right Top: `Scene`
- Right Bottom: `Details`
- Bottom: `Content Browser`

## 5.8 验收标准

- 左侧存在 `Place Actors` 面板
- 至少可拖拽 Empty、Cube、Point Light 到 Viewport
- 拖拽松手后实体出现在合理位置
- 生成动作进入 history，可 undo / redo
- 默认布局能稳定显示该面板

## 6. P1：Viewport 工具链与精确编辑

## 6.1 目标

让 Viewport 具备更高密度、更少遮挡、更适合精确编辑的控制方式。

## 6.2 Overlay 图标化与收纳

### 当前问题

- 左上仍是较显眼的文字菜单
- 在较小 viewport 下遮挡感偏强

### 推荐实现

不建议完全移除现有浮动 window 模式。

推荐结构：

- 外层仍使用 `beginWindowFlags()` 控制位置、透明度和 hover
- 内部可用一个紧凑 `beginChild()` 承载内容布局

这样能同时满足：

- 半透明专业感
- 菜单紧凑排布
- 正确的 hover / input capture

### 菜单分组

保留三组逻辑，但改成图标触发 popup：

- 视图预设
- 渲染模式
- Overlay 选项

#### 视图预设

- Perspective
- Top
- Side
- 可选显示 `Custom`

#### 渲染模式

- Textured
- Wireframe
- Unlit

#### Overlay 选项

- Show Grid
- Show Bones
- Show Collision

### 输入隔离

必须保证：

- 只要 overlay hovered，则 `viewport_overlay_hovered = true`
- 只要 popup open，也要视为 overlay 占用输入

### ViewPreset 状态修正

在 `src/editor/interaction/camera.zig` 中，当用户自由 orbit / look 改变视角时：

- `state.viewport_view_preset = .custom`

## 6.3 Snapping 控制

### UI 位置

推荐放在 Viewport 顶部工具条右侧，或右上角与 ViewCube 分区相邻。

建议表现为三个 toggle 图标：

- 平移吸附
- 旋转吸附
- 缩放吸附

首版无需做完整数值下拉，先支持：

- 开关
- 默认步进值

第二版再补：

- 10 / 50 / 100
- 5° / 10° / 15° / 45°
- 0.1 / 0.25 / 0.5

### 后端实现

修改：

- `src/editor/interaction/manipulation.zig`

新增辅助函数：

- `snapTranslation(delta, step)`
- `snapAngleRadians(value, step_degrees)`
- `snapScale(value, step)`

建议采用“相对操控起点吸附”，不要直接对每帧 mouse delta 做 round。

推荐方案：

1. 操作开始时记录 `manipulation_origin`
2. 累加得到未吸附的目标 transform
3. 对目标 transform 相对 origin 的变化量做吸附
4. 再回写最终 transform

原因：

- 如果直接对 `mouse_delta` round，会造成抖动和无法细调

### 各模式建议

#### Translation

- `.free` 模式下对 3 轴分量分别吸附
- 单轴模式仅吸附对应分量

#### Rotation

- 统一对欧拉角目标值按角度步进吸附

#### Scale

- 建议对最终 scale 值按步进吸附，而不是对乘法因子直接 round

## 6.4 ViewCube 策略

### 当前事实

当前代码已经有自定义 3D ViewCube，不是简单文字按钮。

### 实施建议

本轮建议优先：

- 保留现有 ViewCube
- 修正其与 Overlay / snapping 区的布局关系
- 确保拖拽 / hover 输入稳定

是否切到 `ImGuizmo::ViewManipulate`，建议作为后续优化而不是本轮硬依赖。

原因：

- 当前真正缺的是 Snapping 和投放语义
- 替换 ViewCube 库属于较大集成面，收益没有前两者高

### 如果后续确实替换

需要评估：

- Zig / C++ bridge 集成成本
- ImGuizmo 与现有 renderer / camera 状态的同步方式
- 输入事件冲突

## 6.5 验收标准

- 左上 Overlay 为紧凑图标菜单
- 视图 / 渲染模式 / Overlay 选项均可打开 popup 切换
- 打开菜单时不会误触发视口旋转
- 三个 snapping toggle 可用
- Translation / Rotation / Scale 至少有一组默认步进逻辑可工作
- ViewCube 与新 UI 不冲突

## 7. P2：Inspector 工业化排版

## 7.1 目标

把当前“局部工业化”的 Details 面板推进为更统一、更高密度的工业表单布局。

## 7.2 本阶段的关键判断

需要纠正一个误区：

- 当前 Inspector 并非完全原始堆叠式
- Transform 行已经有彩色轴标签和 `dragFloat` Scrubbing

因此本阶段应聚焦：

- 非 Transform 区域统一到双列布局
- 顶部摘要区与过滤区梳理
- 控件宽度和对齐一致

## 7.3 目标布局

推荐把 Inspector 分成两类区域。

### 顶部摘要区

始终显示：

- Selection Count
- Entity ID
- Name
- Component Filter

说明：

- 搜索框不应依赖 `Identity` header 是否展开

### 属性区

所有 section 内尽量统一为双列属性表：

- 左列：Label
- 右列：Control

建议统一规则：

- Label 右对齐
- Control `setNextItemWidth(-1.0)`
- section 内部对齐风格一致

## 7.4 实施步骤

### 步骤 1：抽统一属性表 helper

建议在 Inspector 内或新布局 helper 中封装：

- `beginInspectorPropertyTable(id)`
- `endInspectorPropertyTable()`
- `drawInspectorPropertyLabel(label)`

### 步骤 2：Transform 保持现有 4 列结构，但微调视觉

Transform 是特殊区域，不建议强行改回普通双列表。

建议保留：

- Label 列
- X / Y / Z 三列

增强内容：

- 颜色块更细、更克制
- 轴标签和输入框的垂直对齐统一
- 让背景染色更轻

### 步骤 3：把 Material / Camera / Light 改为真正的双列属性布局

优先改这些 section：

- Material
- Camera
- Light

原因：

- 它们最容易受益于统一 property table
- 当前大量 `labelText()` 已经限制了控件区宽度和对齐一致性

### 步骤 4：保留并强化搜索与右键菜单

继续复用：

- `inspector_filter_buffer`
- `inspectorSectionMatches()`
- Header context menu

同时删除未使用的旧 `drawXComponentToolbar` 函数。

## 7.5 Transform 交互增强

### 已有基础

- `drawTransformTableRow()`
- `drawAxisDragField()`
- X/Y/Z 颜色样式
- `dragFloat` Scrubbing

### 本轮增强

- 更细的颜色条或更浅的背景染色
- 统一 X/Y/Z 轴按钮尺寸
- 让 Transform 表格在窄宽度下也保持稳定
- 与 snapping 联动时，显示被吸附后的最终值

## 7.6 验收标准

- 顶部摘要区常驻可见
- 搜索框位置固定，不依赖 header 展开
- Material / Camera / Light 等 section 使用统一双列属性布局
- 控件右列宽度一致
- Transform 仍保留彩色轴与 Scrubbing，并且对齐更整洁

## 8. P3：Outliner 结构优化

## 8.1 目标

把当前“能用的实体树”升级为能管理复杂场景的大纲系统。

## 8.2 Folder 语义设计

当前没有“纯管理型节点”。本轮建议显式引入。

### 推荐数据模型

不要复用 `editor_only` 代替文件夹。

建议新增：

- `editor_kind: .entity | .folder`

或最小版：

- `is_folder: bool`

要求：

- Folder 不参与渲染
- Folder 可有子节点
- Folder 可序列化到场景
- Folder 主要用于编辑器组织结构

### 图标

新增 folder icon，并在 hierarchy 行首显示。

## 8.3 多选拖拽父子关系

当前多选存在，但拖拽重设父子关系仍偏单节点语义。

目标行为：

- 多选若包含父子链，只移动 selection roots
- 拖到目标节点时，批量 reparent
- 阻止把父节点拖进自己的后代

建议新增 helper：

- `collectSelectionRoots(...)`
- `reparentEntities(...)`

并与现有 history 快照联动。

## 8.4 类型图标与行对齐

当前动态类型图标已经存在，因此本轮只做增强：

- 统一 icon 区宽度
- 图标与文本基线对齐
- Folder 图标优先级最高
- Camera / Light / Mesh / Object 逻辑继续保留

## 8.5 与 Place Actors 的联动

Place Actors 创建出的实体应立即：

- 出现在 Outliner
- 自动展开必要父级
- 被选中

若未来支持把 Place Actors 直接拖到 Outliner，也应复用同一生成入口。

## 8.6 验收标准

- 可创建 Folder
- Folder 可重命名 / 拖拽 / 挂子节点
- 多选实体可批量重设父子关系
- 类型图标垂直对齐稳定

## 9. P4：Docking / Theme / Font 校准

## 9.1 默认布局重设计

本轮目标布局：

- Left: `Place Actors`
- Center: `Viewport`
- Right Top: `Scene`
- Right Bottom: `Details`
- Bottom: `Content Browser`

建议在 `src/engine/ui/imgui_bridge.cpp` 中重写默认 DockBuilder split：

1. 先从中心拆左侧 `Place Actors`
2. 再拆右侧栏
3. 右侧栏再纵向拆成 `Scene` / `Details`
4. 最后从中心剩余区域拆底部 `Content Browser`

推荐初始比例：

- left: `0.18f`
- right: `0.26f`
- right_top: `0.52f`
- bottom: `0.26f`

### 关于当前 top dock

当前 builder 里有 `Global Toolbar###global_toolbar_panel` 的 dock target，但仓库中没有明显的实际 Zig 窗口实现。

建议：

- 若没有真实上方 dock 窗口，就从默认布局移除 top split
- 顶部主菜单继续由 `beginMainMenuBar()` 承担

## 9.2 Style 校准

当前主题已经是冷灰色系，方向基本正确，因此本轮只做校准：

- 背景保持深灰冷色，不切回纯黑
- 继续保持 `FrameBorderSize = 0`
- 将 rounding 从当前较圆的数值往目标靠拢

建议目标：

- `WindowRounding = 4.0`
- `FrameRounding = 3.0`
- `ChildRounding = 4.0`

说明：

- 当前值约为 7 / 5，较偏圆润
- 调整时应统一，不要只改单个控件

## 9.3 字体策略

当前字体逻辑是：

- 优先系统英文字体
- 再合并系统 CJK 字体

这能保证“能显示”，但不能保证跨平台一致。

若要接近工业编辑器体验，建议第二阶段引入内置字体资源：

- `assets/ui/fonts/Inter-Regular.ttf`
- `assets/ui/fonts/Inter-Medium.ttf`
- `assets/ui/fonts/NotoSansSC-Regular.otf`

然后在 bridge 中优先加载项目内字体，系统字体只作为 fallback。

说明：

- 若不引入内置字体，就无法保证 macOS / Windows / Linux 外观一致

## 9.4 验收标准

- 启动后默认布局符合目标工作区
- `Reset Dock Layout` 可恢复该布局
- 主题仍保持冷灰专业感
- 圆角和控件风格比当前更克制
- 字体方案有明确的“内置优先、系统兜底”策略

## 10. 辅助工作流：上一版文档中的 Browser / Material 增强

这一部分不删除，但优先级后移。

建议保留为后续增强项：

- `AssetKind.material`
- Browser 中 material 一等资产支持
- Material 拖拽到实体 / 视口
- 面包屑视觉整理

原因：

- 这些对资产工作流有价值
- 但与 Place Actors 相比，不是当前最直接的“搭场景”入口

## 11. 推荐实施顺序

建议按以下顺序提交。

### 提交 1：基础设施

- ImGui bridge popup / hint API
- `EditorState` 中的 ViewPreset / Snapping / PlaceActor / PendingViewportDrop
- 图标与 i18n 补充

### 提交 2：Place Actors + 新默认布局

- 新增 `place_actors.zig`
- 左侧分类与条目卡片
- 默认 DockBuilder 改到经典布局
- `drawEditorUi()` 中接入新窗口

### 提交 3：Viewport 投放工作流

- Viewport 接收 `place_actor_drag_payload`
- 地平面求交 / 失败回退逻辑
- `history` 中新增 `...At(transform)` 生成入口

### 提交 4：Viewport 紧凑 Overlay 与 Snapping

- 图标化 Overlay 菜单
- Snapping toggle
- `manipulation.zig` 中平移 / 旋转 / 缩放吸附
- ViewPreset 与自由视角状态联动

### 提交 5：Inspector 工业化

- 顶部摘要区重构
- 全局双列属性布局 helper
- Material / Camera / Light section 改表单布局
- 清理遗留 toolbar 死代码

### 提交 6：Outliner 结构优化

- Folder 语义
- 多选根节点拖拽重设父子关系
- 图标和行对齐校准

### 提交 7：主题与字体校准

- rounding / spacing / style 统一
- 内置字体优先
- Reset Layout 全入口回归验证

### 提交 8：辅助增强

- Browser material 资产支持
- Material 拖拽链路
- 其他资产工作流细化

## 12. 验收清单

### 12.1 场景搭建

- Place Actors 面板存在且布局稳定
- 至少支持 Empty / Cube / Point Light 拖到 Viewport 生成
- 生成位置优先来自地平面求交，失败时有合理回退
- 所有生成动作都可撤销

### 12.2 Viewport

- 左上菜单紧凑且图标化
- 吸附开关可工作
- 打开 popup 时不会触发相机控制
- ViewCube 与 overlay 不重叠、不打架

### 12.3 Inspector

- 顶部摘要区常驻
- 双列表单对齐清晰
- Transform 颜色与 Scrubbing 保持，并与新风格一致
- 搜索和右键菜单不回退

### 12.4 Outliner

- Folder 可创建、命名、拖拽
- 多选拖拽只移动根节点
- 图标与文本对齐稳定

### 12.5 Layout / Theme

- 启动后是经典布局
- Reset Layout 生效
- 主题冷灰、边框克制、圆角更收敛
- 字体加载策略清晰且可控


## 14. 最终建议

本轮最容易犯的错误，是继续把问题理解成“把几个按钮换成更像 UE 的样子”。真正决定体验差异的是三件事：

- 是否先把 Place Actors + Viewport 投放这条主工作流打通
- 是否给 Viewport 增加真正可用的 Snapping
- 是否把 Details / Outliner / Layout 组织成稳定的工业编辑工作区

这三件事完成后，再去做 ViewCube 替换、材质资产拖拽、字体和主题收尾，投入产出会更高。
