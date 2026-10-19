# Sidebar

`Sidebar` 是受控的分组导航。每项原生支持图标、文字、徽标与禁用状态；头部、滚动目的地列表、底部各自拥有布局边界。应用提供有界的侧边栏尺寸，组件负责内部滚动。

```swift
@State var destination: String? = "downloads"

Sidebar(selection: $destination, sections: [
    SidebarSection("workspace", title: "Workspace", items: [
        SidebarItem("downloads", "Downloads") {
            $0.icon = UIIcons.Action.download
            $0.badge = "8"
        },
        SidebarItem("recent", "Recent activity"),
        SidebarItem("settings", "Settings") {
            $0.icon = UIIcons.Action.settings
        },
        SidebarItem("team", "Team permissions") {
            $0.icon = UIIcons.Status.lock
            $0.isEnabled = false
        }
    ])
], header: {
    Text("My workspace").font(.bodyStrong).padding(16)
    Divider()
}, footer: {
    Divider()
    Text("All changes saved").font(.caption).padding(14)
}).frame(width: 280, height: 440)
```

同一分组按最大图标尺寸保留一个前导槽位；没有图标的项保留该槽位，使标题对齐。纯文字分组不保留空图标槽。默认使用 `icon.medium`，长标题换行，紧凑的计数徽标独立占位；行高以 38 逻辑像素为下限，随实际内容增长。选中使用中性的 `surfaceVariant` source-list 胶囊，hover/press 只叠加中性 state layer；不再把 accent 蓝叠成淡紫，图标继承该行的前景色。键盘焦点和禁用状态仍使用各自的主题 token。每一行的命中区和 hover/selection 背景都占满栏宽，不随标题长度收缩；短标题与长标题的胶囊宽度一致。

图标使用 `BundleImageResource`，通过 `IconTheme` 替换资源和设置推荐尺寸。可按项设置开放的语义槽位，也可定义任意尺寸：

```swift
SidebarItem("project", "Project") {
    $0.icon = AppIcons.project
    $0.iconSize = .large
}
SidebarItem("custom", "Custom destination") {
    $0.icon = AppIcons.custom
    $0.iconSize = SemanticIconSize { theme in theme.icons.medium + 3 }
}
```

数值均为逻辑像素，DPI 由渲染器处理。默认图标跟随 `TextScaler`；`.textScaler(.init(2))` 同时放大文字、徽标和图标，行高重新测量。`.iconScaling(.fixed)` 可固定整个局部侧边栏的图标，`.iconScaling(.factor(1.5))` 可单独覆盖图标缩放，文字策略不受影响。

Tab 进入目的地分组一次。上/下键选择并聚焦上一项/下一项，Home/End 到首项/末项，越界循环；禁用项被跳过。横向箭头和带修饰键的组合不触发该导航。键盘移动会通过真实 `ScrollView` 显露目标，遵守滚动边界并同步已有滚动绑定。初始选择与应用主动改变的选择会在本侧边栏中显露一次，后续用户滚动不被持续拉回。Enter/Space 与点击一样触发该目的地选择。焦点环只响应键盘焦点。

辅助功能中每项保留完整标题、选中状态、启用状态，徽标作为 value 暴露；装饰图标与徽标不重复朗读。语义通过 provider 保留，悬停或焦点引起的子树重组不会丢失名称。项目 ID 在整个侧边栏内唯一，分组 ID 也必须唯一。

`minimumRowHeight` 默认 38pt，可按呈现形态提高下限；触摸仍至少 44pt。`onActivate` 仅在点击或 Enter/Space 激活目的地后调用，方向键浏览只更新 selection，不触发该回调。[NavigationDrawer](navigation-drawer.md) 复用同一 Sidebar 数据、至少 44pt 行高和共享选择，并用激活回调关闭覆盖层。Gallery Sidebar 页提供 “Open as drawer” 入口。

目的地可以递归嵌套。非空 `children` 让该行成为可展开分组：点击分组只展开/收起，不改变 selection；只有叶子目的地会写入 selection 并触发 `onActivate`。`expanded` 是可选 `Binding<Set<ID>>`，省略时组件持有本地会话。选中某个深层目的地时，组件只展开其祖先路径一次；外部折叠后选中页和节点保留，焦点交给最近的可用祖先。

```swift
Sidebar(selection: $selection, sections: [
    SidebarSection("workspace", items: [
        SidebarItem("projects", "Project spaces") {
            $0.icon = UIIcons.File.folder
            $0.children = [
                SidebarItem("welcome", "Getting started"),
                SidebarItem("team", "Design team") {
                    $0.children = [SidebarItem("audit", "Audit log"),
                                   SidebarItem("billing", "Billing") { $0.isEnabled = false }]
                }
            ]
        }
    ])
], expanded: $expanded).frame(width: 280, height: 360)
```

