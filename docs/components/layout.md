# Box / Row / Column / Spacer

布局原语。它们只决定子节点的几何关系，不画任何像素，不参与命中测试。

## 总则

- `isHitTestable = false` —— 这些容器本身不接事件；事件透传到下层叶子节点。
- `_makeLayoutNode` 只设 Yoga `flexDirection` / `alignItems` / `justifyContent` / `gap`。
- 没有任何 background / border / cornerRadius —— 视觉走 modifier。
- 大小默认由内容决定。Box 默认 `alignItems: .stretch`，Column / Row 用其各自的便捷 alignment 枚举。

## Box

```swift
Box(direction: .row,
    alignItems: .stretch,        // Yoga.Align 全集
    justifyContent: .flexStart,  // Yoga.Justify 全集
    spacing: 0) { … }

Box(direction: .row,
    alignment: .topLeading,
    spacing: 0) { … }
```

最贴近 Yoga 原语，需要细粒度控制时用。

`alignment:` 是常见 9 宫格对齐的便捷写法。它会按 `direction` 映射到 `alignItems + justifyContent`；反向主轴（`rowReverse` / `columnReverse`）也会保持 `leading` / `trailing` / `top` / `bottom` 的视觉语义不变。

## Row

```swift
Row(alignment: .center, spacing: 0) { … }
```

`VerticalAlignment.{top | center | bottom}` —— Row 跨轴是 **垂直方向**，alignment 控制子节点垂直对齐。`.center` 是默认。

## Column

```swift
Column(alignment: .leading, spacing: 0) { … }
```

`HorizontalAlignment.{leading | center | trailing}` —— Column 跨轴是 **水平方向**，alignment 控制子节点水平对齐。`.leading` 是默认。

⚠️ **`Column` 不会把子节点拉伸到父宽**。`HorizontalAlignment` 没有 `.stretch` 选项；`.leading` 映射到 Yoga `flex-start`，子节点取自身内容宽度。需要让子节点撑满父宽，请用 `Box(direction: .column, alignItems: .stretch) { … }`。

## Spacer

```swift
Spacer(minLength: 0)
```

在父容器主轴上贪心吸收剩余空间（`flexGrow = 1`）。

⚠️ **Spacer 永远 `flexGrow=1`**。即使加 `.frame(height: 16)`，外层 frame 锚点固定高度，但 Spacer 与同级 `.flex()` 兄弟会争抢剩余空间，常见症状是后置的 Tree / List 被压成 1 行。需要"固定的视觉间距"时，请用：

```swift
Box(direction: .column, alignItems: .stretch) { EmptyView() }
    .frame(height: 16)
```

或外层用 `.padding(top: 16)`。

## 选择指南

| 想要 | 用 |
| ---- | -- |
| 横向排，子节点垂直居中 | `Row(alignment: .center)` |
| 纵向排，子节点水平居中 | `Column(alignment: .center)` |
| 纵向排，子节点撑满父宽 | `Box(direction: .column, alignItems: .stretch)` |
| 横向排，子节点撑满父高 | `Row` 默认 `.center`；要拉伸用 `Box(direction: .row, alignItems: .stretch)` |
| 主轴上把右侧子节点推到末尾 | 在中间插 `Spacer()` |
| 在 Box 主轴上给固定 16pt 间隙 | `EmptyView().frame(height: 16)`（别用 Spacer） |
| 子节点之间统一间距 | `spacing:` 参数（用 Yoga gap） |

## File map

- 全部在 [GuavaUICompose/Primitives/Box.swift](../../GuavaUI/Portable/Sources/GuavaUIComposeCore/Box.swift)


## 能力边界（实际代码复核）

