# Guava Editor UI 修改实施方案

本文用于指导以下四类编辑器 UI 改造的实际落地：

1. Viewport Overlay 图标化与折叠
2. Inspector 空间优化与组件检索
3. Content Browser 面包屑与拖拽工作流增强
4. Docking Layout 默认布局整理

本文不是需求摘要，而是实施文档。重点不是“想要什么”，而是“基于当前代码库，应该如何改，先改什么，哪些地方其实已经存在，哪些地方需要补基础设施”。

## 1. 现状确认

在开始实现前，需要先明确当前项目中已经具备的能力，避免重复设计。

### 1.1 Viewport Overlay 现状

- `src/editor/ui/viewport.zig` 已经有独立的悬浮 Overlay window。
- 当前 Overlay 不是把按钮直接平铺在渲染图像上，而是通过 `beginWindowFlags` 创建无标题、不可停靠、自动尺寸的浮动窗口。
- 当前 Overlay 已包含三组菜单：
  - `View`
  - 当前渲染模式文本菜单
  - `Overlay`
- 当前播放工具条和 ViewCube 也已经是独立悬浮层。
- `state.viewport_overlay_hovered` 已用于阻止视口相机控制穿透。

结论：
- 第一阶段不应被理解为“从无到有做 Overlay”。
- 真正要做的是“在现有 Overlay 基础上图标化、收纳、改成交互更紧凑的专业面板”。

### 1.2 Inspector 现状

- `src/editor/ui/windows/inspector.zig` 已经有组件过滤输入框。
- `state.inspector_filter_buffer` 已存在于 `src/editor/core/state.zig`。
- 组件 Header 的右键上下文菜单已经存在：
  - Transform
  - Mesh
  - Material
  - Camera
  - Light
- 旧版 `drawXComponentToolbar` 函数仍保留在文件中，但当前代码路径已经不再调用它们。

结论：
- 第二阶段不应再实现一套新的搜索和右键逻辑。
- 正确做法是“整理现有结构、提升过滤位置与交互质量、删除未使用遗留函数”。

### 1.3 Content Browser 现状

- `src/editor/assets/browser.zig` 已经有面包屑导航 `drawBreadcrumbs()`。
- `model` 和 `texture` 资产已经支持从浏览器发起拖拽。
- `Viewport` 已经支持接收 `model` 和 `texture` 的拖拽。
- `Scene Hierarchy` 已经支持接收：
  - `model` 拖入根级列表
  - `texture` 拖到实体节点

结论：
- 第三阶段不是“新增所有拖拽能力”，而是“把已有拖拽从局部可用提升为完整资产工作流”。
- 真正缺失的是 `material` 作为资产的一等支持，以及更稳定的 drop 目标语义。

### 1.4 Dock Layout 现状

- `src/engine/ui/imgui_bridge.cpp` 已经使用 DockBuilder API 构建默认布局。
- `resetDefaultLayout()`、`loadAnimationLayout()` 已经在 Zig 层暴露。
- 菜单栏和设置窗口中已经有重置布局入口。
- 当前窗口稳定 ID 已通过 `###panel_id` 形式固定，不会因为语言切换打乱停靠。

结论：
- 第四阶段不需要重新发明 DockBuilder。
- 正确工作是“调整现有默认布局比例与放置策略，并统一 Reset Layout 的入口与行为”。

## 2. 总体实施原则

本次改造建议遵循以下原则。

### 2.1 先补基础能力，再改界面

当前 Zig ImGui bridge 暴露的接口仍然偏少。若直接改 UI，很容易出现一半用旧方式、一半为新交互补临时 hack 的情况。应先补足以下基础接口，再做图标化和 popup 菜单。

### 2.2 优先增量重构，不重写现有可用逻辑

已有功能必须尽量复用：

- 现有 Overlay 的窗口位置与输入屏蔽机制
- 现有 Inspector 过滤和右键菜单
- 现有 Browser 面包屑
- 现有 model/texture 拖拽逻辑
- 现有 DockBuilder 布局函数

### 2.3 把“数据语义”补完整，而不是只改按钮外观

例如：

