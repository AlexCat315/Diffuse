# List / ListRow

垂直、单选列表。仅负责行排版与点选 binding；行的视觉（选区填充、padding、字体）走 `ListRowStyle`。

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

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| 选中底色 | `theme.colors.stateLayerSelected` | composited over current bg |
| hover 底色 | `theme.colors.stateLayerHover` | composited |
| 行高 | 由 `rowHeight` 参数决定 | 调用方 |
| 行 padding | 由 style 决定（默认 horizontal `theme.spacing.md`） | theme |
| 文本颜色 | `onSurface` | theme |

## Behavior

- **指针**：down + up 在同一行内 → 写 `selection.wrappedValue = id`
- **键盘**：未实现
- **滚动**：外层 `ScrollView(.vertical)`，wheel 自动支持
- **多选**：v1 不支持

## Authoring rules

✅ 应当：
- 把 List 放在已有明确高度的容器内（否则会塌成内容高度）
- `selection: $someID` 时配合 `id: \.id` 提供稳定 ID
- 自定义视觉走 `ListRowStyle` + `.listRowStyle(_:)`

❌ 不应：
- 在 row content 里再嵌一个 ScrollView
- 给 row content 写自己的选中高亮 —— style 已经处理；冲突会双高亮

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Material 3 | List item 高度（48 standard, 30 dense） |
| Fluent UI v9 | 单选 / 多选模式分离 |
| SwiftUI | `List(items, id:, selection:)` 调用形态 + ListStyle |

## File map

- 主体: [GuavaUICompose/Primitives/List.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/List.swift)
- Style + 默认: [GuavaUICompose/Theme/ListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/ListRowStyle.swift) · [DefaultListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultListRowStyle.swift)
