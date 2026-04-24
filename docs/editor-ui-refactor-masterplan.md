# Guava Editor 重构总方案（功能 + UI + 样式）

## 1. 文档目标

本方案用于把当前 Editor 界面重构为目标图中的“完整编辑工作台”形态，覆盖三类输出：

- 功能重构：布局壳层、面板系统、工作流模式、交互命令、状态模型、数据流。
- UI 重构：信息架构、组件结构、可见层级、可用性规则。
- 样式重构：主题 token、颜色规范、字体与间距、交互态、动效节奏。

本方案基于现有实现和现有蓝图，不重写系统底座，不引入与当前仓库冲突的二套框架。

---

## 2. 当前状态评估

### 2.1 已具备能力

1. Dock 内核完整：分割、拖拽、tab 移动、卫星窗、关闭历史、快照持久化。
2. 现有主面板可用：Hierarchy、Viewport、Inspector、Console、Assets、AI Intent、Confirm。
3. 主题系统可用：`Theme`、`ColorScheme`、dark/light 默认主题、Dock 默认风格。
4. EditorState 已有编辑核心字段：选中、多选、gizmo、shading、snap、AI 状态、Inspector 折叠状态。

### 2.2 差距

1. 缺少“编辑器壳层”：菜单栏、主工具栏、状态栏、底部工作台仍未独立。
2. Dock 仍承担全窗口布局，导致全局信息结构不稳定。
3. 工具模式（Level / Modeling / Animation）没有布局预设和面板可见性策略。
4. 样式层虽有 token，但 Editor 端还存在局部调用点差异，组件密度和视觉节奏不统一。
5. 组件缺口仍在：Select/Enum 类、AssetRef 类、菜单/弹层深度能力仍需补齐和统一接入。

---

## 3. 重构总架构

### 3.1 三层架构

1. Frame Shell（固定壳层）
- 顶部：MenuBar
- 顶部第二行：MainToolbar
- 中部：Workspace Body（Dock）
- 底部第一行：Bottom Workbench（Console/Assets/Intent 等）
- 底部第二行：StatusBar

2. Workspace Runtime（工作区运行层）
- 对应不同工作模式加载不同 Dock 快照模板。
- 管理面板显示集合、默认激活 tab、区域落位约束。

3. Panel Runtime（面板运行层）
- 统一注册、延迟构建、生命周期、状态订阅。
- 统一动作派发，不允许面板互相直接写状态。

### 3.2 关键原则

1. Dock 是中部工作区内核，不是整窗口布局系统。
2. 壳层优先稳定，工作区可配置。
3. 状态单向流：View -> Action -> Reducer -> State -> View。
4. 主题 token 单一来源：组件只读取语义 token，不写裸色。

---

## 4. 功能重构设计

### 4.1 编辑器壳层（新增）

#### 4.1.1 MenuBar

功能：
- File / Edit / Window / Tools / Build / Help。
- 命令绑定：新建、打开、保存、导入、布局重置、主题切换。
- 支持快捷键显示与冲突检测。

实现建议：
- 新建 `Editor/Sources/EditorApp/Shell/EditorShellView.swift`。
- 新建 `Editor/Sources/EditorApp/Shell/MenuBarView.swift`。
- 菜单项由配置驱动，避免硬编码文本。

#### 4.1.2 MainToolbar

功能：
- Play / Pause / Stop。
- 平台切换。
- 工作模式切换（Level / Modeling / Animation）。
- 全局搜索入口。

实现建议：
- 新建 `Editor/Sources/EditorApp/Shell/MainToolbarView.swift`。
- 模式切换 dispatch `EditorAction.setWorkspaceMode(...)`（新增 action）。

#### 4.1.3 StatusBar

功能：
- 连接状态、场景实体数量、性能摘要、后台任务状态。
- 快速入口：日志、问题、资源导入队列。

实现建议：
- 新建 `Editor/Sources/EditorApp/Shell/StatusBarView.swift`。
- 从 StoreScope 读取 `connected`、`sceneRevision`、stats 聚合。

### 4.2 Workspace（中部工作区）

#### 4.2.1 布局模板

新增布局模板枚举：
- `defaultLevelLayout`
- `modelingLayout`
- `animationLayout`

每个模板为 `DockLayoutSnapshot`，包含：
- 根布局树
- 默认 active tab
- 允许落位策略

#### 4.2.2 面板可见性策略

每个面板新增元数据：
- `workspaceVisibility: Set<WorkspaceMode>`
- `defaultPinned: Bool`
- `defaultTabOrder: Int`