- 只有把 `material` 纳入 `AssetKind`，材质拖拽才有工程意义。
- 只有给 `Viewport` 增加明确的 pending drop 语义，拖拽到视口才不会依赖脆弱的“当前选中对象”。
- 只有把 `view preset` 作为状态保存，图标化后的菜单才能正确表达当前视图。

### 2.4 所有新增交互都必须兼顾输入穿透问题

当前相机控制依赖 `state.viewport_overlay_hovered` 防止 overlay 上的点击、悬浮影响视口旋转。任何 popup、图标按钮、悬浮面板都必须继续参与这套输入屏蔽逻辑。

## 3. 前置改造

本节是正式进入四个阶段前的统一准备。

## 3.1 ImGui bridge 补强

建议先在 `src/engine/ui/imgui_bridge.h`、`src/engine/ui/imgui_bridge.cpp` 和 `src/engine/ui/imgui.zig` 补以下接口。

### 必补接口

- `openPopup(id)`
- `beginPopup(id)`
- `endPopup()`
- `inputTextWithHint(label, hint, buffer)`

### 建议补接口

- `isPopupOpen(id)`
- `beginChildFlags(id, width, height, border, flags)`
- `beginCombo(label, preview)`
- `endCombo()`

说明：

- 如果只做文字菜单，当前 `beginMenu()` 已够用。
- 但如果要实现“图标按钮作为菜单触发器”，就需要 `openPopup + beginPopup` 或 `beginCombo`。
- `inputTextWithHint` 不是必须，但对于 Inspector 搜索框和 Browser 搜索框会明显提升可用性。
- `beginChildFlags` 不是第一优先级，因为现有 Overlay 更适合继续用 `beginWindowFlags`，但将来会有用。

## 3.2 状态模型整理

建议在 `src/editor/core/state.zig` 做以下补充。

### 3.2.1 新增视图预设状态

新增：

```zig
pub const ViewportViewPreset = enum {
    perspective,
    top,
    side,
    custom,
};
```

在 `EditorState` 中增加：

```zig
viewport_view_preset: ViewportViewPreset = .perspective,
```

用途：

- Overlay 图标菜单需要知道当前处于哪个视图。
- 用户自由旋转相机后，应切换为 `.custom`。
- 点击菜单预设时，再切回对应 preset。

### 3.2.2 扩展资产类型

当前 `AssetKind` 只有：

- `scene`
- `model`
- `texture`
- `shader`

建议新增：

```zig
material,
```

同时新增 payload 常量：

```zig
pub const asset_material_drag_payload = "guava.asset.material";
```

### 3.2.3 重构视口待处理拖拽状态

当前视口待处理状态只有：

- `pending_viewport_drop_asset_index`
- `pending_viewport_drop_kind`

这套结构对简单导入够用，但无法表达复杂目标。建议改成结构体：

```zig
pub const PendingViewportDrop = struct {
    asset_index: usize,
    kind: AssetKind,
    pixel: ?[2]u32 = null,
    target_entity: ?engine.scene.EntityId = null,
    world_position: ?[3]f32 = null,
};
```

在 `EditorState` 中替换原有两个字段。

用途：

- `pixel` 用于命中测试或后续 readback。
- `target_entity` 用于材质或贴图落到实体。
- `world_position` 用于模型落点生成。

说明：

- 如果短期内不做完整命中返回，也建议先把状态结构升级好。
- 否则阶段三很容易继续堆叠“当前选中对象 + 下一帧推断”的脆弱逻辑。

## 3.3 图标资源整理

在 `src/editor/ui/icons.zig` 的 `paths.toolbar` 下，建议新增：

- `camera`
- `material`
- `overlay`

若现有 `assets/ui/icons` 中没有合适资源，建议补充 SVG。

推荐语义：

- `camera` 用于 View Preset 菜单
- `material` 或 `shaded_sphere` 用于 Render Mode 菜单
- `overlay` 或 `eye/sliders` 用于 Grid / Bones / Collision 菜单

说明：

- 不建议继续用 `settings` 图标同时代表“渲染模式”和“通用设置”，语义会变混乱。

## 3.4 国际化文本补充

