# NavigationRail

紧凑目的地导航，默认宽 72pt，显示图标和文字；`showsLabels: false` 使用 56pt 纯图标形态。复用 `SidebarItem`，与 Sidebar、NavigationDrawer 共用选择、图标、徽标、禁用与键盘语义。

```swift
@State private var destination: String? = "projects"

NavigationRail(selection: $destination, items: [
    SidebarItem("projects", "项目") { $0.icon = AppIcons.projects; $0.badge = "12" },
    SidebarItem("activity", "最近活动") { $0.icon = AppIcons.activity }
], showsLabels: true).frame(height: 440)
```

带 `header` / `footer` 的初始化器提供顶部、底部任意 View 插槽；两者独立占位，中间目的地列表在有限高度内滚动。应用提供有界高度，Rail 自己确定宽度。槽位中的自定义操作应提供完整名称并保持可用的命中尺寸。

`expanded` 可选传入 `Binding<Set<ID>>`：`SidebarItem.children` 形成嵌套分组时，Rail 与普通 Sidebar 共享同一展开会话；省略时 Rail 自己持有本地展开集合。

## 外观与输入

纯图标轨的选中态是居中的 40×40 圆角方块（`surfaceVariant`），不再绘制 accent 侧条或铺满整行的深色带；hover/press 只在这块方形选择层上叠中性 state layer，并把图标从 `onSurfaceVariant` 提亮到 `onSurface`。带文字形态仍以整行胶囊承载图标与标题。行高至少 44pt，带文字形态使用 caption 并自然换行；200% 字号增加行高，不把文字压回固定高度。图标沿用 IconTheme 与缩放策略，解析一次后限制在轨道内部宽度，避免大型语义图标撑破固定轨道。缺少图标的目的地使用通用文件图标。

徽标在 Rail 上显示为图标角落的小圆点，完整值保留在辅助功能 value 和 tooltip。所有目的地都有完整标题 tooltip；纯图标模式不会丢失名称。图标与圆点不重复朗读。禁用目的地不可聚焦、不可激活，语义保留禁用及选中状态。

Tab 在目的地组内只有一个停靠点；Up/Down、Home/End 浏览、跳过禁用项并循环，显露目标。横向箭头及带修饰键的组合不改变选择。点击、Enter、Space 更新选择并调用 `onActivate`，方向键浏览只更新选择。焦点环遵循键盘/指针模态，触摸、混合和指针输入均保留至少 44pt 目的地。

## 切换呈现并保留状态

已有分组导航可直接改变 `SidebarPresentation`：

```swift
Sidebar(selection: $destination, sections: sections,
        presentation: .rail(showsLabels: false))
    .frame(height: 440, maxWidth: 280)
```

`.expanded` 恢复普通栏；`.rail(showsLabels: true/false)` 使用同一组按钮节点。切换保留选择、焦点和 header/footer 本地状态，分组标题在 Rail 里收起。初始选择、应用改变选择、呈现或内容几何变化后显露选中项；普通用户滚动不会持续被拉回。显露操作先刷新实际内容范围，并在范围夹紧偏移后换算目标坐标，避免重排时二次滚动到错误位置。tooltip 的定位与显露观察互不覆盖。

Rail 不自行选择窗口形态：medium/expanded 可由壳层使用，compact 应使用 [NavigationDrawer](navigation-drawer.md)。自动选择常驻栏、Rail 和抽屉可使用 [AdaptiveSidebar](sidebar.md#自适应壳层)，它保留同一导航和页面节点；Gallery 的中等宽度壳层采用 56pt 图标轨。

## 验证

`NavigationRailTests` 覆盖 390/720/1280pt、100%/200% 文字、明暗主题、三类输入、72/56pt 几何、完整名称、长词换行、图标约束、居中 40×40 选择块与 hover 图标提亮、按钮/焦点/槽位状态保留、选择显露与普通滚动、键盘/触摸激活及禁用/卸载捕获清理。DevTools AI `query_ui_nodes` 可按完整名称和 button 角色发现纯图标目的地，并读取声明的选中态和徽标值。

Gallery 提供 `--component navigationRail`、三种宽度/输入预览及同一 Sidebar 的三种呈现切换；`RailTests` 通过实际事件验证文字开关、共享选择和节点保留。设备触摸与读屏仍按规范第 4 节取样。

macOS 原生 DevTools 已通过真实复选框将 72pt 切到 56pt，验证目的地 elementID 保留及 44pt 命中高度；mirror 检查了带文字和纯图标两种呈现。
