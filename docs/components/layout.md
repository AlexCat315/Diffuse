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
| 大集合 | VariableVirtualStack 提供已知可变行高、稳定 ID 锚点及窗口化；仍缺未知高度估测和统一加载协议 |
| 响应式候选布局 | LayoutThatFits 为同一组子视图选择候选 Layout；仍缺容器查询和多套内容的 ViewThatFits |
| Grid | Grid/GridLayout 有 fixed/flexible/adaptive 列、测量行高及 RTL 对齐；LazyGrid 有等宽列与已知固定/可变行高窗口化；仍缺 span、显式 intrinsic 轨道和二维窗口化 |
| 应用自定义布局 | 公开 Layout / ProposedViewSize / LayoutSubview / LayoutContainer；仍缺 GeometryReader、baseline/alignment guide API |
| 表单/属性布局 | Form / PropertyGrid 已有专门用途；不能代替通用约束或网格系统 |
| 特殊布局 | layoutDirection 贯通 Flex、自定义布局和逻辑 padding；SafeArea 嵌套消费宿主提供的逻辑 insets；平台自动 insets、完整组件 RTL/双向文字、Anchor/约束布局和 Masonry 仍缺 |

LazyGrid 的 `.variable(...)` 提供每行高度（含最后不完整行），数量必须等于 `ceil(itemCount / columns)`。数据、列数或文字缩放改变时，由调用方同步更新高度值；它没有 VariableVirtualStack 的内容宽度/TextScaler 高度回调。

测量与尺寸基础已先于新容器落地。已有 Yoga Flex 不必重新命名或重复包装；StackLayout 提供自然尺寸算法供候选布局组合，伸展/压缩仍用 Box/Row/Column。

## 自定义测量与放置（2026-10-12）

应用实现 `Layout.sizeThatFits(proposal:subviews:) -> CGSize` 与 `placeSubviews(in:proposal:subviews:)`，然后直接 `MyLayout() { ordinaryViews }`。子视图保持普通 View，不需要 Node、全局注册或生命周期适配。`LayoutSubview.sizeThatFits(_:)` 返回自然测量结果，`place(at:proposal:)` 放置子视图；算法只能在这次测量/放置期间使用这些短期值，测量必须确定且不能改变 UI 状态。

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

SafeArea(.horizontal) { content }
    .safeAreaInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 12))
    .layoutDirection(.rtl)
```

SafeArea 的 insets 由宿主提供，桌面默认零；它不推断操作系统刘海、软键盘或窗口 chrome。嵌套容器只消费尚未使用的边。显式 left/right 定位保持物理方向；leading/trailing padding 使用 Yoga start/end。方向一致不等于所有控件的图标、键盘和 bidi 文本已经验收。

大集合详见 [可变行高窗口化](https://github.com/AlexCat315/GuavaStudio/blob/main/GuavaUI/Tests/GuavaUIComposeTests/VariableVirtualStackTests.swift)，候选算法详见 [响应式布局](standard.md)。画廊 `--component layout` 展示测量 Grid、自适应列、候选切换、RTL/insets、100K LazyGrid 和 100K 可变行高列表。普通 ScrollView 不因此自动窗口化。

## 尺寸修饰器与局部重组

`frame(width: 300)` 只覆盖宽度，保留组件自己的高度；省略的 min/max 也不清除已有约束。恢复某个轴的 intrinsic 尺寸请显式使用 `frame(width: .auto)` 或 `frame(height: .auto)`，百分比用 `.percent(100)`。动态方向切换需要显式 `.auto` 清理旧轴，Form、PropertyGrid 和 Workspace 的调用已同步迁移。

组件局部状态更新、更换内部布局根时，ComposeCore 会按声明顺序重新施加调用方修饰器，避免组件内部的百分比尺寸覆盖调用方固定尺寸。AnyView 包装的多次同型修饰器也逐个保留；父更新替换该声明列表，避免保存过期值或无限追加。重放不会把键盘导航组的过期 tab-stop 恢复回来，焦点以当前组状态为准。

本地 Motrix MyGo 的 `dashboard.go`、`downloads.go`、`widgets.go` 主要通过 Row/Column、Grow、MinWidth(0)、滚动视口与裁剪卡片组织界面；其层次还依赖 palette、间距、圆角和文字字距。GuavaUI 已有相应 Flex 原语，不需要为相同几何再增加一套容器名称。但它的产品级 28/36pt 固定高度不能直接成为通用框架的行高契约，仍需按字体缩放与内容测量调整。
