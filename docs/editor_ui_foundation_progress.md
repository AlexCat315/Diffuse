# 编辑器 UI 基础设施进度

日期：2026-03-17

本文同步 `docs/editor_ui_implementation_plan.md` 的真实落地状态，只记录当前分支已经实现并验证过的内容。

## 新增：VFX 运行时支持

- `engine.scene.Entity` 现在包含显式 `vfx` 组件，不再只是 Place Actors 里空分类占位。
- 当前提供两套内置 VFX 预设：
  - `喷泉 / Fountain`
  - `环绕 / Orbit`
- `Place Actors`、Scene Hierarchy 右键创建、Viewport 拖放和 Inspector `Add Component` 都已经接到真实生成入口。
- VFX 根实体会保留一个可选中的可视锚点球体；运行时粒子则作为 `editor_only` 子实体动态生成。
- 运行时行为按 playback controller 真正受控：
  - `Playing` 时连续模拟
  - `Step` 时推进一帧
  - `Paused` 时冻结当前粒子状态
  - `Stopped` 时清空运行时粒子，不把临时粒子留在 world 里
- Inspector 已新增 `VFX` section，可编辑：
  - 类型
  - 循环
  - 发射率
  - 粒子寿命
  - 速度
  - 最大粒子数
  - 半径 / 扩散 / 尺寸 / 颜色
- VFX 运行时粒子不会污染编辑工作流：
  - hierarchy 里仍然隐藏
  - scene 序列化会跳过
  - CPU scene surface raycast 会跳过
  - ID pass 也会跳过，不会把临时粒子选中成主对象
- 当前真实边界：
  - 运行时粒子仍复用现有 mesh/base pass，不是单独的 GPU 粒子管线
  - 当前是两套内置 emitter preset，不是通用 Niagara/节点式 VFX 编辑器

## 新增：多套用户自定义布局模板

- 布局系统现在不再只有“保存当前布局 + 两套内置布局”。
- ImGui bridge 已新增任意路径的布局保存/加载接口，用户模板会真正写入磁盘，而不是只留在当前会话内存里。
- 当前模板目录位于编辑器偏好目录下的 `layouts/` 子目录，模板文件按 `*.ini` 持久化。
- `Window > Layout` 菜单现在会列出用户保存的模板，可直接快速加载。
- `Settings` 窗口现在提供完整模板管理：
  - 输入模板名
  - 将当前布局保存为模板
  - 加载已保存模板
  - 删除已保存模板
- 加载用户模板后，当前激活布局会同步回主 `imgui.ini`，因此重启编辑器后仍会保留最后一次加载结果。
- 当前真实边界：
  - 目前没有“模板重命名”独立操作，重命名方式是用新名字另存后删除旧模板
  - 当前模板只管理 dock/layout ini，不额外携带主题、语言或其他编辑器设置

## 新增：完整场景表面 Raycast

- `engine.scene` 现在提供真实的 CPU 场景表面射线检测，而不是只和固定地平面求交。
- Raycast 会遍历当前 world 中可见、非 `editor_only` 的 mesh 实体，并返回最近命中的：
  - entity id
  - hit distance
  - hit position
  - hit normal
- Viewport 投放链路现在先走真实场景表面命中，再回退到 `y = 0` 地平面；这意味着模型、基础体和灯光都可以直接吸附到已有表面，而不是永远落到地板。
- 视口像素到射线的构造也已改成读取当前活动相机的真实投影：
  - perspective 相机按 FOV 投射
  - orthographic 相机按视锥尺寸投射

## 新增：Browser 多视图模式

- 新增 `BrowserViewMode` 枚举（grid / list）
- 工具栏新增 Grid / List 切换按钮
- Grid 视图：原有卡片式布局
- List 视图：图标 + 名称的紧凑行布局
- 支持拖拽、选中

## 新增：材质球预览

- 选中材质资源时显示详细信息面板
- 显示 Shading 模型（Unlit/Lambert/PBR）
- 显示 Base Color RGB 值
- 显示 Texture 状态（Assigned/None）
- 显示 Apply 按钮（当选中实体时）
- Browser 的 material 卡片、list icon 和详情预览现在都接入了真实缩略图，不再只显示静态占位 icon。
- `EditorState.material_thumbnail_queue` 现在会在 UI 帧内收集当前可见/被选中的 material 资产，再在 `EditorLayer.onUpdate()` 末尾统一 flush 到 renderer。