### 4.3 面板功能增强

#### 4.3.1 Hierarchy

目标：
- 搜索过滤
- 可见/锁定列
- 多选批量操作
- 拖拽层级重排（SceneAdapter 提供事务入口）

必要 API：
- `setHierarchyFilter(String)`
- `toggleEntityVisibility(UInt64)`
- `toggleEntityLocked(UInt64)`
- `reparentEntity(child: UInt64, parent: UInt64?)`

#### 4.3.2 Viewport

目标：
- 工具栏逻辑拆分：壳层按钮与视口内按钮职责明确。
- 统一输入路由：摄像机、gizmo、框选、资产投放。
- 覆盖层配置化：网格、坐标轴、选框、gizmo 显示规则。

补充能力：
- `ViewportOverlayConfig`（新增）
- `ViewportInputProfile`（新增）

#### 4.3.3 Inspector

目标：
- 统一分组：General / Transform / Rendering / Physics / Script。
- section 折叠状态持久化（已存在）继续沿用。
- 数值编辑统一用 `NumberField` 约束边界与 step。
- 增加枚举、资源引用、颜色、脚本参数编辑。

新增字段类型建议：
- `.assetRef(...)`
- `.enumOptions(...)`
- `.jsonText(...)`

#### 4.3.4 Bottom Workbench

目标：
- Console、Assets、AI Intent、Confirm 统一到底部工作台。
- 支持拆分子区：左侧日志类、右侧资产/AI 类。
- tab pin 与最近打开队列。

### 4.4 命令系统与快捷键

新增命令域：
- `EditorCommand.workspace.switchMode`
- `EditorCommand.layout.reset`
- `EditorCommand.panel.toggle(id:)`
- `EditorCommand.theme.toggle`

快捷键优先级：
1. 文本输入焦点上下文
2. 面板上下文
3. 全局命令

---

## 5. 状态模型重构

### 5.1 EditorState 扩展

新增字段：

```swift
public enum WorkspaceMode: String, Codable, Sendable {
    case level
    case modeling
    case animation
}

public struct EditorPanelVisibilityState: Codable, Sendable {
    public var openPanelIDs: Set<String>
    public var pinnedPanelIDs: Set<String>
    public var lastActivePanelID: String?
}

public struct EditorThemeState: Codable, Sendable {
    public var appearance: String // dark/light/system
    public var density: String    // compact/comfortable
}
```

建议并入 `EditorState`：
- `workspaceMode: WorkspaceMode`
- `panelVisibility: EditorPanelVisibilityState`
- `themeState: EditorThemeState`
- `activeLayoutPresetID: String`

### 5.2 Action 扩展

新增 action：
- `setWorkspaceMode(WorkspaceMode)`
- `setPanelOpen(panelID:isOpen:)`
- `setPanelPinned(panelID:isPinned:)`
- `setThemeAppearance(String)`
- `setThemeDensity(String)`
- `setActiveLayoutPreset(String)`

### 5.3 持久化策略

持久化对象拆分：
1. Dock 布局快照（已有）
2. 壳层配置（theme、mode、panel visibility）
3. 面板局部设置（如 Hierarchy filter）

文件建议：
- `editor_dock_layout.json`
- `editor_shell_state.json`
- `editor_panel_prefs.json`

---

## 6. UI 与样式规范

## 6.1 主题策略

采用 GuavaUI 已定义的 `ColorScheme` slot 体系，不新增并行色板。

### 6.1.1 深色主题（默认）

直接沿用 `DefaultDarkTheme`：
- `background` #13151A
- `surface` #1B1E24
- `surfaceVariant` #23272F
- `surfaceSunken` #16181E
- `surfaceRaised` #2A2F38
- `surfaceFloating` #313742
- `surfaceOverlay` #39404C

- `onSurface` #E7EBF2
- `onSurfaceVariant` #BEC6D3
- `onSurfaceMuted` #8791A0

- `accent` #4A8CF7
- `accentHover` #6BA5FF
- `accentPressed` #3677E6
- `accentMuted` alpha-based tint

### 6.1.2 亮色主题

直接沿用 `DefaultLightTheme`：
- `background` #FAFAFA
- `surface` #FFFFFF
- `surfaceVariant` #F4F4F5
- `surfaceSunken` #E4E4E7

- `onSurface` #18181B
- `onSurfaceVariant` #52525B
- `onSurfaceMuted` #A1A1AA

- `accent` #4F46E5
- `accentHover` #6366F1
- `accentPressed` #4338CA