在 `src/editor/i18n/message_id.zig` 及中英文 locale 中补以下文案。

建议新增：

- `search_components`
- `search_assets`
- `material_asset`
- `apply_material`
- `drop_model_here`
- `drop_material_here`
- `custom_view`

如果实现 tooltip，也建议补：

- `view_presets`
- `render_modes`
- `overlay_options`

## 4. 阶段一：Viewport Overlay 图标化与折叠

## 4.1 实施目标

将当前左上角 Overlay 从文本触发菜单升级为图标触发菜单，同时保持：

- 专业感
- 紧凑性
- 悬浮层输入不穿透
- 当前功能完整保留

## 4.2 建议保留的结构

不建议把当前 Overlay 从 `beginWindowFlags()` 改回纯 `beginChild()`。

推荐保留现有模式：

- 外层仍为 floating window
- 内部如有需要可嵌一个 child 做内容布局

原因：

- 当前 Overlay 已经正确使用 `setNextWindowPos()` 和 `setNextWindowBgAlpha()`
- 当前 hover 检测依赖 `isWindowHovered()`
- Overlay 本质上是独立悬浮层，不是 Viewport 内容流布局的一部分

## 4.3 实施步骤

### 步骤 1：抽出 Overlay 面板样式辅助函数

在 `src/editor/ui/viewport.zig` 中抽出：

- `beginViewportOverlayPanel()`
- `endViewportOverlayPanel()`

统一处理：

- `setNextWindowPos`
- `setNextWindowBgAlpha`
- `WindowFlags`
- `item_spacing`
- `frame_rounding`

目的：

- 让左上控制面板、播放工具条在视觉风格上统一。

### 步骤 2：为视图预设引入图标触发 popup

建议实现：

- 图标按钮点击后 `openPopup("viewport_view_preset_popup")`
- `beginPopup("viewport_view_preset_popup")`
- 内部保留现有 `menuItem()` 逻辑

菜单项：

- Perspective
- Top
- Side

点击后：

- 调用 `camera.setViewPreset()`
- 更新 `state.viewport_view_preset`

### 步骤 3：为渲染模式引入图标触发 popup

菜单项：

- Textured
- Wireframe
- Unlit

点击后：

- 更新 `state.viewport_render_mode`

建议在菜单标题或预览状态中体现当前模式，但不需要回到全文字按钮。

### 步骤 4：保留 Overlay 诊断菜单

当前第三组 `Overlay` 菜单：

- Show Grid
- Show Bones
- Show Collision

建议保留为第三个图标菜单，而不是删除。

原因：

- 这些选项虽然不是高频模式切换，但仍然属于视口临时调试控制，放在左上角是合理的。

### 步骤 5：修正 hover 和 popup 打开态

必须保证：

- 鼠标悬浮在图标按钮上时，`state.viewport_overlay_hovered = true`
- popup 打开期间，也要把 `viewport_overlay_hovered` 维持为 `true`

否则会出现：

- 打开菜单时还能拖动相机
- 点击 popup 项时视口同时接收鼠标事件

推荐方式：

- 只要 overlay window hovered，就设置 `viewport_overlay_hovered = true`
- 只要任一 popup `beginPopup()` 返回 `true`，也设置 `viewport_overlay_hovered = true`

### 步骤 6：自由旋转时重置 view preset

在 `src/editor/interaction/camera.zig` 中，当用户通过 orbit / look 改变相机角度时：

- 若当前不是精确 preset 结果，切换 `state.viewport_view_preset = .custom`

这样 Overlay 才不会错误显示用户仍处于 `Top` 或 `Side` 视角。

## 4.4 推荐代码组织

建议在 `viewport.zig` 中新增以下 helper：

- `drawViewportOverlayMenuButton()`
- `drawViewportViewPresetMenu()`
- `drawViewportRenderModeMenu()`
- `drawViewportDebugOverlayMenu()`

目的：

- 减少 `drawViewportOverlayControlsWindow()` 的体积
- 避免后续继续把逻辑堆在一个函数里

## 4.5 风险点

- 如果不补 popup API，只能继续用文字 `beginMenu()`，无法实现真正图标触发。
- 如果不补 view preset 状态，图标菜单只能“能点”，不能表达当前状态。
- 如果 popup 打开时不拦截视口输入，交互会非常差。

