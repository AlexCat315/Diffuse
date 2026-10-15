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

当前接口是分组目的地导航。折叠到纯图标、嵌套子菜单、项级操作/上下文菜单及可自定义的前后任意 View 插槽仍未实现，不能将当前 Sidebar 视为与 GPUI Kit Sidebar 完全等价。