### 6.1.3 颜色使用规则

1. 面板容器用 `surface`，不要直接用 `background`。
2. 输入/凹槽区域用 `surfaceSunken`。
3. 弹层和菜单用 `surfaceFloating`。
4. 选中高亮用 `selection` 或 `stateLayerSelected`，不直接铺实色 `accent`。
5. focus 边框只用 `focusRing`。

## 6.2 字体与密度

沿用 `Typography` token：
- 顶栏菜单：`label`
- 面板标题：`headline`
- 正文/属性：`body`
- 辅助信息：`caption`
- ID/路径/日志：`mono`

密度规范：
- 紧凑密度：行高 26-28（Inspector/Tree）
- 标准密度：行高 30-32

## 6.3 间距与圆角

沿用 token：
- 内间距：`sm/md/lg`
- 面板头：`md`
- tab 胶囊：`sm` 或 `md`
- Inspector 单元：`sm`

圆角：
- 主体面板：`md`
- 输入框：`sm`
- 浮层：`md` 或 `lg`

## 6.4 阴影与层级

- 常规 dock 区域：无阴影或 low
- 弹层菜单：medium
- 拖拽浮窗：high

## 6.5 动效

- hover/focus：`motion.fast`
- tab 切换、面板显示：`motion.standard`
- 布局切换：`motion.slow`

动效仅改变透明度与颜色，不做大位移动画，避免工具 UI 晕动。

---

## 7. 组件级 UI 规范

### 7.1 MenuBar

- 高度：28
- 背景：`surface`
- 下边线：`border`
- 菜单项 hover：`stateLayerHover`

### 7.2 MainToolbar

- 高度：40-44
- 背景：`surfaceVariant`
- 分组间距：`md`
- 主按钮：Primary 样式
- 次要按钮：Ghost/Secondary 样式

### 7.3 Dock Tab Bar

按现有 `DefaultDockStyle`：
- tabBarHeight: 32
- active accent bar: 1
- split divider: 1

扩展建议：
- tab 溢出时提供横向滚动与下拉列表
- pinned tab 在最前

### 7.4 Hierarchy Tree

- 行高：28
- 缩进：16
- 选中背景：`stateLayerSelected` 叠加
- 行 hover：`stateLayerHover`
- 图标色：未选 `onSurfaceVariant`，选中 `onSurface`

### 7.5 Inspector Property Grid

- label 宽：100-120
- row 高：26
- section 头高度：28-30
- section 背景：`surfaceVariant`
- 输入框背景：`surfaceSunken`

### 7.6 Viewport Overlay

- 顶部信息条：半透明 `surfaceOverlay`（alpha 0.72 左右）
- 文本：`caption/body`
- gizmo 颜色：XYZ 轴固定色，不进入主题切换

### 7.7 Bottom Workbench

- 高度默认占比：22%-28%
- 背景：`surface`
- tab 栏：`surfaceSunken`
- 空态文案：`onSurfaceMuted`

### 7.8 状态栏

- 高度：24
- 背景：`surfaceVariant`
- 边框：`border`
- 状态点：
  - 在线 `success`
  - 警告 `warning`
  - 错误 `error`

---

## 8. 功能-组件映射表

| 功能 | Shell | Workspace | Panel | State |
|---|---|---|---|---|
| 工作模式切换 | MainToolbar | 加载布局模板 | 控制可见性 | `workspaceMode` |
| 面板开关 | Menu/Window | Dock 插入/关闭 tab | registry 查询 | `panelVisibility` |
| 布局保存恢复 | - | DockSnapshot | - | persisted json |
| 主题切换 | Menu/View | 全树 `.theme(...)` | 自动继承 | `themeState` |
| 多选与编辑 | - | Viewport 输入 | Hierarchy/Inspector 同步 | `selectedEntityIDs` |
| 资产拖放 | - | Viewport DropTarget | Assets DragSource | `activeAssetDrag` |

---

## 9. 分阶段实施计划

## Phase A：壳层接管（1-2 周）

目标：
- `EditorRootView` 改为 `EditorShellView` + `WorkspaceHostView`。
- 保留现有面板功能，不改变业务逻辑。

修改文件：
- `Editor/Sources/EditorApp/RootView.swift`
- 新增 `Editor/Sources/EditorApp/Shell/*`

验收：
- 菜单栏/工具栏/状态栏可见。
- 现有面板行为不退化。

## Phase B：模式与布局模板（1 周）

目标：
- 新增 `WorkspaceMode`。
- 模式切换加载不同 `DockLayoutSnapshot`。