## 5. 阶段二：Inspector 空间优化与组件检索

## 5.1 实施目标

减少 Inspector 在组件变多时的纵向浪费，并让搜索框处于更自然的位置。

## 5.2 结构上的关键调整

当前需求写的是“在 EntityId 和 Name 下方加搜索框”，但当前 `EntityId` 与 `Name` 处于 `Identity` 折叠区内部。这会带来一个实际问题：

- 如果 `Identity` 被收起，搜索框也会消失。

因此推荐做法不是简单插一行输入框，而是重构顶部摘要区。

## 5.3 推荐布局重构

建议把窗口顶部拆成两个区块。

### 固定摘要区

始终显示：

- Selection Count
- Entity ID
- Name
- Component Filter

这个区块不使用 `collapsingHeader`，始终可见。

### 详细折叠区

保留：

- Identity
- Transform
- Components
- Mesh
- Material
- Camera
- Light
- Actions

这样更符合专业编辑器习惯，也满足“搜索框位于 ID 与 Name 之后”的诉求。

## 5.4 实施步骤

### 步骤 1：固定顶部摘要区

在 `drawInspectorWindow()` 顶部重组以下绘制顺序：

1. `selection_count`
2. `entity_id`
3. `name`
4. `component_filter`

说明：

- 当前 `Name` 编辑逻辑已经存在，可以直接迁移。
- `Parent` 和 `Editor Only` 可以继续留在 `Identity` header 中，不必搬到顶部。

### 步骤 2：搜索框使用 hint

若 bridge 已补齐 `inputTextWithHint()`，建议使用：

- label: `##inspector_filter`
- hint: `state.text(.search_components)`

若暂时不补 hint，则使用普通 `inputText()` 也可，但建议在旁边补一行静态标签。

### 步骤 3：统一过滤判定

当前已有：

- `inspectorFilter()`
- `inspectorSectionMatches()`

建议继续复用，不要新写第二套 filter 逻辑。

应确保以下部分都经过过滤：

- Identity
- Transform
- Mesh
- Material
- Camera
- Light
- Actions

如果 `Components` 只是“Add Component”容器，建议它在 filter 非空时始终显示，或者改为只在无 filter 时显示，避免噪音。

### 步骤 4：删除未使用旧 Toolbar 函数

删除以下遗留函数：

- `drawTransformComponentToolbar`
- `drawMeshComponentToolbar`
- `drawMaterialComponentToolbar`
- `drawCameraComponentToolbar`
- `drawLightComponentToolbar`

理由：

- 它们已经不在主绘制路径中使用
- 会持续误导后续维护者
- 与当前 Header Context Menu 方案重复

### 步骤 5：保留现有 Header Context Menu

当前以下函数已可复用：

- `drawTransformHeaderContextMenu`
- `drawMeshHeaderContextMenu`
- `drawMaterialHeaderContextMenu`
- `drawCameraHeaderContextMenu`
- `drawLightHeaderContextMenu`

建议只做微调，不重写：

- menu id 保持稳定
- 复制/粘贴/删除行为继续复用现有 history 逻辑

### 步骤 6：过滤命中时默认展开

当前代码已经使用：

- `collapsingHeader(label, filter.len != 0)`

这个策略是正确的。建议保留。

原因：

- 用户输入关键字时，希望匹配组件自动展开
- 这样无需再次点击 header

## 5.5 可选增强

可在后续补充：

- 搜索框右侧清空按钮
- 组件数量提示
- 仅显示有组件的 section

这些都不是本阶段的硬依赖。

## 5.6 风险点

- 若不把 Name 从 `Identity` 区抽出来，搜索框放到其下方会导致结构变得别扭。
- 若保留旧 toolbar 死代码，后续很容易再出现“双系统并存”。

## 6. 阶段三：Content Browser 极致交互

## 6.1 实施目标

把当前 Browser 从“能浏览、能拖拽部分资产”提升为稳定、清晰、可扩展的资产工作流入口。

## 6.2 建议分成三个子阶段