- 行缩进按祖先数量每级 16pt，最多 5 级；分支左侧保留 16pt disclosure 槽，叶子保留同宽槽位，标题不跳动。
- 分支展开状态通过 `accessibility.state.isExpanded` 与辅助功能 activate 暴露；分组只切换展开，不冒充目的地。只有精确选中的叶子绘制 selection 高亮，包含选中项的祖先只保持展开，避免多行同时显示为选中。
- 键盘 Right（RTL 为 Left）在折叠时展开，已展开时进入首个可用子项；Left（RTL 为 Right）在展开时收起，否则回到父项。Up/Down/Home/End 只遍历当前可见且启用的项。Enter/Space 对分组切换展开，对叶子选择并触发 `onActivate`。
- 数据删除、祖先禁用或整体禁用时，不可见/禁用节点不进入 Tab 链；焦点回退到最近可用祖先或首个可用目的地，selection 不被改写。`AnimatedVisibility(.identity, retainsContent:)` 保留折叠子树的节点与局部状态。

### 项级操作

`SidebarItem.contextMenu` 接收标准 `[MenuEntry]`。普通栏中同时提供两种入口：

- macOS 右键/Control-click 整行打开菜单；
- 行尾低调的 “….” 触发器（仅 expanded 呈现）打开同一菜单，鼠标、触摸和键盘均可到达；辅助功能名称为 `Actions for <title>`。
- Rail 仅在右键时打开；rail 的窄宽不叠加行尾按钮。
- 菜单使用不透明浮层，避免侧栏下方文字透出；执行或 Escape 关闭，disabled 项不可执行。

```swift
SidebarItem("audit", "Audit log") {
    $0.contextMenu = [
        .item(MenuItem(id: "archive", title: "Archive") { archive() }),
        .item(MenuItem(id: "duplicate", title: "Duplicate") { duplicate() })
    ]
}
```

`presentation` 默认 `.expanded`，也可使用 `.rail(showsLabels: true/false)` 收为 72/56pt 导航轨，同一组目的地按钮、选择、焦点及头尾槽位状态保留；标签和徽标在图标模式下保留完整 tooltip 与辅助功能信息。呈现与内容几何变化后会显露选中项，普通滚动不被持续拉回。独立 Rail API 与边界见 [NavigationRail](navigation-rail.md)。

## 自适应壳层

`AdaptiveSidebar` 按**容器实际宽度**呈现同一份导航与页面。宿主提供有界宽高，安全区由宿主处理。

```swift
@State var selection: String? = "overview"
@State var navigationOpen = false
@State var navigationWidth: Float = 240

AdaptiveSidebar("Workspace", isPresented: $navigationOpen, selection: $selection, width: $navigationWidth,
    sections: [SidebarSection("workspace", items: [
        SidebarItem("overview", "Overview") { $0.icon = UIIcons.Layout.dashboard },
        SidebarItem("files", "Files") { $0.icon = UIIcons.File.folder }
    ])], configure: { $0.allowsEdgeSwipe = true }) {
        DocumentEditor()
    }
```

| 容器宽度 | 默认呈现 | 导航宽度与入口 |
| --- | --- | --- |
| < 600pt | 抽屉关闭，内容占满 | 内容上方 44pt 打开按钮；抽屉宽 `min(320, 容器宽 − 56)` |
| 600…<1000pt | 常驻 Rail | 72pt，可配置为无标签的 56pt；顶部按钮打开完整导航覆盖层 |
| ≥ 1000pt | 常驻 Sidebar | 240pt，内容占剩余空间 |

`options.layout` 独立持有 `compactMaximumWidth`、`expandedMinimumWidth`、`sidebarWidth` 与 `showsRailLabels`；阈值按非负、递增范围校验，非有限数恢复默认值。`options.drawer` 复用 `NavigationDrawerOptions` 的关闭策略；`openLabel` 和 `drawer.closeLabel` 可本地化。省略 `isPresented` 时组件持有本地会话；传入 binding 时临时变宽不覆盖它，再次变窄会恢复此前展开状态。

导航按钮、头尾槽位与页面始终位于同一树位置，保留本地状态及滚动。关闭后的导航不占紧凑布局、不绘制、不接收输入，也不暴露可见语义。槽位默认原样保留；需要随宽度改变品牌/搜索布局时，可在槽位内使用 `ViewThatFits`。Gallery 采用 56pt 图标轨，用它隐藏搜索并保留搜索词。

抽屉暴露带完整名称的 dialog，并约束焦点和后台输入。关闭开始时禁用抽屉输入并还原触发器焦点；变宽解除模态约束并保留导航焦点，导航因变窄而隐藏时交给打开按钮，再变宽交给选中目的地。紧凑抽屉支持可反转的边缘动画；Rail 与完整导航覆盖层之间直接重排，遮罩淡变。展开与收起共用侧栏图标，紧凑模式的两个操作位于相同的前导位置；收起按钮暴露 expanded 状态并使用本地化名称，不再显示 X。指针/触摸打开后自动焦点保持安静，不自动弹出提示；键盘打开和后续 Tab 保留焦点反馈。两种覆盖形态均使用中性主题 `overlay` 遮罩，支持 Escape、点击遮罩、选择后关闭和左滑关闭；通过 `drawer` 独立配置关闭策略，减少动画立即完成。Rail 和抽屉目标至少 44pt，普通常驻栏的指针密度保持 38pt 下限，触摸仍至少 44pt。

