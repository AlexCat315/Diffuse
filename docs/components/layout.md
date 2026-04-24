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

- 全部在 [GuavaUICompose/Primitives/Box.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Box.swift)