不要一次性把所有拖拽需求塞进一个提交。建议分为：

1. 面包屑视觉整理
2. 材质资产正式进入 Browser
3. 视口与 Hierarchy 的 drop 语义增强

## 6.3 子阶段 A：面包屑视觉整理

当前 `drawBreadcrumbs()` 已经能工作。这里要做的是风格整理，而不是重写。

### 建议改动

- 将 breadcrumb button 改成透明背景风格
- 分隔符继续使用 `>`
- 当前目录层级可加更明显的 active 样式
- 保持点击任意层跳转

### 不建议重做的部分

- 不需要重写路径分割算法
- 不需要改动 `selectedDirectory()` 和 `setSelectedAssetDirectory()`

## 6.4 子阶段 B：Material 资产正式进入 Browser

这是第三阶段中最关键的基础改造。

### 当前缺口

虽然底层资产系统里已经有 `material` 记录类型，但 Browser 侧会在刷新时跳过它。

当前需要补的部分：

- `AssetKind.material`
- Browser 刷新时映射 `record.type == .material`
- Material 图标
- Material 预览文本
- Material 拖拽 payload

### 实施步骤

#### 步骤 1：扩展 `AssetKind`

修改 `src/editor/core/state.zig`。

#### 步骤 2：刷新资产列表时纳入 material

修改 `src/editor/assets/browser.zig` 的 `refreshAssetBrowser()`：

- `record.type == .material` 时写入 `AssetKind.material`

#### 步骤 3：补 Material 图标与 tint

修改：

- `assetIconPath()`
- `assetIconTint()`

#### 步骤 4：补 Material 预览内容

在 `drawSelectedAssetPreview()` 中增加 `.material` 分支。

首版可以只展示：

- 资源名
- 路径
- “可拖拽到视口或层级中的对象以赋予材质”

不需要第一版就做材质球缩略图。

#### 步骤 5：发出 material 拖拽 payload

在 `drawAssetCard()` 中加入：

- `state_mod.asset_material_drag_payload`

## 6.5 子阶段 C：Viewport 和 Hierarchy drop 语义增强

### 6.5.1 关于 payload 载荷的建议

当前拖拽使用 `u64 asset_index` 作为 payload。

这在最小实现上可以继续使用，但它不是最稳健的设计。

推荐分两档：

#### 最小实现

- 继续使用 `asset_index`
- 改动小
- 适合先把功能打通

#### 推荐实现

- 未来扩展 string payload 或 stable asset id payload
- 避免刷新列表、排序变化后 payload 语义不稳定

本轮若追求交付速度，可先保留 `asset_index`。

### 6.5.2 Viewport 接收 model

当前 Viewport 接收 `model` 后直接调用 `history.importModelPath()`，而后者会把模型生成在“相机前方 3 米”。

这与“拖到哪里生成到哪里”不一致。

建议分两步实现：

#### 第一步：保底实现

- 保持当前导入逻辑
- 先让 Viewport 拖模型在交互上稳定可用

#### 第二步：正确实现

新增“鼠标射线与地平面求交”的工具函数，建议放在：

- `src/editor/interaction/camera.zig`
或
- `src/editor/common/utils.zig`

建议新增 helper：

- `viewportScreenRay(...)`
- `intersectGroundPlane(...)`
- `viewportDropWorldPosition(...)`

最终效果：

- 用户把 model 拖到 Viewport 某位置时，在该世界位置生成实例

### 6.5.3 Viewport 接收 material

材质拖拽与贴图拖拽不同，它不应依赖“当前已选中的实体”作为最终目标。

推荐实现分两档。

#### 最小实现

- 复用当前 texture drop 的模式
- 在鼠标位置触发 selection readback
- 下一帧将 material 赋给命中的选中实体

问题：

- 这会污染当前 selection
- 若 selection 在异步 readback 完成前变化，目标可能漂移

#### 推荐实现

补一个专用的 hit-test / entity readback 接口，避免借用“选择系统”。

理想接口：

- `requestEntityReadback(pixel)`
- 返回命中的 `EntityId`
- 不改当前 selection

如果暂时不改 renderer，也至少应在 `PendingViewportDrop` 中记录更完整的待处理上下文。

