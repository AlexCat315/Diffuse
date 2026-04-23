# Panel

带标题栏的 surface 容器。把任意内容包装成"卡片"或"工具窗口"语义。

## Anatomy

```
┌──────────────────────────────────────────┐
│  Title                       [accessory] │ ← header bar
├──────────────────────────────────────────┤
│                                          │
│  content                                 │
│                                          │
└──────────────────────────────────────────┘
```

## API

```swift
Panel("Inspector") {
    // content
}

Panel("Console", isActive: true) {
    Button("Clear") { … }    // accessory
} content: {
    // content
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `title` | 必填 | 标题字符串 |
| `isActive` | false | 高亮态（如当前聚焦的工具窗） |
| `accessory` | EmptyView | 标题右侧操作槽（按钮 / 状态指示） |
| `content` | 必填 | 主体 |

## Tokens (DefaultPanelStyle)

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| 外层 background | `theme.colors.surface` | theme |
| 外层 cornerRadius | `theme.radius.lg` | theme |
| 外层 border | 1px `borderSubtle`，active 时换 `borderStrong` | theme |
| header background | `theme.colors.surfaceVariant` | theme |
| header height | 内置（约 36） | — |
| title font | `bodyStrong` | typography |
| content padding | `theme.spacing.md` | theme |

## Behavior

- 纯视觉容器；自身不接事件
- `isActive` 切换由调用方决定（如焦点链 / 用户点击 header）
- header 的 accessory 槽可以放任何 View（Button / Toggle / Text）

## Authoring rules

✅ 应当：
- 把 Panel 作为"工具窗口"或"内容卡片"的 wrapper
- 内嵌 ScrollView 应在 content 槽里
- 多个 Panel 用 `SplitView` / `Box(.column)` 组合

❌ 不应：
- 在 Panel 外再加 background + cornerRadius —— 双层 chrome
- header 槽里塞复杂多行布局 —— 它是单行 horizontal

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Fluent UI v9 | Card + CardHeader |
| Material 3 | Card variants |
| Radix Primitives | 暂无原生，参考 Dialog 的 header/content 拆分 |

## File map

- 主体: [GuavaUICompose/Primitives/Panel.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Panel.swift)
- Style 协议 + 默认: [GuavaUICompose/Theme/PanelStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/PanelStyle.swift) · [DefaultPanelStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultPanelStyle.swift)
