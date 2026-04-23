# Slider

连续单滑块。把一个 `Double` 绑定到一段 `ClosedRange<Double>`。

## Anatomy

```
                   ┌────────┐
   ━━━━━━━━━━━━━━━━│  thumb │━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                   └────────┘
   └─── filled ───┘└──────────── unfilled ─────────────────┘
                       ↑ track (height 4)
```

- **track**：水平细条，圆角 `theme.radius.sm`，颜色 `surfaceVariant`
- **filled**：track 中已选区段，颜色 `accent`
- **thumb**：圆形把手，直径 18，颜色 `accent`；focused 时叠 2px `focusRing` 描边

## Tokens (DefaultSliderStyle)

| 槽位 | 默认 | 来源 |
| ---- | ---- | ---- |
| trackHeight | 4 | 硬编码 |
| trackColor | `surfaceVariant` | theme |
| fillColor | `accent` (enabled) / `surfaceVariant` (disabled) | theme |
| thumbDiameter | 18 | 硬编码 |
| thumbColor | `accent` (rest) | theme |
| trackCornerRadius | `theme.radius.sm` | theme |

## States

| State | 视觉 |
| ----- | ---- |
| rest | thumb = `accent` |
| hover | thumb = `accentHover` |
| press | thumb = `accentPressed` |
| focus | thumb 加 2px `focusRing` 描边 |
| disabled | track + fill + thumb 全部 `surfaceVariant` |

## Behavior

- **指针**：down 把 thumb 锁定到光标 X 位置；motion 时持续更新 binding；up 释放并触发 `onEditingChanged?(false)`。
- **键盘**：未实现（待 Phase 9 键盘焦点链）。
- **step**：非 nil 时把值四舍五入到最近的 step 倍数。

## Authoring rules

✅ 应当：
- `Slider(value: $volume, range: 0...1)` —— range 任意，必要时给 `step`
- 旁边并列展示数值标签：`Row(alignment: .center, spacing: 12) { Slider(...).flex(); Text("\(Int(value*100))").frame(width: 50) }`
- 自定义视觉走 `SliderStyle` 协议 + `.sliderStyle(_:)`

❌ 不应：
- 改 thumbDiameter < 16（命中区会变得不可用）
- 写 `Slider().padding(...)` —— Slider 自己留出 thumb 的横向空间

## Known issues / TODO

- 没有 keyboard support（方向键、Page）
- 没有 tick mark / discrete step 视觉提示
- 没有 vertical 方向

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Material 3 | continuous Slider 的 thumb 大小 + filled track 视觉 |
| Fluent UI v9 | hover/press 反馈强度 |
| Radix Primitives | `Slider.Root` + `Slider.Track` + `Slider.Range` + `Slider.Thumb` 槽位拆分 |
| SwiftUI | `Slider(value:in:step:)` 调用形态 |

## File map

- 主体: [GuavaUICompose/Primitives/Slider.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Slider.swift)
- Style 协议 + 默认: [GuavaUICompose/Theme/SliderStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/SliderStyle.swift)
