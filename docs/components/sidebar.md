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

同一分组按最大图标尺寸保留一个前导槽位；没有图标的项保留该槽位，使标题对齐。纯文字分组不保留空图标槽。默认使用 `icon.medium`，长标题换行，紧凑的计数徽标独立占位；行高以 38 逻辑像素为下限，随实际内容增长。选中、悬停、按下、键盘焦点和禁用状态都有对应的主题颜色；图标继承该行的前景色。

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

`presentation` 默认 `.expanded`，也可使用 `.rail(showsLabels: true/false)` 收为 72/56pt 导航轨，同一组目的地按钮、选择、焦点及头尾槽位状态保留；标签和徽标在图标模式下保留完整 tooltip 与辅助功能信息。呈现与内容几何变化后会显露选中项，普通滚动不被持续拉回。独立 Rail API 与边界见 [NavigationRail](navigation-rail.md)。

## 自适应壳层

`AdaptiveSidebar` 按**容器实际宽度**呈现同一份导航与页面。宿主提供有界宽高，安全区由宿主处理。

```swift
@State var selection: String? = "overview"
@State var navigationOpen = false

AdaptiveSidebar("Workspace", isPresented: $navigationOpen, selection: $selection,
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

抽屉暴露带完整名称的 dialog，并约束焦点和后台输入。关闭开始时禁用抽屉输入并还原触发器焦点；变宽解除模态约束并保留导航焦点，导航因变窄而隐藏时交给打开按钮，再变宽交给选中目的地。紧凑抽屉支持可反转的边缘动画；Rail 与完整导航覆盖层之间直接重排，遮罩淡变。两种覆盖形态均支持轻量主题遮罩、Escape、点击遮罩、选择后关闭和左滑关闭；通过 `drawer` 独立配置关闭策略，减少动画立即完成。Rail 和抽屉目标至少 44pt，普通常驻栏的指针密度保持 38pt 下限，触摸仍至少 44pt。

`allowsEdgeSwipe` 默认关闭；启用后仅在支持触摸的紧凑容器中观察前导 24pt 内开始的右滑，水平意图成立才取消子按钮按下。普通点击、前导区外的手势、纵向滚动和文本选择保留原有输入路径。独立 `NavigationDrawer` 的唤出仍由应用提供按钮。

验收：`AdaptiveSidebarTests` 覆盖 390/720/1280pt、100%/200% 字号、三类输入、明暗主题、状态/滚动/节点保留、焦点交接、关闭策略、边缘/左滑、动画反转与卸载，并通过真实 AI `query_ui_nodes` 检查可见性、模态输入权限及关闭后隐藏。`RetainedVisibilityTests` 验证无渐隐的隐藏槽位在直接和缓存绘制中均不残留文字或图标。Gallery `AdaptiveShellTests` 检查壳层重排、故事状态、搜索、目的地与两种主题入口；Sidebar 页提供窄/宽/触摸预览。设备触摸与读屏仍按 [自适应规范](adaptive-spec.md) 第 4 节取样。

嵌套子菜单、可调整栏宽、项级操作/上下文菜单及行内可自定义的前后任意 View 插槽仍未实现，不能将当前 Sidebar 视为与 GPUI Kit Sidebar 完全等价。

macOS 原生 DevTools 取样：实际窗口 1224 → 722 → 390pt，主内容前导位置 240 → 56 → 0pt；导航目的地、搜索与内容节点 ID 保留，紧凑抽屉实际为 320×720pt。原生按钮计数跨切换保持为 1；此记录验证窗口布局和事件路径，不代替设备触摸或动画帧时间验收。