| 需求 | 当前情况 |
| --- | --- |
| Flex / 横纵排列 / 对齐 / gap / 反向排列 | Box / Row / Column / Spacer 已有 |
| 流式换行 | Box 的 `wrap: .wrap` 已有，包装行向起点收拢；不是二维轨道 Grid |
| 裁剪与滚动 | ScrollView / BoundedScrollView；测量真实内容，原生滚动直接跟随平台，支持稳定 gutter；自定义手势可显式使用惯性/回弹 |
| 双面板与 IDE 工作区 | SplitView 与 Workspace；详见各自的约束与缺口 |
| 层叠内容 | absolutePosition / zIndex 与 Portal 支持绘制层级；缺独立公共 ZStack/Overlay 布局容器 |
| 大集合 | VirtualStack 的闭包行高形态提供已知可变行高、稳定 ID 锚点及窗口化；仍缺未知高度估测和统一加载协议 |
| 响应式候选布局 | LayoutThatFits 为同一组子视图选择候选 Layout；ContainerSizeReader 发布自身内容盒实测尺寸（容器查询，0.5pt 抗抖动阈值）；ViewThatFits 的 `wide:` / `compact:` 两套内容支持阈值或 intrinsic 选择，往返切换保留各自状态与节点；WidthClassReader 读取窗口级 compact/medium/expanded；默认容器阈值与 `UIEnvironment.Viewport.compactMaximumWidth` 一致 |
| Grid | Grid/GridLayout 有 fixed/flexible/adaptive 列、测量行高及 RTL 对齐；Grid 具备命名字段列、优先级、显隐菜单和 minimum 横向滚动兜底；LazyGrid 有等宽列与已知固定/可变行高窗口化；仍缺 span、显式 intrinsic 轨道和二维窗口化 |
| Masonry | 最短列放置、按宽度自动 1–2 列、列/项间距与 RTL；高度由子视图自然测量；不虚拟化。详见 [Masonry](masonry.md) |
| 应用自定义布局 | 公开 Layout / ProposedViewSize / LayoutSubview / LayoutContainer；容器尺寸查询由 ContainerSizeReader 覆盖；仍缺 baseline/alignment guide API 与 safeAreaInsets/frame-in-container 全量 proxy |
| 表单/属性布局 | Form / PropertyGrid 已有专门用途；不能代替通用约束或网格系统 |
| 特殊布局 | layoutDirection 贯通 Flex、自定义布局和逻辑 padding；SafeArea 嵌套消费宿主提供的逻辑 insets；平台自动 insets、完整组件 RTL/双向文字、Anchor/约束布局仍缺 |

LazyGrid 的 `.variable(...)` 提供每行未缩放逻辑高度（含最后不完整行），数量必须等于 `ceil(itemCount / columns)`。数据或列数改变时，调用方同步更新 authored 高度值；字号改变时组件自动缩放高度与行间距，不要预先乘 `TextScaler`。它没有 VirtualStack（闭包行高） 的内容宽度/TextScaler 高度回调，也不自动测量未知行高。

测量与尺寸基础已先于新容器落地。已有 Yoga Flex 不必重新命名或重复包装；StackLayout 提供自然尺寸算法供候选布局组合，伸展/压缩仍用 Box/Row/Column。

## 自定义测量与放置（2026-10-12）

应用实现 `Layout.sizeThatFits(proposal:subviews:) -> CGSize` 与 `placeSubviews(in:proposal:subviews:)`，然后直接 `MyLayout() { ordinaryViews }`。子视图保持普通 View，不需要 Node、全局注册或生命周期适配。`LayoutSubview.sizeThatFits(_:)` 返回自然测量结果，`place(at:proposal:isVisible:)` 放置子视图，`isVisible` 默认 true；false 保留节点与局部状态，停止该子树的绘制、输入和辅助功能，释放其焦点及指针捕获，不改写 authored opacity 或输入设置。算法只能在这次测量/放置期间使用这些短期值，测量必须确定且不能改变 UI 状态。

proposal 使用逻辑点；nil 是 intrinsic，非有限值归一化为 nil，负值为零。有限 proposal 是空间建议，不覆盖子视图的显式固定尺寸或 minimum；算法决定溢出、换行或退让。bounds 是扣除 padding/border 的内容区域，坐标相对容器。框架使用有界 proposal 缓存，子树变化跨自定义布局边界失效；普通 Flex 继续交给 Yoga。