修改文件：
- `Editor/Sources/EditorCore/State/EditorState.swift`
- `Editor/Sources/EditorCore/State/EditorReducer.swift`
- `Editor/Sources/EditorApp/RootView.swift`

验收：
- 切换模式后面板组合变化符合预期。
- 切回模式可恢复上次布局。

## Phase C：面板细化与组件补齐（2-3 周）

目标：
- Hierarchy/Inspector/Assets 功能增强。
- 补齐 Select/Menu/AssetRef/ColorField 关键路径。

修改文件：
- `Editor/Sources/EditorApp/Panels/*`
- `GuavaUI/Sources/GuavaUICompose/Primitives/*`

验收：
- Inspector 可完成光照、材质、资源引用完整编辑流程。
- 资产拖放路径稳定。

## Phase D：样式统一与细节修正（1 周）

目标：
- 清理裸色值与魔法像素。
- 对齐 dark/light 主题表现。

修改文件：
- `GuavaUI/Sources/GuavaUICompose/Theme/*`
- `Editor/Sources/EditorApp/Panels/*`

验收：
- 全局颜色来源可追溯到 token。
- 关键组件在两套主题下对比度达标。

---

## 10. 测试与验收

### 10.1 功能测试

1. 布局保存/恢复：重启后恢复正确。
2. 模式切换：panel 可见性与布局模板正确。
3. 选中同步：Hierarchy/Viewport/Inspector 三方一致。
4. 资产拖放：拖放到视口后实体创建正确。
5. 右键菜单和快捷键：无冲突，焦点上下文正确。

### 10.2 UI 测试

1. 色彩一致性：同语义状态颜色一致。
2. 文本层级：标题/正文/辅助信息可读性稳定。
3. 密度一致：面板行高、内边距统一。
4. 交互态：hover/pressed/focus 呈现连续。

### 10.3 回归测试

1. Dock 拖拽与分割不退化。
2. 卫星窗与重停靠不退化。
3. Inspector 折叠状态持久化不退化。
4. Viewport 首帧渲染路径不退化。

---

## 11. 性能预算

1. 空闲帧 UI CPU：<= 1.5ms
2. 带交互帧 UI CPU：<= 3.0ms
3. Dock 拖拽过程不出现明显跳帧。
4. 布局切换 95 分位耗时 <= 120ms。

监控项：
- recompose 次数
- layout 脏树大小
- draw list 命令数量

---

## 12. 风险与约束

1. Dock 与 Shell 同时改动，存在一次性改动面较大风险。
- 控制方式：先壳层接管，再切模式模板，避免同一迭代混合高风险改动。

2. 组件补齐会触发 Inspector API 变更。
- 控制方式：先扩展 `EditorInspectorFieldValue`，保持已有 case 兼容。

3. 主题统一容易引入视觉回归。
- 控制方式：关键页面截图基线对比（dark/light 各一套）。

---

## 13. 交付清单

1. 架构层交付
- `EditorShellView`、`WorkspaceHostView`、`BottomWorkbenchView`、`StatusBarView`

2. 状态层交付
- `WorkspaceMode`、`panelVisibility`、`themeState`

3. 组件层交付
- `Select`、`Menu/Popover`、`AssetRefField`、`ColorField`（Editor 所需最小闭环）

4. 设计层交付
- token 映射文档更新
- dark/light 截图基线

5. 验收资产
- 功能测试用例
- UI 对比截图
- 性能采样记录

---

## 14. 实施优先级

P0（必须先做）：
1. Shell 分层
2. WorkspaceMode + 布局模板
3. Inspector 关键编辑链路完整

P1（紧随其后）：
1. Bottom Workbench 双区化
2. Menu/快捷键映射完善
3. 主题统一清理

P2（可并行推进）：
1. 高级面板（Material/Modeling/Animation）
2. 更细颗粒动效
3. 更完整资产管理面板

---

## 15. 代码落地起点建议

首批改动入口：
1. `Editor/Sources/EditorApp/RootView.swift`
2. `Editor/Sources/EditorCore/State/EditorState.swift`
3. `Editor/Sources/EditorCore/State/EditorReducer.swift`
4. `Editor/Sources/EditorApp/Panels/InspectorPanel.swift`
5. `GuavaUI/Sources/GuavaUICompose/Theme/DefaultDockStyle.swift`

首批目标：
- 一次提交完成壳层分层与状态字段扩展。
- 不在同一提交中引入大规模组件新增，避免问题定位成本上升。
