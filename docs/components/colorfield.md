# ColorField

紧凑颜色选择器。色块触发器打开 RGBA 通道弹层；通道行使用共享 `Slider`，并保留十六进制输入。

## Anatomy

```
[ 52×22 swatch ]  #587EE7FF  88, 126, 231, 255
        ↓ click
┌──────────────────────────────┐
│  preview                     │
│  R  ───●────────  88         │
│  G  ──────●─────  126        │
│  B  ─────────●──  231        │
│  A  ───●────────  255        │
│  HEX [ #587EE7FF          ]  │
└──────────────────────────────┘
```

## API

```swift
@State private var tint = Color(red: 88, green: 126, blue: 231)

ColorField(color: $tint)
ColorField(color: $tint, showAlpha: false, showsInlineValues: true)
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `color` | 必填 | RGBA `Color` 绑定 |
| `isEnabled` | `true` | 禁用后色块与弹层不接输入 |
| `showAlpha` | `true` | 显示 A 通道与 8 位 hex |
| `showsInlineValues` | `false` | 色块旁显示 hex |
| `showsInlineChannels` | `true` | 与 `showsInlineValues` 配合显示 RGB 文本 |

## Sizing

- 色块固定 52×22；触摸命中由 Popover 触发器提升到 44pt。
- 弹层宽度 `min(280, max(176, viewport − 24))`：390/720 窗口为 280，200 窗口为 176；hex 字段不因窄而隐藏。
- 通道行使用共享 Slider，≥44pt 触摸轨道与 1pt 刻度能力沿用 Slider。

## Behavior

- **弹层**：点击色块打开，Escape/外部点击关闭；触发器的辅助功能名称包含当前 hex 与通道值。
- **通道**：R/G/B/A 各自 0–1；整数文本显示 0–255。
- **HEX**：接受 `#RRGGBB` 或 `#RRGGBBAA`；非法输入恢复当前颜色。
- **窄宽**：弹层宽度随 viewport 收缩，内容列不隐藏；高度由内容决定。

## Verification

- `ControlDensityTests.colorPickerWidth`：720/390→280，200→176。
- Gallery `colorField` 页提供默认与 `showAlpha:false` 两种字段。
- DevTools 720×820：点击色块后查询 `color-picker-panel` 为 280×184；200×820 时为 176×184，截图确认 hex 输入仍可见。

## File map

- 主体：[ColorField.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/ColorField.swift)
- 测试：[ControlDensityTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/ControlDensityTests.swift)
