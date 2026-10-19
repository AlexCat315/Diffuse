# NumberField

单值浮点输入。基于 `TextField`，但把外部语义固定为 `Binding<Float>`，内部维护字符串 draft，只在提交时解析并写回。

## Anatomy

```
┌──────────────────────┐
│ 12.50                │
└──────────────────────┘
```

- **surface**：沿用 `TextField` 的输入框外观
- **draft text**：聚焦编辑时保留用户输入中的临时态字符串
- **committed value**：失焦或回车后解析为 `Float` 并写回绑定

## API

```swift
NumberField(value: $x)
NumberField(value: $rotation, decimals: 1, size: .small)
NumberField(value: $mass, isEnabled: false)
NumberField(value: $amount, locale: Locale(identifier: "de_DE")) // 12,5
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `value` | 必填 | `Binding<Float>` |
| `decimals` | `2` | 格式化时保留的小数位上限，自动去掉尾随 `0` |
| `size` | `.automatic` | 直接复用 `TextField.Size` |
| `isEnabled` | `true` | `false` 时禁用输入 |
| `minValue` / `maxValue` | `nil` | 提交与步进时夹紧；到达边界时步进按钮禁用 |
| `step` | `nil` | 步进与输入归一化的步长 |
| `showsStepper` | `false` | 显示紧凑上下箭头列；方向键步进不依赖它 |
| `prefix` | `nil` | `NumberField.Prefix("W", tint: .accent)`：输入框内前导标签芯片，与文本共用一个圆角边框与焦点环，并作为拖拽 scrub 手柄 |
| `resetValue` | `nil` | 双击前缀芯片恢复为该值 |
| `locale` | `.current` | 小数分隔符、数字与正负号；绑定始终为 `Float`，不保存格式化字符串 |

## Behavior

- **提交时机**：`Return` 或失焦时提交
- **键盘步进**：↑ / ↓ 调整值，Shift ×10、Alt ×0.1；达到 min / max 边界停止
- **拖拽 scrub**：有 `prefix` 时水平拖动芯片实时改值，每 4pt 一个 `step`（未指定为 1）；按下时按住 Shift ×10、Option/Alt ×0.1；结果夹紧到 min / max，并同步正在编辑的草稿
- **重置**：有 `resetValue` 时双击芯片恢复
- **解析策略**：按 `locale` 归一化小数分隔、数字与正负号后完整解析；支持指数，拒绝分组符、尾随垃圾、NaN 和无穷值。失败时恢复当前已提交值；例如 `de_DE` 接受 `12,5`，拒绝 `1.234`，不会把它误当 1234。
- **编辑体验**：聚焦后显示 draft，避免把 `1.`、`-` 这类中间态立刻回写成格式化结果
- **格式化**：不插入千位分组；小数位上限夹紧在 0…6，移除尾随零并归一化舍入后的负零。`de_DE` 的 1.5 显示 `1,5`，`en_US_POSIX` 显示 `1.5`。

## Authoring rules

✅ 应当：
- 在 Inspector 的单值数值字段使用 `NumberField`
- 和 `Row` / `PropertyGrid` 组合成 `X / Y / Z` 三联编辑
- 指针面 `.small` 最小 28pt；触摸面至少 44pt，大字号应允许控件增高

❌ 不应：
- 把 `NumberField` 当流程导航（那是 `Stepper`）；数值增减用 `showsStepper` 或方向键
- 在调用方把本地化字符串写进数值模型；模型保持 `Float`，显示与编辑交给 `locale`

## Known issues / TODO

- 拖拽调整的修饰键在按下时决定（指针移动事件不携带修饰键）
- 芯片不进入 Tab 顺序：键盘与读屏使用文本输入与方向键步进；芯片名称作为输入框辅助功能标签

## Vec3Field

三个轴共享同一 `locale`、精度、步长和边界；轴 chrome 最小高度为 small 28 / regular 32 / large 40 乘文本缩放，触摸时再取 44pt 下限。内部实际输入面填满轴单元，轴标签同步缩放。每轴基准 96pt、最小 88pt，窄宽按 X/Y → Z 换行并保留草稿与焦点。

```swift
Vec3Field(x: $x, y: $y, z: $z, locale: Locale(identifier: "de_DE"))
```

## 验证

- `NumericLocaleTests`：五种 locale 的数字/符号往返、严格拒绝非法值、真实事件提交/恢复/步进，390/720/1280 × 100%/200% 的三轴值与输入面高度。
- `NumberFieldTests`、`NarrowReflowTests` 与 TextField 回归测试验证提交、边界、换行及显式高度的输入面。
- Gallery `numberField` 的两个 locale 共享同一数值绑定，`vec3Field` 提供三轴与 mixed 示例；实际 DevTools 输入与镜像结果见 [自适应验收记录](adaptive-spec.md#5-规范完成清单按本文验收)。

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| HTML | `input[type=number]` 的提交语义 |
| Unity Inspector | 紧凑数值输入在属性面板中的布局角色 |
| SwiftUI | `TextField(value:format:)` 的数值绑定方向 |

## File map

- [NumberField.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/NumberField.swift)
- [NumericTextFormat.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/NumericTextFormat.swift)
- [Vec3Field.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/Vec3Field.swift)
