# TextField

文本输入。默认单行；传 `axis: .vertical` 时支持显式多行输入。

## Anatomy

```
┌──────────────────────────────────┐  ← chrome (surfaceVariant + radius.sm + clipsToBounds)
│  ┊                            ┊  │
│  ┊  text or placeholder       ┊  │  ← vertically centered, left-aligned
│  ┊  cursor│                   ┊  │
│  ┊                            ┊  │
└──┊──────────────────────────────┊┘
    ↑                            ↑
   spacing.sm inset (left + right)
```

| 槽位 | 默认值 | Token |
| ---- | ------ | ----- |
| chrome.height | 32 | 硬编码 |
| chrome.cornerRadius | `theme.radius.sm` | 4 |
| chrome.background | `theme.colors.surfaceVariant` | 每次 `_updateNode` 重算（响应主题切换） |
| inner inset (left + right) | `theme.spacing.sm` | 8 |
| label.font | `body` | 14pt 400 |
| placeholder.color | `onSurfaceMuted` | — |
| text.color | `onSurface` | 调用方可经 `textColor:` 覆盖 |
| cursor.color | `onSurface` | — |
| selection.color | `theme.colors.selection` | — |
| `clipsToBounds` | `true` | 防文本溢出框外 |
| cursor (mouse) | `.ibeam` | — |

## States

| State | 视觉 | 触发 |
| ----- | ---- | ---- |
| empty rest | placeholder + chrome | 没有文本、没有焦点 |
| focused empty | placeholder + 闪烁光标 | 有焦点、没有文本 |
| focused with text | 文本 + 闪烁光标 | 有焦点、有文本 |
| selecting | 选区 `selection` 色块 + 抑制光标 | 拖选中 |
| composing (IME) | 预编辑文本 + 下划线 1px | IME 在合成 |

无 disabled 视觉变体 ——（v1 限制）想要禁用，外层 `.opacity(0.5)` + 不绑 binding。

## Behavior

- **指针**：单击放置光标（按字符中线判定）；拖动延伸选区；双击选词；三击全选（命中 SDL3 的 `event.clicks`）。
- **键盘**：方向键 / Home / End / Shift 配合扩展选区，Cmd/Ctrl + A/C/V/X 标准编辑。
- **IME**：`textEditing` 事件写入 `compositionText` + 下划线指示，`textInput` 提交并清空合成区。
- **Enter**：单行模式触发 `onSubmit?()`；垂直轴模式插入换行。垂直轴若绑定了 `onSubmit`，使用 Cmd/Ctrl + Enter 提交。
- **TextInputArea**（候选窗定位）：发布到 `node.attachments[TextInputAttachmentKey.area]`，y 位于文本基线行（不是 chrome 顶部）。
- **State 持久化**：`FieldState`（光标 / 选区 / IME）挂在 `node.attachments`，跨 recompose 存活。

## Authoring rules

✅ 应当：

- `TextField("Search…", text: $text)` —— 默认 chrome 已经是 light/dark 主题安全的
- 多行输入优先用 `TextField("Notes…", text: $text, axis: .vertical)`，不要自己拦截回车再手拼 `"\n"`
- 想自定义 chrome 时：`TextField(...).frame(width:140)`（保留默认 chrome）或外层包 background + 自己写 padding（少见）
- 用 `onSubmit:` 处理 Enter 提交，不要监听 key 事件

❌ 不应：

- 给 TextField 加 `.padding(...)` —— 会把 chrome 当文本框，inset 会变成 padding 加 inset 双重
- 给 TextField 加 `.frame(height:)` 强行改高 —— 32pt 是当前定值，要改请去改 token
- 把 TextField 用作只读文本展示（请用 `Text`）
- 在 `_updateNode` 内做 "if backgroundColor == nil" 守卫缓存 token —— 主题切换时不会更新

## Known limitations (v1)

- 垂直轴模式目前只处理显式换行，不做软换行；超长单行内容仍会水平裁剪
- 没有 placeholder 上浮 / floating-label
- 没有 disabled / readonly 显式状态
- 没有 leading / trailing icon 槽位 —— 调用方需要外层 Row 自己拼

## References

| 设计系统 | 对应组件 | 借鉴点 |
| -------- | -------- | ------ |
| Material 3 | TextField (filled / outlined) | filled 模式的 surfaceVariant 填充 |
| Fluent UI v9 | Input | 8px 横向 inset、垂直居中 |
| Radix Primitives | TextField.Root + TextField.Input | 单行 + 简单字段的最小契约 |
| Flutter Material | TextFormField | onSubmit 命名、IME 集成思路 |
| SwiftUI | TextField | 调用形态 `TextField("placeholder", text:)` |

## File map

- 主体: [GuavaUICompose/Primitives/TextField.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/TextField.swift)
- Style 协议（Phase 7.5）: [GuavaUICompose/Theme/TextFieldStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/TextFieldStyle.swift)
- 默认 style: [GuavaUICompose/Theme/DefaultTextFieldStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultTextFieldStyle.swift)
