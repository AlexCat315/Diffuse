# TabView / TabItem

单选多面板容器：标签条和当前内容共享稳定树结构，支持顶部、底部及 compact 自动换边。

## API

```swift
@State var page = "overview"

TabView(selection: $page, tabs: [
    TabItem("Overview", id: "overview", configure: {
        $0.icon = UIIcons.File.file
        $0.badge = "3"
    }) { overviewPage },
    TabItem("Workspace permissions", id: "permissions") { permissionsPage },
    TabItem("Unavailable", id: "unavailable", isEnabled: false) { EmptyView() }
]) {
    $0.variant = .bar
    $0.placement = .adaptive
    $0.overflow = .menu
}
```

| 值 | 语义 |
| --- | --- |
| `selection` | 必填 `Binding<ID>`，`ID: Hashable`；ID 唯一且稳定 |
| `tabs` | 按声明顺序排列；可动态增删、重新生成数组 |
| `variant` | `.bar`（默认，2pt 指示条）、`.segmented`（胶囊）、`.card`（卡片） |
| `placement` | `.adaptive`（默认）、`.top`、`.bottom` |
| `overflow` | `.wrap`（默认）、`.scroll`、`.menu` |
| `isEnabled` | 控制标签导航、关闭按钮和溢出菜单；当前面板内部控件由应用管理 |
| `TabItem.configure` | 可设 `icon`、短 `badge` 和 `onClose`；关闭回调由应用更新数组及后继 selection |

TabView 需要有界高度，当前内容填充剩余空间。selection 不命中可用标签时，内容为空；键盘停靠仍落在首个可用标签，不偷偷改写 binding。面板按标签 ID 隔离，只有当前面板挂载，切换页面会卸载旧面板；需跨页面保存的数据放在应用持有的状态或 Binding 中。仅调整宽度、字号、主题或标签位置会保留当前面板的节点、局部状态和焦点。

## 响应式与输入密度

`placement = .adaptive` 按 surface width class 在 compact 使用底部栏，其余顶部栏；显式 top/bottom 覆盖。容器里的标签条仍按自身实际宽度计算溢出，不把窗口宽度当作卡片宽度。

所有标签标题单行省略，完整原文同时保留在 tab 名称、help 和 tooltip。图标、徽标、关闭按钮与文字分别测量，文字承担宽度退让；touch 下标签与关闭按钮至少 44pt。单个标题在 wrap/scroll 模式也受容器宽度约束，不因标题很长而换成多行或挤走关闭按钮。

- `.wrap`：整项换到下一行，标签内部保持单行。
- `.scroll`：整条保持一行，横向滚动；键盘切换揭示当前标签。
- `.menu`：当前选中标签留在条中，其余按声明顺序尝试保留；隐藏项进入 More tabs 菜单。入口与菜单行至少 44pt，关闭菜单后选择的标签得到真实焦点。禁用项保留禁用语义；全部能放下时隐藏入口。极窄到图标、徽标、关闭按钮和入口的最小空间仍不足时保留它们的尺寸，并横向滚动。

隐藏标题仍挂载但不绘制、不接收输入、不进入辅助功能遍历。菜单只列当前隐藏项；要关闭隐藏文档，先在菜单选择它，再使用其关闭按钮。菜单是挂载会话状态，窗口变宽、项目集合改变或禁用时关闭；没有把临时显隐写入文档或 selection。

## 键盘与语义

标签组有一个顺序 Tab 停靠点，溢出入口另有独立停靠。方向键、Home、End 选择所有可用标签（包括隐藏项），跳过禁用项。选择隐藏项后等实际布局放置完成再聚焦，连续两次按键可在同一帧推进。面板内输入框保留自己的方向键。Menu 复用现有导航与 Escape 关闭，取消后恢复入口；选中条目则聚焦所选标签。

每个标签提供 `.tab` 角色、完整名称和 `isSelected`。图标及徽标不重复朗读，关闭按钮有独立的 `Close <title>` 名称与停靠点。颜色跟随当前主题：bar/card 使用 surface，segmented 使用 surfaceVariant；selected 使用 onSurface，其余使用 onSurfaceVariant，禁用使用 disabled ink。视觉样式协议与纯主题 token 化仍待完善。

## 验证与边界

`TabOverflowTests` 覆盖 390/720/1280pt、100%/200%、三种输入、明暗主题、RTL、三种外观、菜单/禁用/集合变化、连续按键、极窄最小尺寸、三种 overflow 的标题绘制及经校验的 AI 查询。`TabViewTests.switchingSamePanelType` 验证同类型面板不串用私有状态；`AdaptiveNavigationTests` 验证 compact 换边与状态保留；`TouchDensityTests` 验证触摸标签及关闭命中。Gallery `--component tabs` 和三预览展示菜单模式、长标题、状态保留与可关闭文档。

2026-10-17 macOS 原生验收完全通过 DevTools 输入与渲染通道完成：390/720/1280pt 的明暗画面均已取样，720pt 显示四个标题与入口，1280pt 显示全部五个标题并隐藏入口。390pt 的计数按钮在 100% → 200% 及暗色切换后保留同一节点与计数；200% 时入口为 46×46pt，长标题选中项为 237×52pt，完整名称仍可查询并显示 tooltip。菜单选择后 Home 键能切回 Overview；各阶段 `get_diagnostics.layoutIssues.total` 为 0。这些图像来自真实 DrawList 的渲染后端重放，不包含系统窗口合成器。

通用 ScrollView 的触摸拖动和键盘滚动仍按 [跨平台规范第 5-9 项](adaptive-spec.md#5-未实现项清单按本文验收) 跟踪；这里已实现的是标签导航、菜单可达、滚轮及程序揭示，不把它们作为完整触摸滚动的替代。

## File map

- [TabView 与标签样式](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/TabView.swift)
- [溢出布局](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Tabs/StripLayout.swift)、[菜单呈现](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Tabs/MenuStrip.swift)、[标签槽测量](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/InlineLabelLayout.swift)
- [专项测试](../../GuavaUI/Tests/GuavaUIComposeTests/Adaptive/TabOverflowTests.swift)
