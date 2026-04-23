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
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `value` | 必填 | `Binding<Float>` |
| `decimals` | `2` | 格式化时保留的小数位上限，自动去掉尾随 `0` |
| `size` | `.regular` | 直接复用 `TextField.Size` |
| `isEnabled` | `true` | `false` 时禁用输入 |

## Behavior

- **提交时机**：`Return` 或失焦时提交
- **解析策略**：用 `Float(...)` 解析；失败则恢复到当前已提交值
- **编辑体验**：聚焦后显示 draft，避免把 `1.`、`-` 这类中间态立刻回写成格式化结果
- **格式化**：输出会去掉尾随 `0` 和孤立的小数点，例如 `1.50 -> 1.5`，`2.00 -> 2`

## Authoring rules

✅ 应当：
- 在 Inspector 的单值数值字段使用 `NumberField`
- 和 `Row` / `PropertyGrid` 组合成 `X / Y / Z` 三联编辑
- 用 `.small` 放进 24-26pt 高的紧凑行

❌ 不应：
- 把 `NumberField` 当 stepper；它没有增减按钮，也没有滚轮步进
- 指望它做 locale-aware 小数分隔符；当前只接受 `.`

## Known issues / TODO

- 还没有 stepper arrows / drag scrub
- 还没有最小值、最大值、step 约束
- 还没有 locale decimal separator 支持

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| HTML | `input[type=number]` 的提交语义 |
| Unity Inspector | 紧凑数值输入在属性面板中的布局角色 |
| SwiftUI | `TextField(value:format:)` 的数值绑定方向 |

## File map

- 主体: [GuavaUICompose/Primitives/NumberField.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/NumberField.swift)
