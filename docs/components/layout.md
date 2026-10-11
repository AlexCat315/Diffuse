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
| 裁剪与滚动 | ScrollView / BoundedScrollView；测量真实内容，支持惯性/回弹和稳定 gutter |
| 双面板与 IDE 工作区 | SplitView 与 Workspace；详见各自的约束与缺口 |
| 层叠内容 | absolutePosition / zIndex 与 Portal 支持绘制层级；缺独立公共 ZStack/Overlay 布局容器 |
| 大集合 | VirtualStack 固定行高；Tree/List/DataTable 各有专门模型；缺可变行高虚拟布局 |
| 响应式候选布局 | 软件可根据已知窗口宽度切换；缺统一断点/容器查询/ViewThatFits 协议 |
| Grid | 缺显式/自适应列轨道、跨行跨列、intrinsic 内容轨道及 LazyGrid |
| 软件自定义布局 | 还没有公开 measure/propose/place Layout 协议与通用 GeometryReader |
| 表单/属性布局 | Form / PropertyGrid 已有专门用途；不能代替通用约束或网格系统 |
| 特殊布局 | Anchor/约束布局、Masonry、SafeArea/insets、RTL 逻辑方向未成套完成 |

下一步应先打通 proposal/measurement/placement 与布局方向契约，再实现 Grid、响应式候选布局和可变行高窗口化；直接添加名称相似的容器会留下测量、缓存和交互不一致的问题。已有 Yoga Flex 不必重新命名或重复包装。

## 尺寸修饰器与局部重组

`frame(width: 300)` 只覆盖宽度，保留组件自己的高度；省略的 min/max 也不清除已有约束。恢复某个轴的 intrinsic 尺寸请显式使用 `frame(width: .auto)` 或 `frame(height: .auto)`，百分比用 `.percent(100)`。动态方向切换需要显式 `.auto` 清理旧轴，Form、PropertyGrid 和 Workspace 的调用已同步迁移。

组件局部状态更新、更换内部布局根时，ComposeCore 会按声明顺序重新施加调用方修饰器，避免组件内部的百分比尺寸覆盖调用方固定尺寸。AnyView 包装的多次同型修饰器也逐个保留；父更新替换该声明列表，避免保存过期值或无限追加。重放不会把键盘导航组的过期 tab-stop 恢复回来，焦点以当前组状态为准。

本地 Motrix MyGo 的 `dashboard.go`、`downloads.go`、`widgets.go` 主要通过 Row/Column、Grow、MinWidth(0)、滚动视口与裁剪卡片组织界面；其层次还依赖 palette、间距、圆角和文字字距。GuavaUI 已有相应 Flex 原语，不需要为相同几何再增加一套容器名称。但它的产品级 28/36pt 固定高度不能直接成为通用框架的行高契约，仍需按字体缩放与内容测量调整。
