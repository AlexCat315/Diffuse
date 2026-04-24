# IconButton

图标按钮组件。用于工具栏、紧凑命令位和无文本动作入口。

## Anatomy

```
┌──────────────────────────┐  ← button chrome（由 ButtonStyle 决定）
│         [ icon ]         │  ← Image(width:size, height:size)
└──────────────────────────┘
```

| 槽位 | 默认值 | 说明 |
| ---- | ------ | ---- |
| icon.size | 16 | 图标绘制尺寸（逻辑点） |
| icon.source | texture / file / resource | 三种资源入口 |
| icon.tint | `nil` | `nil` 表示跟随 ButtonStyle 的语义前景色 |
| role | `.normal` | 仅语义，不自动切换 destructive 视觉样式 |

## Variants

`IconButton` 本身不定义独立变体，视觉完全复用 ButtonStyle：

- `.primary`
- `.secondary`
- `.ghost`
- `.destructive`（需显式 `.buttonStyle(.destructive)`）
- `.plain`

## States

| State | 视觉来源 |
| ----- | -------- |
| rest / hover / press / focus / disabled | 由当前 ButtonStyle 决定 |

## Behavior

- **指针**：左键 down/up 触发点击，右键/中键向上冒泡。
- **键盘**：Space / Return / KP Enter（非重复键）触发 action。
- **命中区**：由 ButtonStyle 的 chrome 尺寸决定，不仅是 icon 的像素区域。
- **禁用**：`isEnabled: false` 时不注册交互处理，cursor 为 `notAllowed`。

## Authoring rules

✅ 应当：

- 使用默认 `tint: nil`，让图标跟随样式语义前景色。
- 在危险操作上同时表达语义与样式：`role: .destructive` + `.buttonStyle(.destructive)`。
- 工具栏场景优先配合 `.buttonStyle(.ghost)` 使用。

❌ 不应：

- 仅设置 `role: .destructive` 但不设置 destructive style，却期望自动危险色。
- 对彩色位图强行叠加任意 tint 而不检查可见性对比度。

## File map

- 组件实现: [GuavaUICompose/Primitives/IconButton.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/IconButton.swift)
- 按钮协议与样式环境: [GuavaUICompose/Theme/ButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/ButtonStyle.swift)
- 样式实现: [PrimaryButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/PrimaryButtonStyle.swift) · [SecondaryButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/SecondaryButtonStyle.swift) · [GhostButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/GhostButtonStyle.swift) · [DestructiveButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DestructiveButtonStyle.swift)
