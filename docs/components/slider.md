# Slider

连续单滑块。把一个 `Double` 绑定到一段 `ClosedRange<Double>`；`axis: .horizontal`（默认）或 `.vertical`。

## Anatomy

```
                   ┌────────┐
   ━━━━━━━━━━━━━━━━│  thumb │━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                   └────────┘
   └─── filled ───┘└──────────── unfilled ─────────────────┘
                       ↑ track (height 4)
```

- **track**：沿主轴的细条，圆角 `theme.radius.sm`，颜色 `surfaceVariant`
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

- **指针**：horizontal 按 X、vertical 按 Y 映射，down 后捕获，拖出边界仍夹紧更新，up 释放并触发 `onEditingChanged?(false)`。垂直方向底部为最小、顶部为最大；水平填充从逻辑 leading 开始，RTL 右端为最小。
- **键盘**：↓ 减小、↑ 增大；水平 ← / → 跟随阅读方向（RTL 反转），垂直 ← 减小 / → 增大。Home / End 到范围两端；PageUp / PageDown 移动 10 个 step（连续滑块的 step 为 span/100，即 10% 区间），并在边界夹紧。
- **step**：非 nil 时把值四舍五入到最近的 step 倍数。
- **ticks**：`showsTicks: true` 且提供 `step` 时，在每个离散 step 位置绘制 1pt 刻度；最多 40 段，避免密集噪声。

## Authoring rules

✅ 应当：
- `Slider(value: $volume, range: 0...1)` —— range 任意，必要时给 `step`
- 需要离散刻度时用 `Slider(value: $level, range: 0...5, step: 1, showsTicks: true)`
- 垂直电平用 `Slider(value: $level, range: 0...100, step: 5, axis: .vertical).frame(height: 160)`；自然尺寸 24×160，触摸宽度至少 44pt。用 `.accessibilityLabel("Level")` 提供业务名称。
- 旁边并列展示数值标签：`Row(alignment: .center, spacing: 12) { Slider(...).flex(); Text("\(Int(value*100))").frame(width: 50) }`
- 自定义视觉走 `SliderStyle` 协议 + `.sliderStyle(_:)`

❌ 不应：
- 改 thumbDiameter < 16（命中区会变得不可用）
- 写 `Slider().padding(...)` —— Slider 自己留出 thumb 的横向空间

## 验收

`SliderAxisTests` 覆盖 390/720/1280 × touch/mixed/pointer、Y 轴点击与越界拖动、捕获释放、方向键、辅助功能赋值/步进和 RTL；既有 `SliderTests`、`FocusRingTests` 与 `TouchDensityTests` 继续验证水平行为、样式、刻度与焦点。

2026-10-18 DevTools：390×820 touch 下从 (68,584) 上拖到 (68,520) 后按 ↑，AI 查询 `slider-vertical` 为 `95.0`、文字为 `95%`；720×820 dark/mixed 下目标宽 44、高 160，1280×820 pointer/200% 下目标宽 24、高 160。三张镜像已实际查看：圆角表面、细轨道、刻度、禁用对照与数值层级清晰，没有文字/轨道重叠；窄窗口通过外层滚动显露完整故事。

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Fluent UI v9 | hover/press 反馈强度 |
| Radix Primitives | `Slider.Root` + `Slider.Track` + `Slider.Range` + `Slider.Thumb` 槽位拆分 |
| SwiftUI | `Slider(value:in:step:)` 调用形态 |

## File map

- API、输入、几何、绘制：[Slider](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/Slider/)
- Style 协议 + 默认：[SliderStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/Styles/Components/SliderStyle.swift)

## 响应式与输入密度

touch surface 上 Slider 的命中区域宽高至少 44pt，轨道和 thumb 仍居中绘制。touch-only surface 忽略 hover；切回 pointer 恢复 authored minima 与原生 24pt 高度。
