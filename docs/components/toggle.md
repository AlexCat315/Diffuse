# Toggle

布尔开关控件。把一个 `Bool` 绑定到 on/off 状态，视觉形态为 switch track + thumb。

## Anatomy

```
┌────────────────────┐
│   ┌────────────┐   │
│   │  track     │   │
│   │ ○      ●   │   │
│   └────────────┘   │
└────────────────────┘
```

- **track**：圆角胶囊背景；off 使用 `surfaceVariant`，on 使用 `accent` ramp
- **thumb**：16pt 圆形把手；on 使用 `onAccent`，off 使用 `surfaceRaised`
- **focus ring**：聚焦时给 thumb 外圈绘制 `focusRing`

## API

```swift
Toggle(isOn: $enabled)
Toggle(isOn: $enabled, isEnabled: false)
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `isOn` | 必填 | `Binding<Bool>` |
| `isEnabled` | `true` | `false` 时禁用交互并使用禁用颜色 |

## Tokens

| 槽位 | off | on |
| ---- | ---- | ---- |
| track | `surfaceVariant` + state layer | `accent` / `accentHover` / `accentPressed` |
| thumb | `surfaceRaised` | `onAccent` |
| border | `border` | `border` |
| focus | `focusRing` | `focusRing` |

## States

| State | 视觉 |
| ----- | ---- |
| rest | off = `surfaceVariant`; on = `accent` |
| hover | off 在 track 上叠 `stateLayerHover`; on = `accentHover` |
| press | off 在 track 上叠 `stateLayerPressed`; on = `accentPressed` |
| focus | thumb 外圈 = `focusRing` |
| disabled | track = `surfaceVariant`; thumb = `surfaceRaised`; cursor = `notAllowed` |

## Behavior

- **指针**：只响应左键；down 进入 pressed，up 时翻转 `isOn`
- **右键 / 中键**：忽略，留给上层容器处理
- **焦点**：host `isFocusable = true`
- **键盘**：`Space` / `Enter` / 小键盘 `Enter` 都会翻转 `isOn`
- **语义共享**：`Checkbox` 与 `Toggle` 共用同一套 bool 激活语义，只是视觉不同

## Authoring rules

✅ 应当：
- 在 `PropertyGrid` 这类已有外部标签的场景直接使用 `Toggle(isOn:)`
- 用 `isEnabled: false` 表达只读布尔状态，而不是手动禁用命中

❌ 不应：
- 把 `Toggle` 当作带内置文本标签的复合行；标签应由上层布局提供
- 继续用 `Button("On" / "Off")` 充当布尔输入

## Known issues / TODO

- 还没有 label slot；当前是纯开关原语
- 还没有 mixed / indeterminate 三态
- 还没有表单级校验或说明文案槽位

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| SwiftUI | `Toggle(isOn:)` 的绑定形态 |
| Fluent UI v9 | switch 的胶囊 track + thumb 语义 |
| Material 3 | on/off 状态的 accent ramp 过渡 |

另见：[checkbox.md](checkbox.md)

## File map

- 主体: [GuavaUICompose/Primitives/Toggle.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Toggle.swift)