### 6.5.4 Hierarchy 根级接收 model

当前根级已支持拖入 model 并导入。这里建议保留。

可补的点：

- 成功导入后自动聚焦新 root
- 支持 undo/redo 一致性验证

### 6.5.5 Hierarchy 节点接收 model 作为子物体

这是当前真正缺失的部分。

推荐方式：

1. 导入模型，得到导入报告中的 root entity
2. 将 root entity reparent 到目标实体
3. 保持世界变换或转成本地变换
4. 记录 history snapshot

这里不建议直接复用“相机前方生成”的入口。

建议抽出新 helper，例如：

- `importModelPathIntoParent(state, layer_context, path, parent_id)`
- 或 `importModelPathAtTransform(...)`

### 6.5.6 Hierarchy 节点接收 material

虽然你的原始计划没有把这项列成必做，但从工作流一致性看，非常值得补。

原因：

- 用户拖材质到实体树节点，比先去视口命中对象更直接
- 这是比 Viewport 材质拖拽更低风险、更容易稳定实现的入口

建议作为第三阶段可选增强。

## 6.6 风险点

- 不先做 `AssetKind.material`，材质拖拽无法形成完整链路。
- 不抽新的导入 helper，Hierarchy 的 model 子物体拖放会继续借用错误的生成语义。
- 不补 hit-test 语义，Viewport 材质拖拽会高度依赖 selection 时序。

## 7. 阶段四：全局工作流与 Docking Layout

## 7.1 实施目标

让编辑器启动即进入合理布局，同时保留现有的顶部工具条停靠位和稳定窗口 ID。

## 7.2 当前布局的实际情况

当前默认布局已经包括：

- Top: `Global Toolbar`
- Center: `Viewport`
- Left: `Scene`
- Right: `Details`
- Bottom: `Content Browser`

所以本阶段不是“新增这套布局”，而是“调优比例与统一重置入口”。

## 7.3 实施步骤

### 步骤 1：保留顶部工具条分区

用户原始草案只描述了左右下和中心，但当前项目还有 `Global Toolbar` 顶部分区。

建议保留 `dock_top`。

原因：

- 现有默认布局已为顶部工具条预留空间
- 若移除顶部 split，工具条窗口将失去稳定停靠位置

### 步骤 2：调整默认布局比例

建议在 `src/engine/ui/imgui_bridge.cpp` 中调整 `build_default_dock_layout()` 的 split ratio：

- left: `0.20f`
- right: `0.25f`
- bottom: `0.30f`
- top: 继续保留，建议 `0.05f` 到 `0.06f`

建议只调 ratio，不改窗口 stable name。

### 步骤 3：统一 Reset Layout 行为

当前以下入口都会影响布局：

- `menu_bar.zig`
- `settings.zig`
- `EditorLayer.onUpdate()` 首次初始化

建议统一规则：

- 首次进入编辑器时自动套用默认布局
- 菜单中的 `Reset Dock Layout` 调用同一套默认布局 builder
- 未来若增加更多预设布局，继续从 bridge 暴露单一入口

### 步骤 4：保持窗口 stable id 不变

以下 stable id 不应改动：

- `global_toolbar_panel`
- `viewport_panel`
- `scene_panel`
- `details_panel`
- `content_browser_panel`

因为 DockBuilder 停靠依赖的是这些窗口名中的 `###stable_id`。

## 7.4 风险点

- 如果随意改 stable window name，用户保存的布局和默认布局都会失效。
- 如果删除 top dock，现有全局工具条的布局将退化。

## 8. 推荐实施顺序

建议按以下顺序提交，而不是按视觉模块拆得过散。

### 提交 1：基础设施

- ImGui bridge 补强
- `AssetKind.material`
- `asset_material_drag_payload`
- `ViewportViewPreset`
- `PendingViewportDrop` 结构升级
- i18n 文案补充
- 图标资源补充

### 提交 2：Viewport Overlay

- 图标触发 popup
- View / Render / Overlay 三组合并为紧凑图标面板
- 保持 hover 屏蔽
- 自由视角切换到 `custom`

### 提交 3：Inspector