```swift
Grid(columns: [.fixed(120), .flexible(minimum: 160)], columnSpacing: 12, rowSpacing: 8) {
    Text("Label")
    Text("A value that may wrap")
}

LayoutThatFits([StackLayout(.horizontal, spacing: 12), StackLayout(.vertical, spacing: 12)]) {
    Button("Save") {}
    Button("Restore") {}
}

ViewThatFits(threshold: 500) {
    Row(spacing: 8) { Button("Save") {}; Button("Restore") {} }
} compact: {
    Column(spacing: 8) { Button("Save") {}; Button("Restore") {} }
}

// Intrinsic: the wide branch is measured at an unspecified size.
ViewThatFits(fitting: .intrinsic) {
    Row(spacing: 8) { Text("Files"); Text("Preview"); Text("Settings") }
} compact: {
    Column(spacing: 8) { Text("Files"); Text("Preview"); Text("Settings") }
}

ContainerSizeReader { size in
    Text("\(Int(size.width)) × \(Int(size.height)) points available")
}
```

`ContainerSizeReader` 在布局后发布自身内容盒的实测尺寸，扣除 layout padding 和 border。它默认填充父级可用宽度，高度随内容；行内分配空间时用 `.flex(1, shrink: 1, basis: 0)`。父级必须提供有界宽度，避免内容自身决定用来选择内容的宽度。首次构建收到 `.zero`；下一次重组得到测量值。小于 0.5pt 的变化不发布，恰好 0.5pt 会发布。该阈值抑制尺寸噪声，不能替任意自定义尺寸反馈算法保证收敛。

`ViewThatFits` 按实测容器宽度阈值选择两套内容，阈值为 wide 分支的包含边界。threshold 模式下分支首次被选择时创建；已创建的分支在来回切换时保留自己的 `@State` 和节点身份，直到整个容器卸载。隐藏分支不参与布局、绘制、输入和可访问性，隐藏时释放其焦点与指针捕获；它仍挂载，因此订阅和资源仍存活，重任务应由应用按当前形态控制。跨形态共享的草稿使用应用持有的 Binding。除 `threshold:` 外，`fitting: .intrinsic` 会在 **unspecified** 宽高下测量 wide 分支的自然尺寸，只有自然宽高都放得下时才选 wide，否则选 compact；宽高任一超界都会退让。intrinsic 模式立即挂载两套分支以便测量，隐藏分支仍停止绘制/输入/语义。两种模式都保留分支节点与 `@State`；需要为同一组子视图选择不同 Layout 时仍用 LayoutThatFits。

`WidthClassReader { widthClass in … }` 读取 surface 级 width class；容器里嵌入的卡片应使用 ContainerSizeReader 或 ViewThatFits。默认断点为 compact < 600，medium < 1000，其余 expanded。画廊 `--component layout` 演示 `ContainerSizeReader` 与阈值选择，`--component viewThatFits` 演示 intrinsic 模式的宽/窄切换；控件 stories 各有窄窗、宽窗和触摸预览。

```swift
SafeArea(.horizontal) { content }
    .safeAreaInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 12))
    .layoutDirection(.rtl)
```

SafeArea 的 insets 由宿主提供，桌面默认零；它不推断操作系统刘海、软键盘或窗口 chrome。嵌套容器只消费尚未使用的边。显式 left/right 定位保持物理方向；leading/trailing padding 使用 Yoga start/end。方向一致不等于所有控件的图标、键盘和 bidi 文本已经验收。

