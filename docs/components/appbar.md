# AppBar / NavigationBar

`AppBar` 是有界容器内的应用标题栏，组合返回、标题、副标题、主操作和命令菜单。它复用 Toolbar 的命令测量、保留节点、键盘导航和 Menu；不会创建第二套命令状态。

```swift
AppBar("Workspace permissions", subtitle: "All changes saved",
    back: MenuItem(id: "back", title: "Back to projects") { openProjects() },
    primary: ToolbarItem(MenuItem(id: "save", title: "Save workspace") { save() },
        icon: .resource(UIIcons.Action.check)),
    actions: [
        ToolbarItem(MenuItem(id: "find", title: "Find") { find() },
            icon: .resource(UIIcons.Action.search), placement: .automatic(priority: 10)),
        ToolbarItem(MenuItem(id: "share", title: "Share project") { share() },
            icon: .resource(UIIcons.Action.share))
    ], configure: { $0.isEnabled = canEdit })
```

| 槽位 / 尺寸 | 契约 |
| --- | --- |
| 返回 | 可省略；ghost 图标按钮，44pt 命中，名称来自 `MenuItem.title`；RTL 使用右箭头 |
| 标题 | `bodyStrong` 单行尾部省略；全文 tooltip 与 heading 名称保留；不会为了容纳命令缩小字号 |
| 副标题 | 宽模式显示 `caption` 单行文字；紧凑模式作为 heading value 保留，隐藏视觉占位 |
| 操作 | 容器 <600pt 最多 1 个，其他宽度最多 3 个；主操作优先保留；其他命令按优先级及实测空间收进菜单 |
| 更多 | 固定 44pt 图标入口，完整名称和展开状态；所有菜单行至少 44pt，长内容仍可换行、滚动 |
| 高度 | 基线至少 48pt（下方分隔线另计）；控件至少 44pt，200% 字号按内容增长 |
| 安全区 | 仅宿主消费 `SafeArea`；AppBar 不重复添加系统状态栏或键盘 inset |

`AppBarOptions` 持有启用状态、辅助功能分组名称、紧凑阈值和分隔线方向。非有限阈值恢复 600pt，负值夹到零。阈值取自实际分配，嵌入宽窗口的窄卡片也使用紧凑呈现。

`primary` 总是排在其他操作前并优先常驻。推荐给手机主操作提供有意义的图标；文字主操作按空间截断并保留全文，不把“更多”挤到视口外。`actions` 中的 `.overflow` 始终进菜单，`.always` 在 AppBar 的数量上限内优先于普通操作；相同优先级保持输入顺序。所有命令 ID 必须唯一，禁用/选中/危险角色与菜单来自同一份 `MenuItem`。无返回、无主操作或空操作列表均可使用。

Tab 顺序为返回 → 可见操作 → 更多，标题不加入 Tab 停靠点；左右/Home/End 复用 Toolbar，菜单支持方向键、Home/End、Enter/Space、Escape 与关闭后还原。宽度改变导致命令转入菜单时交接焦点，菜单集合变化时关闭当前菜单；禁用和卸载会清理捕获、焦点及浮层，外部页面仍可操作。

标题语义使用 `AccessibilityRole.heading`，AI 可按 `role: "heading"` 定位全文。macOS 26+ 映射为 [AppKit headingRole](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/role/headingrole)；较旧 macOS 保留完整文字但使用 staticText 原生角色。其他宿主的原生读屏接入与设备验证继续由自适应规范第 4 节及第 5-14 项跟踪。

`AppBarTests` 覆盖 390/720/1280pt、100%/200% 字号、触摸/混合/指针、明暗主题、长标题与文字主操作、RTL、安全区、Tab/菜单/焦点、禁用/卸载及真实 AI 工具查询。`SingleLineTextTests` 验证字符边界、实际 shaping/测量/绘制；`NativeAccessibilityTests` 验证原生角色与全文。Gallery `--component appBar` 提供可交互故事、宿主安全区样例及窄/宽/触摸预览，Gallery `AppBarTests` 验证真实操作结果。物理设备触摸、读屏与动画帧时间不由宿主单元测试代替。

2026-10-16 macOS 原生 Gallery 复核：1280/722/390pt 窗口内实际 AppBar 宽度分别为 936/562/286pt，缩放窗口后节点身份保留；100% 字号高度 49pt。390pt 窗口、200% 字号、文字主操作时高度增长到 55pt，主操作 120×50pt，“更多”44×44pt 且未裁切，heading 仍包含完整 Unicode 标题。Save 和菜单 Find 的实际点击结果均已通过原生界面及 AI 查询确认；`input_enabled_only` 查询排除了禁用项。查询使用 [DevTools 即时 AI 工具入口](../architecture/agent-framework.md#诊断工具)，不是仅检查 Gallery 源码。
