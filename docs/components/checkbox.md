# Checkbox

离散布尔输入。把一个 `Bool` 绑定到勾选 / 未勾选状态，视觉形态为方框 + 勾线。

## Anatomy

```
┌──────────────┐
│ ┌──────────┐ │
│ │  ┌────┐  │ │
│ │  │ ✓  │  │ │
│ │  └────┘  │ │
│ └──────────┘ │
└──────────────┘
```

- **box**：18pt 方框，off 使用 `surfaceVariant`，on 使用 `accent` ramp
- **check**：两段线组成的勾，on 时使用 `onAccent`
- **focus ring**：聚焦时给 box 外圈绘制 `focusRing`

## API

```swift
Checkbox(isOn: $enabled)
Checkbox(isOn: $enabled, isEnabled: false)
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `isOn` | 必填 | `Binding<Bool>` |
| `isEnabled` | `true` | `false` 时禁用交互并使用禁用颜色 |

## Tokens

| 槽位 | off | on |
| ---- | ---- | ---- |
| fill | `surfaceVariant` + state layer | `accent` / `accentHover` / `accentPressed` |
| check | 无 | `onAccent` |
| border | `border` | `border` |
| focus | `focusRing` | `focusRing` |

## States

| State | 视觉 |
| ----- | ---- |
| rest | off = `surfaceVariant`; on = `accent` |
| hover | off 在 box 上叠 `stateLayerHover`; on = `accentHover` |
| press | off 在 box 上叠 `stateLayerPressed`; on = `accentPressed` |
| focus | box 外圈 = `focusRing` |
| disabled | fill = `surfaceVariant`; check = `onSurfaceMuted`; cursor = `notAllowed` |

## Behavior

- **指针**：只响应左键；down 进入 pressed，up 时翻转 `isOn`
- **键盘**：`Space` / `Enter` / 小键盘 `Enter` 都会翻转 `isOn`
- **焦点**：host `isFocusable = true`
- **语义共享**：与 `Toggle` 共用同一套 bool 激活逻辑

## Authoring rules

✅ 应当：
- 在表格、列表、批量选择这类离散布尔场景使用 `Checkbox`
- 在 Inspector 的紧凑布尔行里优先用 `Checkbox`，如果视觉上不需要开关轨道

❌ 不应：
- 把 `Checkbox` 当三态控件使用；当前只有 true / false
- 用 `Button("Yes" / "No")` 伪装勾选框

## Known issues / TODO

- 还没有 indeterminate 三态
- 还没有 label slot；标签仍由上层布局提供

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| HTML | `input[type=checkbox]` 的离散布尔语义 |
| Fluent UI v9 | 方框 + 勾线的简洁 geometry |
| Radix UI | checkbox 与 label 解耦的组合方式 |

## File map

- 主体: [GuavaUICompose/Primitives/Toggle.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Toggle.swift)