- 固定摘要区
- 搜索框位置调整
- 清理旧 toolbar 死代码
- 复核过滤命中与默认展开行为

### 提交 4：Content Browser 基础增强

- breadcrumb 透明风格
- material 资产进入 Browser
- material 预览文案
- material payload 发出

### 提交 5：拖拽工作流

- Hierarchy 节点接收 model 并作为 child 导入
- Hierarchy 节点可选接收 material
- Viewport 接收 material
- Viewport 接收 model 的保底版本

### 提交 6：精确落点与布局收尾

- 视口射线与地平面求交
- model 按鼠标落点生成
- 默认 DockBuilder 比例调整
- Reset Layout 全入口检查

## 9. 验收清单

以下内容应作为这轮修改的验收标准。

## 9.1 Overlay

- 左上 Overlay 不再使用长文本按钮触发主菜单
- View Preset、Render Mode、Overlay Options 均可通过图标打开
- Overlay popup 打开时不会触发视口相机控制
- 自由旋转视角后状态显示为 `Custom`

## 9.2 Inspector

- 搜索框在顶部摘要区，位于 Entity ID / Name 之后
- 搜索关键字可过滤组件 section
- 命中的 section 自动展开
- 旧组件 toolbar 函数已删除
- Header 右键菜单仍可正常复制、粘贴、删除

## 9.3 Content Browser

- breadcrumb 为透明风格按钮，可逐级跳转
- Browser 中可看到 material 资产
- material 可从 Browser 发起拖拽
- model 可拖到 Hierarchy 实体节点并作为其子物体导入
- texture/material 可拖到实体或视口目标并赋值

## 9.4 Dock Layout

- 启动后默认布局为中心 Viewport、左 Scene、右 Details、下 Content Browser、上 Global Toolbar
- `Window -> Layout -> Reset Dock Layout` 可恢复默认布局
- Settings 中的 Reset Layout 行为一致
- 切换语言后停靠关系不丢失

## 10. 手工验证建议

建议至少执行以下验证流程。

### 验证组 A：Overlay

1. 打开编辑器
2. 在 Viewport 左上点击视图图标
3. 切换 Perspective / Top / Side
4. 打开 Render Mode 图标并切换模式
5. 打开 Overlay 图标并切换 grid / bones / collision
6. 在 popup 打开时拖动鼠标，确认不会误触发 orbit

### 验证组 B：Inspector

1. 选择一个包含 Mesh、Material、Light 的实体
2. 在 Inspector 顶部输入 `mat`
3. 确认只显示 Material 或匹配条目
4. 右键 Material Header
5. 执行 Copy / Paste / Remove
6. 验证 history snapshot 可正确撤销

### 验证组 C：Browser 与拖拽

1. 进入多级目录，点击 breadcrumb 上一级
2. 将 model 拖到 Hierarchy 根区域
3. 将 model 拖到某实体节点上
4. 将 texture 拖到实体节点上
5. 将 material 拖到实体节点或视口对象上
6. 验证赋值结果与 undo/redo

### 验证组 D：布局

1. 手动打乱停靠布局
2. 点击 Reset Dock Layout
3. 验证恢复默认
4. 切换语言
5. 再次重启编辑器，确认停靠稳定

## 11. 建议暂不处理的内容

以下内容可以明确排除在本轮之外，避免范围失控。

- 材质球实时缩略图渲染
- Browser 中复杂多列元数据视图
- Overlay tooltip 系统全量设计
- 完整 drag preview 自定义渲染
- 多种预设布局之间的用户可编辑模板系统

这些都可以在当前工作完成后再单独规划。

## 12. 最终建议

本轮修改最容易犯的错误，是把问题误判为“主要是视觉换皮”。实际上，真正影响交付质量的是三件事：

- Zig ImGui bridge 是否先补到可支撑图标 popup 的程度
- `material` 是否进入 Browser 的数据模型
- `Viewport` drop 是否有稳定的目标语义，而不是继续依赖当前 selection 推断

如果这三件事先做对，剩下的界面整理工作会非常顺；如果这三件事不先处理，后续每一处 UI 改动都可能带来新的补丁式逻辑。
