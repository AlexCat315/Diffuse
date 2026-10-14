# List / ListRow

垂直、单选列表，固定行高并按可见区域虚拟化。负责行排版与点选 binding；行的视觉（选区填充、padding、字体）走 `ListRowStyle`。

## Anatomy

```
┌──────────────────────────────────┐
│  ┌────────────────────────────┐  │ ← row[0] (rowHeight)
│  │  rowContent(item, isSel)   │  │
│  └────────────────────────────┘  │
│       ↕ rowSpacing               │
│  ┌────────────────────────────┐  │ ← row[1]
│  │  rowContent(item, isSel)   │  │
│  └────────────────────────────┘  │
│  …                                │
└──────────────────────────────────┘
            ↑ ScrollView(.vertical) outer
```

## API

```swift
List(items, id: \.id, selection: $selectedID, rowHeight: 30, rowSpacing: 0) { item, isSelected in
    Text(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `selection` | `.constant(nil)` | 单选 binding，nil 表示未选 |
| `rowHeight` | 30 | Material list item 一致 |
| `rowSpacing` | 0 | 行间隙 |

## Tokens (DefaultListRowStyle)

选中态不在这张表里各自推导：`SelectionAppearance.resolve(.navigation, theme:)` 是唯一的
“这一行被选中了”的定义，Sidebar 目的地和 List 行共用同一个 role。行 style 只决定
role，不自己从原始颜色拼填充和圆角。

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| 选中 / hover / press 填充 | `SelectionAppearance.resolve(.navigation, …)` | theme |
| 选中圆角 | `theme.radius.md` | theme |
| 选中内缩 | horizontal `theme.spacing.sm`，vertical `theme.spacing.xs` | theme |
| 行高 | `rowHeight`；style 在其中居中内容，超出即裁切 | 调用方 |
| 文本颜色 | `onSurface` | theme |

hover 由行 host 直接绘制（不触发重组），圆角取同一个 appearance，所以 hover 与选中不会
一个圆一个方。

## Behavior

- **指针**：down + up 在同一行内 → 写 `selection.wrappedValue = id`
- **键盘**：未实现
- **滚动**：外层 `ScrollView(.vertical)`，wheel 自动支持；只挂载视口附近的行，用占位高度保留完整滚动范围。
- **虚拟化**：`List` 内部使用 `VirtualStack`；`VirtualStack(data, id: \.id, rowHeight: 30, scrollToIndex: target)` 和 `VirtualList(data, id: \.id, rowHeight: 30)` 可单独使用，默认额外挂载视口前后各 3 行。行内容需符合指定固定高度，视口应有明确高度。
- **调用方的尺寸约束生效**：`List` 最外层是键盘 host，所以 `.frame`/`.flex` 落在它上面，内部滚动容器取剩余高度并裁切。缺少这条时滚动容器会按自身内容撑高，行会画到容器外面去。
- **`scrollToIndex` 首次布局不生效**：第一帧还没有视口高度，此时做 reveal 会多滚一行并把这次请求消费掉，所以本来可见的目标也会把列表滚过头。`VariableVirtualStack` 用同一条规则。
- **多选**：v1 不支持

## Authoring rules

✅ 应当：
- 把 List 放在已有明确高度的容器内（否则会塌成内容高度）
- `selection: $someID` 时配合 `id: \.id` 提供稳定 ID
- 自定义视觉走 `ListRowStyle` + `.listRowStyle(_:)`；沿用 `SelectionAppearance` 的 role，不要自己拼选中填充和圆角
- 行内容高于 `rowHeight` 会被居中并裁切；把 Badge 之类的小控件算进行高预算里

❌ 不应：
- 在 row content 里再嵌一个 ScrollView
- 给 row content 写自己的选中高亮 —— style 已经处理；冲突会双高亮
- 为新的可选行 surface 重新发明选中样式 —— 加一个 role，或复用现有 role

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Material 3 | List item 高度（48 standard, 30 dense） |
| Fluent UI v9 | 单选 / 多选模式分离 |
| SwiftUI | `List(items, id:, selection:)` 调用形态 + ListStyle |

## File map

- 主体: [GuavaUICompose/Primitives/List.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/List.swift)
- Style + 默认: [GuavaUICompose/Theme/ListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/ListRowStyle.swift) · [DefaultListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultListRowStyle.swift)

## 响应式与输入密度

List 在 touch surface 上使用 max(rowHeight, 44) 作为真实行高，行 host、VirtualStack 的窗口化与滚动 extent 使用同一高度。返回 pointer 后恢复 authored rowHeight。通用 VirtualList/VirtualStack 不假定每行可交互，仍使用调用方高度。touch-only surface 不展示行 hover。