`allowsEdgeSwipe` 默认关闭；启用后仅在支持触摸的紧凑容器中观察前导 24pt 内开始的右滑，水平意图成立才取消子按钮按下。普通点击、前导区外的手势、纵向滚动和文本选择保留原有输入路径。独立 `NavigationDrawer` 的唤出仍由应用提供按钮。

验收：`AdaptiveSidebarTests` 覆盖 390/720/1280pt、100%/200% 字号、三类输入、明暗主题、状态/滚动/节点保留、焦点交接、关闭策略、边缘/左滑、动画反转与卸载，并通过真实 AI `query_ui_nodes` 检查可见性、模态输入权限及关闭后隐藏。`RetainedVisibilityTests` 验证无渐隐的隐藏槽位在直接和缓存绘制中均不残留文字或图标。Gallery `AdaptiveShellTests` 检查壳层重排、故事状态、搜索、目的地与两种主题入口；Sidebar 页提供窄/宽/触摸预览。设备触摸与读屏仍按 [自适应规范](adaptive-spec.md) 第 4 节取样。

### 调整栏宽

传入可选 `width: Binding<Float>`，常驻栏会提供可拖拽、可键盘聚焦的分隔柄。省略 binding 时仍由 `options.layout.sidebarWidth` 提供固定宽度；独立 `Sidebar` 的外部尺寸继续由调用方布局管理。

`options.resizing` 是独立的 `SidebarResizeOptions` 组：`minimumWidth` 默认 180、`maximumWidth` 默认 480、`minimumContentWidth` 默认 320、辅助功能 `label` 默认 "Resize navigation"。非有限值恢复默认值，最大宽度不会小于最小宽度。

- 栏宽是逻辑点，不随文字或 DPI 缩放。实际宽度受容器和内容最小空间限制，但布局本身不改写请求 binding；再次变宽恢复请求宽度。非法请求只在显示时回退，用户操作才写入夹紧后的有效值。
- 分隔柄单独占用 7pt 指针区域，触摸或混合输入占 44pt；视觉为 1pt 细线，悬停/拖动与键盘焦点有反馈。它不覆盖导航项或内容操作。空间不足以调整时隐藏分隔柄并优先保留主内容。
- 拖拽捕获指针，离开分隔柄仍跟随；Escape 恢复本次拖拽起始宽度。Left/Right 移动 16pt，Shift 移动 32pt，Home/End 到当前可用范围两端。RTL 的方向键和拖动遵循物理方向，增减辅助功能动作仍表示逻辑栏宽增减。
- slider 语义提供完整名称、当前点数、说明，以及 increment/decrement/setValue。切到 Rail 或抽屉时不保留隐藏分隔柄的输入或捕获，焦点交给选中目的地或打开按钮；禁用交互、形态/输入变化和卸载都会结束捕获。

`SidebarResizeTests` 覆盖容器三档与阈值往返、100%/200%、明暗主题、三种输入、RTL、草稿/焦点/滚动/节点保留、拖拽/取消/键盘/辅助功能、约束与非法请求及真实 AI 查询。`SidebarHierarchyTests` 8/8 覆盖嵌套展开/收起、项级 ellipsis/右键菜单与 390 touch 的 44pt 触发器、可见项遍历、程序化选择展开祖先、数据删除/禁用回退、本地展开 + Rail/RTL、AdaptiveSidebar 390/720/1280 × 100%/200% × 主题/输入矩阵，以及真实 AI `query_ui_nodes` 对折叠子项的隐藏。Gallery 主壳层已采用；Sidebar 页另有独立预览、宽度重置按钮与 “Nested navigation” 示例（Audit log 带 Archive/Duplicate）。项级操作/上下文菜单已实现；行内可自定义的前后任意 View 插槽仍未实现。

本轮 macOS DevTools 验收通过自身 AI `query_ui_nodes`、输入桥和 Metal 渲染捕获完成：1280pt 主壳层拖拽 96pt 后从 240 变为 336pt，Right 后语义为 352pt，Home/End 分别到 180/480pt；Left 后 464pt，主内容从 471pt 开始。720/390pt 的可见调宽 slider 查询均为零。三档窗口的明暗主题、100%/200% 字体取样中，布局诊断均为零；200% 的嵌入式预览保持指定的 220pt 高度，目的地与后续内容不重叠。跨形态节点、草稿、焦点和滚动保留由同一实例的测试矩阵验证，三档原生窗口分别启动取样，不作为跨窗口节点保留证据。

先前固定栏宽的 macOS 原生 DevTools 取样：实际窗口 1224 → 722 → 390pt，主内容前导位置 240 → 56 → 0pt；导航目的地、搜索与内容节点 ID 保留，紧凑抽屉实际为 320×720pt。原生按钮计数跨切换保持为 1；这些记录验证窗口布局和事件路径，不代替设备触摸或动画帧时间验收。
