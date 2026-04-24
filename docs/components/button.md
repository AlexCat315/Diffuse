# Button

可点击的命令组件。承担"用户告诉系统执行某个动作"的语义。不要拿它代替链接或可选项。

## Anatomy

```
┌──────────────────────────────────┐  ← chrome (background + cornerRadius + border)
│  ╭────────────────────────────╮  │
│  │   [icon]  label   [icon]   │  │  ← centered Box(.row, .center, .center)
│  ╰────────────────────────────╯  │
└──────────────────────────────────┘
        ↑                ↑
    horizontal      vertical
    padding         centering
    (spacing.md)    via fixed chrome height
```

| 槽位 | 默认值 | Token |
| ---- | ------ | ----- |
| chrome.height | 32 | 硬编码（Material compact size） |
| chrome.cornerRadius | `theme.radius.md` | 6 (dark) / 6 (light) |
| chrome.padding (h) | `theme.spacing.md` | 12 |
| chrome.padding (v) | 0（高度由 frame 控制） | — |
| label.font | `bodyStrong` | 14pt 600 |
| icon-text gap | 调用方 `Row(spacing:)` 自己决定 | — |
| focus ring | 2px `theme.colors.focusRing` | 仅 focused 时显示 |

## Variants

每个变体只通过 token 区分，不复制几何参数。

| Variant | Background (rest) | Foreground | Hover | Press | 用途 |
| ------- | ----------------- | ---------- | ----- | ----- | ---- |
| Primary | `accent` | `onAccent` | `accentHover` | `accentPressed` | 主操作（每屏 ≤1） |
| Secondary | `surfaceVariant` + 1px `borderStrong` | `onSurface` | composited `stateLayerHover` | composited `stateLayerPressed` | 次操作 |
| Ghost | transparent | `onSurface` | `stateLayerHover` | `stateLayerPressed` | 工具栏、密集列表里的命令 |
| Destructive | `error` | `onAccent` | composited `stateLayerHover` | composited `stateLayerPressed` | 不可逆的破坏性操作（需显式 `.buttonStyle(.destructive)`） |
| Plain | none | inherit | none | none | 把 Button 当成纯命中区（自定义 chrome 时） |

## States

| State | 视觉 | 触发 |
| ----- | ---- | ---- |
| rest | variant 默认 | — |
| hover | 上表 hover token | 指针进入命中区 |
| press | 上表 press token | 指针 down，未释放 |
| focus | 多一圈 2px `focusRing` border | 键盘 Tab 聚焦 |
| disabled | opacity 0.55，cursor 改为 `notAllowed` | `isEnabled: false` |

State 切换走语义动效 `.animation(.semantic(.fast, in: theme), value: configuration.interactionKey)`，默认主题下 `theme.motion.fast = 80ms`。

## Behavior

- **指针**：down 设置 `isPressed = true`；up 在命中区内触发 `action()`，离开命中区释放则取消。
- **键盘**：Space / Return / KP Enter（非重复键）触发 `action()`。
- **Cursor**：enabled → `.pointer`，disabled → `.notAllowed`，可被外层 `.cursor(_:)` 覆盖。
- **命中区**：完整 chrome 大小（不只 label）。

## Authoring rules

✅ 应当：

- 调用方写 `Button("Save") { … }`，让 ButtonStyle 决定 chrome
- 自定义 chrome 时用 `.buttonStyle(.plain)` 并自己负责 padding / background / cornerRadius
- 多元素 label 用 `Row(spacing: 6) { Icon(); Text("Save") }`，Box 会把整个 Row 居中
- `role: .destructive` 只表达语义；视觉危险态请显式写 `.buttonStyle(.destructive)`

❌ 不应：

- 给 Button 加 `.frame(height:)` 强行改高（除非确认 32pt 不合适）
- 在 PrimaryButtonStyle 上手动写 `Color.indigo` —— 走 `theme.colors.accent`
- 用 `lighter()` / `darker()` 算 hover/press —— 走 `accentHover` / `accentPressed` 或 `composited(over: stateLayerHover)`
- 把 Button 当成可选项展示器（请用 Toggle / Checkbox / SegmentedControl）

## References

| 设计系统 | 对应组件 | 借鉴点 |
| -------- | -------- | ------ |
| Material 3 | Filled / Tonal / Outlined / Text Button | 5 个变体的语义 + state-layer overlay 体系 |
| Fluent UI v9 | PrimaryButton / DefaultButton / SubtleButton | "subtle" ≈ ghost 的 hover 反馈强度 |
| Radix Primitives | Button (asChild pattern) | label 完全由调用方决定的开放槽 |
| Flutter Material | ElevatedButton / FilledButton / TextButton | 高度 36 / cornerRadius 8 的体感（我们略小） |
| SwiftUI | Button + ButtonStyle | makeBody(configuration:) 协议形态直接对应 |

## File map

- 协议 + Configuration: [GuavaUICompose/Theme/ButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/ButtonStyle.swift)
- 主体: [GuavaUICompose/Primitives/Button.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Button.swift)
- 变体: [PrimaryButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/PrimaryButtonStyle.swift) · [SecondaryButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/SecondaryButtonStyle.swift) · [GhostButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/GhostButtonStyle.swift) · [DestructiveButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DestructiveButtonStyle.swift) · [PlainButtonStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/PlainButtonStyle.swift)