大集合详见 [可变行高窗口化](https://github.com/AlexCat315/GuavaStudio/blob/main/GuavaUI/Tests/GuavaUIComposeTests/VirtualStackVariableRowsTests.swift)，候选算法详见 [响应式布局](standard.md)。画廊 `--component layout` 展示测量 Grid、自适应列、候选切换、RTL/insets、100K LazyGrid 和 100K 可变行高列表。普通 ScrollView 不因此自动窗口化。

## 响应式与输入密度

### Grid 字段列

普通 `.fixed` / `.flexible` / `.adaptive` 保持按行排列；`Grid` 在 minimum 超出分配宽度时提供横向滚动，交互单元格仍由调用方保证足够尺寸。需要列级显隐时，每列使用唯一非空 ID 与标题的 `.named`，sizing 选 `.fixed` 或 `.flexible`。命名字段列与匿名自适应卡片流不能混用。

```swift
Grid(columns: [
    .named(id: "name", title: "Name", sizing: .fixed(180)),
    .named(id: "count", title: "Quantity", sizing: .fixed(120), visibility: .automatic(priority: 10)),
    .named(id: "notes", title: "Notes", sizing: .flexible(minimum: 200), visibility: .automatic())
], columnSpacing: 12, rowSpacing: 8, columnVisibility: $columnChoices, isEnabled: isEnabled) {
    Button("Open") { openAsset() }
    Text("7 items")
    TextField("Notes", text: $notes)
}
```

`ColumnVisibility` 与 Table / DataTable 共用：默认 `.required` 保留；自动列按实际可用宽度和 minimum 移除低优先列，同优先级先移除靠后的列，至少保留一列。字号不缩小，行高由可见单元格实测。`columnVisibility` 是可选 `[String: Bool]` binding：true 强制显示、false 隐藏、缺省自动，必要列优先；无 binding 时选择属于当前挂载会话，卸载重置。命名 Grid 内置 Columns 菜单、当前数量及 Automatic columns 重置；入口和菜单行至少 44pt，必要列禁用并勾选。强制显示或必要 minimum 超宽时横向滚动；滚轮及程序揭示可用，通用触摸拖动与键盘滚动仍见规范第 5-9 项。

单元格按声明时的列数分行；隐藏列不把下一行数据移入空槽，恢复后保留节点、局部计数和编辑草稿。需要空槽请提供 `Box {}`，`EmptyView` 不占单元格。隐藏期间节点仍挂载，订阅和资源仍存活；所属 Popover、Tooltip、HoverCard 关闭，独立模态由应用管理。禁用 Grid 会关闭列菜单并释放焦点与捕获。直接使用 `GridLayout` 时，显隐选择传普通值 `columnVisibility`，菜单和滚动由宿主提供。

`GridColumnsTests` 覆盖 390/720/1280pt、100%/200% 字号、三种输入、明暗主题、RTL、源行对齐、首次隐藏几何、草稿、附属浮层、菜单、会话重置、横向揭示和经校验的 AI 查询。`CustomLayoutVisibilityTests` 验证直接与缓存绘制、焦点、命中和语义。Gallery `layout` 提供可编辑示例及窄/宽/触摸预览。

### Grid 跨列/跨行

子视图用 `.gridCellSpan(columns:rows:)` 声明覆盖的格数（经通用的 `LayoutValueKey` / `.layoutValue(key:value:)` 读到 `LayoutSubview`，子视图无需包装类型）。放置按行优先的稀疏流：放不下当前行剩余列的格子换到下一可用行，跨度夹紧到实际列数。行高先由单行格子决定，跨多行的格子若更高，把差额加到它覆盖的最后一行。格子宽度 = 覆盖轨道之和 + 间距，RTL 镜像。命名字段列（可隐藏）忽略跨度，避免隐藏一列时移动所有跨列格子。

### LazyGrid 二维窗口与跨列

`LazyGrid(columnWidth:)` 使用固定列宽，内容宽于视口时双向滚动，并且只构建可见列（含 overscan）与可见行的交集。`columnSpan: (Element) -> Int` 让元素覆盖多列，行按顺序打包，放不下的元素开启下一行；打包只读取整数跨度，不构建视图。使用跨列时 `.variable` 行高按打包后的行数提供。LazyGrid 不提供跨行 span；普通 Grid 的跨行能力不能直接推及 LazyGrid。`GridSpanTests` 覆盖放置、行高分配、RTL、打包与 5,000 格双向窗口。

### Masonry

`Masonry` 是按最短列放置的瀑布流容器，适合高度不一的卡片墙。列数由 `floor((width + columnSpacing) / (minimumColumnWidth + columnSpacing))` 决定并夹在 1…`maximumColumns` 之间，默认最多 2 列；窄宽自动单列，宽屏也不会超过上限。列宽均分可用宽度；`columnSpacing` 只出现在列间，`itemSpacing` 只出现在同列卡片间。卡片以列宽测量，高度自然增长；文本缩放由卡片自身处理。RTL 下第 0 列位于 trailing，源顺序不变。

```swift
Masonry(minimumColumnWidth: 220, maximumColumns: 2,
        columnSpacing: 14, itemSpacing: 14) {
    for card in cards { CardView(card) }
}
```

Masonry 只负责布局，不虚拟化、不排序、不管理卡片数据；大集合请使用 `LazyGrid` 或 `VirtualStack`，需要显式二维轨道请使用 `Grid`。`MasonryTests` 覆盖最短列、列数上限、单列退化、间距与 RTL；Gallery `masonry` 页提供 Add card/Reset 与窄/宽/触摸预览，DevTools 实测 720pt 为两列、390pt 为单列，点击 Add card 后卡片数与列平衡更新。

2026-10-18 DevTools 实测：720×820 下卡片 frame 为两列（x=102/389，宽 273），390×820 下卡片单列排列；`input-ui` 点击 Add card 后计数从 8 变为 9，`capture-ui` 截图确认卡片墙、间距与文字裁切正常。

2026-10-17 macOS 原生 Gallery 验收：1280pt / 约 720pt 显示三列，390pt 自动保留 Asset；即时 AI 查询中隐藏 Notes 的可见可交互节点数为 0，手动恢复后为 1，同一输入框仍保留已输入草稿。恢复自动模式重新隐藏，必要列操作可用。200% 字号下 Columns 入口为 125×50pt，菜单行为 52pt，Asset 仍禁用并勾选；切换暗色后草稿与操作结果保留。前后 `get_diagnostics.layoutIssues.total` 均为 0。横向滚轮及程序揭示另由场景交互测试覆盖；以上取样不代表物理设备触摸或 GPU 帧时间测量。

### LazyGrid 文本缩放

LazyGrid 的固定与已知可变行高、行间距随 `TextScaler` 缩放一次；列宽与列间距保留 authored 几何。可变行高的前缀索引按 authored 高度建立，解析字号时共享索引，窗口化查询仍为 O(log n)。占位、单元格高度、可见范围和滚动 extent 使用同一缩放几何，恢复字号时夹紧越界滚动位置。LazyGrid 可承载非交互内容，因此不自动提升所有单元格到 44pt；交互单元格由调用方提供足够的 authored 行高。

`TextScaleRowTests.collectionGeometry` 覆盖固定行高的 100K 窗口化、100%/125%/200% 字号与三档宽度；`variableGrid` 验证可变行高、行间距、最后不完整行、重叠节点保留及滚动夹紧。Gallery `layout` 页的 100K 示例直接传入 `.fixed(48)`，由组件响应字号控件；`NavigationStateTests.lazyGridTextScale` 验证 200% 下行高为 96pt、视口仍为 240pt。

## 尺寸修饰器与局部重组

`frame(width: 300)` 只覆盖宽度，保留组件自己的高度；省略的 min/max 也不清除已有约束。恢复某个轴的 intrinsic 尺寸请显式使用 `frame(width: .auto)` 或 `frame(height: .auto)`，百分比用 `.percent(100)`。动态方向切换需要显式 `.auto` 清理旧轴，Form、PropertyGrid 和 Workspace 的调用已同步迁移。

组件局部状态更新、更换内部布局根时，ComposeCore 会按声明顺序重新施加调用方修饰器，避免组件内部的百分比尺寸覆盖调用方固定尺寸。AnyView 包装的多次同型修饰器也逐个保留；父更新替换该声明列表，避免保存过期值或无限追加。重放不会把键盘导航组的过期 tab-stop 恢复回来，焦点以当前组状态为准。

`.id(value)` 为条件、元组和数组提供一个带 key 的透明身份锚点，使整组内容按单个身份匹配。外层普通尺寸/样式修饰器拥有结构锚点时，子 key 留在所属边界；更新修饰器或重排组不会误重建组内局部状态。改变 ID 或移除内容会卸载旧子树，恢复使用默认状态。`StructuralModifierTests.identifiedConditional` / `identifiedArrays` 覆盖多层修饰、组重排、同名子 ID 的隔离和卸载恢复。

本地 Motrix MyGo 的 `dashboard.go`、`downloads.go`、`widgets.go` 主要通过 Row/Column、Grow、MinWidth(0)、滚动视口与裁剪卡片组织界面；其层次还依赖 palette、间距、圆角和文字字距。GuavaUI 已有相应 Flex 原语，不需要为相同几何再增加一套容器名称。但它的产品级 28/36pt 固定高度不能直接成为通用框架的行高契约，仍需按字体缩放与内容测量调整。