### 完整离屏渲染链路（已实现）

1. **独立 128x128 thumbnail render target**
   - renderer 为每个缓存条目创建独立 `128x128` color/depth 纹理
   - color target 采用 `color_target | sampler`，可直接被 ImGui 采样显示

2. **专用 preview scene / camera / light**
   - renderer 内部维护独立 preview world
   - 预置球体 mesh、固定相机和专用灯光 rig
   - 当前光照 rig 为 `1 directional + 1 point fill`；这是当前 base pass 光照模型真实支持的上限，不伪装成 3-light shader

3. **缩略图缓存与失效策略**
   - renderer 维护内存缓存，key 为 material asset id
   - 失效判断基于材质签名：
     - shading
     - base color
     - base color texture handle / width / height / format
   - 同一 asset 只会排队一次
   - 缓存上限为固定条目数，并按最近请求时间做 LRU 淘汰
   - 场景重置时会清空缓存，避免旧 world 的材质缩略图串场

4. **渲染调度**
   - 每帧最多处理 `2` 个待渲染 material thumbnail job
   - 缩略图渲染发生在主场景 pass 之后、UI pass 之前
   - 首次请求时本帧仍可能先看到 fallback icon，下一帧开始显示真实缩略图；这是当前调度模型下的真实表现

5. **当前边界**
   - 只有“已经载入当前 world，并且能通过 `materialHandleByAssetId()` 解析到句柄”的材质资源可以生成缩略图
   - 未载入当前 world 的材质仍会回退到静态 material icon，不伪装成已实现通用 importer

## 已完成：提交 2 Place Actors + 新默认布局

- 新增 `src/editor/ui/windows/place_actors.zig` 面板，包含分类、搜索、拖拽和点击生成入口。
- `Place Actors` 行项目已经改成整行卡片式条目：
  - 顶部分类按钮的选中态样式已生效
  - 每个条目会显示图标、标题和弱化说明文字
  - 点击和拖拽都落在统一的整行热区上，不再是“左边按钮 + 右边漂浮文字”的拼接布局
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
- Viewport 已接收 `place_actor_drag_payload`，并优先使用完整场景表面 Raycast 决定投放位置。
- 场景表面未命中时，会回退到 `y = 0` 地平面；地平面也失败时，最终回退到默认 `spawnTransform()`。
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

## 已完成：提交 8 辅助增强

- Browser 中 `material` 现在已经是可交互的一等资产：
  - 资产卡会发起 `asset_material_drag_payload`
  - 预览区在“当前 world 已加载该材质”时会显示 `Apply Material` 按钮
- Material 拖拽链路已打通到两条真实目标：
  - 拖到 Scene Hierarchy 实体节点会把该材质应用到目标实体
  - 拖到 Viewport 会先做目标实体 readback，再把材质应用到命中的对象
- Browser / Viewport / Hierarchy 现在共用同一条材质应用 helper：
  - 会同步 `handle`
  - 会把 `shading` 和 `base_color_factor` 回写到实体组件
  - 会接入 undo/redo 快照
- Browser 面包屑已做视觉收口：
  - 当前路径会高亮
  - 面包屑按钮 roundings / padding 已与当前 toolbar 风格统一
- 当前真实限制也已经显式暴露：
  - 只有“已经载入当前 world 并且能通过 `materialHandleByAssetId()` 解析到句柄”的材质资源可以直接应用
  - 对于只存在于 project registry、但尚未载入当前 world 的材质，预览区会明确提示“当前 world 里还没有加载这个材质资源”
  - 这次没有伪装成“任意 material 资源都能直接拖上去生效”

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

`docs/editor_ui_implementation_plan.md` 中提交 2 到提交 8 的开发项已经在当前分支全部落地。

`完整场景表面 Raycast`、`VFX 运行时支持`、`多套用户自定义布局模板` 这三项现在都已经在当前分支落地并通过构建验证。

如果继续推进，建议优先补一轮 headed UI 人工验收，重点确认：

- VFX 在 `Play / Pause / Step / Stop` 四种状态下的视觉行为
- 用户布局模板在菜单加载、设置页删除、重启后持久化这三条路径上的实际手感
