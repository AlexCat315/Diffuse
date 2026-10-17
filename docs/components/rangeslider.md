# RangeSlider

双 thumb 区间选择。两个 thumb 共用一条轨道；指针按距离选择 active thumb，方向键/Home/End 移动 active thumb，值始终保持在 `range` 内并满足 `minimumSpan`。

## Anatomy

```
┌──────────────────────────────────────┐
│ ────────●════════════════●────────── │
└──────────────────────────────────────┘
         start            end
```

- **track**：与 `Slider` 共用 `SliderStyle` token
- **range fill**：两个 thumb 之间
- **thumb**：start / end；active thumb 在键盘聚焦时绘制 focusRing
- **active thumb**：指针就近选择；键盘只移动 active thumb

## API

```swift
@State private var values: ClosedRange<Double> = 20...80

RangeSlider(values: $values, in: 0...100, step: 1, minimumSpan: 10)
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `values` | 必填 | `Binding<ClosedRange<Double>>` |
| `range` | `0...1` | 允许的上下界 |
| `step` | `nil` | 吸附步长；`nil` 连续 |
| `minimumSpan` | `0` | 两端最小间距 |
| `isEnabled` | `true` | 禁用后不接输入、不聚焦 |
| `onEditingChanged` | `nil` | 按下/释放回调 |

## Sizing

- 高度 24pt；触摸命中由 `applyTouchControlExtent` 提升到 44pt。
- 默认自然宽度 160，父级可 `.frame(width:)` 拉伸。
- thumb 直径与轨道厚度来自 `SliderStyle`；active thumb 的 focus ring 额外绘制 2pt 外圈。

## Tokens

与 `Slider` 完全一致：

| 槽位 | 来源 |
| ---- | ---- |
| track / fill / thumb | `SliderStyle.resolve(...)` |
| active focus ring | `theme.colors.focusRing` |
| disabled | `SliderStyle` 的 disabled 外观 |

## States

| 状态 | 行为 |
| ---- | ---- |
| rest | 两个 thumb；active 默认 lower |
| hover | 指针面 thumb 反馈沿用 SliderStyle |
| press | 按下就近 thumb 并捕获指针 |
| focus | active thumb 外圈 `focusRing` |
| drag lower | 限制在 `range.lowerBound ... upper - minimumSpan` |
| drag upper | 限制在 `lower + minimumSpan ... range.upperBound` |
| disabled | 不聚焦、不接输入，释放捕获 |

## Behavior

- **指针**：按下点距离哪个 thumb 更近就选哪个；随后 motion 更新该 thumb；up 释放捕获。
- **键盘**：Left/Down、Right/Up、Home/End 移动 active thumb；Step 默认 `span / 100`，提供 `step` 时按步长吸附。
- **辅助功能**：role=slider，value 为 `"lower – upper"`；increment/decrement 作用于 active thumb。
- **限制**：当前是一个焦点节点；Tab 仍执行系统焦点遍历，没有实现两个 thumb 各自的 Tab 停靠，也没有暴露两个独立 slider 值。需要双 thumb 独立语义时使用两个 `Slider` 或等待后续增强。
- **方向**：当前只实现水平方向，与 Slider 一致。

## Authoring rules

- 曝光区间、帧范围、价格过滤用 `RangeSlider`；单值用 `Slider`。
- 指针靠近哪个 thumb 就拖哪个；不要依赖“总是先移动 start”。
- `minimumSpan` 应小于等于 `range` 跨度；跨度不足时组件退化为整段。
- 需要两个独立可聚焦 thumb 的严格 a11y 场景，暂用两个 `Slider` 组合并在应用层校验先后。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/RangeSliderTests.swift`）：

- `pointerDrag`：按下 lower 附近并拖动，lower 更新、upper 不变，a11y value 同步。
- `minimumSpan`：lower 不能越过 `upper - minimumSpan`。
- `keyboard`：Right 增加 active thumb；End/Home 夹紧到边界。

Gallery `rangeSlider` 页提供可拖动区间、最小间距与实时 `Selected` 文本；`AdaptiveControlExamples` 提供 390/720/390-touch 预览。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component rangeSlider --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"slider","visible_only":true}'
guava-dev devtools input-ui 9229 --input \
  '[{"kind":"pointerDown","x":370,"y":286},{"kind":"pointerMove","x":328,"y":286},{"kind":"pointerUp","x":328,"y":286}]'
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"node_id":"116","visible_only":true}'            # value 10 – 80
guava-dev devtools capture-ui 9229 /tmp/guava-range.jpg
```

## References

- Flutter `RangeSlider`
- Material 3 range slider
- SwiftUI 无内置 RangeSlider（双 Slider 组合）
