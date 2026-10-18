# Alert

页面内联的状态反馈卡。用于说明结果、错误与下一步操作，不承担阻塞式确认；需要阻塞时使用 `AlertDialog`。

## Anatomy

```
┌──────────────────────────────────────┐
│  ✓  Project saved                    │
│     All changes are available.       │
└──────────────────────────────────────┘
```

- **icon**：tone 对应的状态图标，默认显示
- **title**：单行强调文本，完整语义进入 label
- **message**：可换行的说明
- **actions**：可选的真实按钮行
- **dismiss**：可选 trailing ghost 关闭按钮

## Variants

| Variant | 视觉 | 用途 |
| ------- | ---- | ---- |
| `.soft`（默认） | iOS 中性 grouped surface + 细边框，tone 只用于图标 | 页面内普通状态反馈 |
| `.outline` | 透明底 + tone hairline + 中性标题/tone 图标 | 已有卡片内部的轻量提示 |
| `.filled` | tone 实底 + 对比 ink | 唯一、阻塞级的重要消息 |

`.soft` 不使用整块 pastel tonal 填充；标题和正文保持普通文本对比度，避免多张 Alert 同时出现时页面被色块切割。

## API

```swift
Alert("Project saved", message: "All changes are available.", tone: .success) {}
Alert("Import failed", message: "The format is unsupported.", tone: .error) {
    $0.variant = .outline
    $0.onDismiss = { hide() }
} actions: {
    Button("Choose another file") { pick() }.buttonStyle(.secondary)
}
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `title` | 必填 | 状态标题 |
| `message` | `""` | 说明文本 |
| `tone` | `.info` | success / warning / error / info |
| `variant` | `.soft` | 见上表 |
| `icon` / `showsIcon` | tone 图标 / `true` | 覆盖或隐藏图标 |
| `onDismiss` | `nil` | 设置后显示关闭按钮 |

## Sizing / Tokens

- 内边距 `theme.spacing.md`，图标与文本间距 `sm`，圆角 `theme.radius.md`。
- 标题 `bodyStrong`，正文 `body`；正文可为空。
- `.soft` 使用 `surfaceRaised` 与 `border`；`.filled` 使用 tone 与 `tone.ink(onSolid:)`。
- 操作行使用真实 Button，触摸面遵守 44pt 下限；关闭按钮为 ghost icon button。

## Behavior

- 非阻塞：Alert 自身不创建 modal scope，不抢焦点，不改变背景输入。
- 辅助功能 role=`status`，label 为 title，help 为 message；图标装饰不重复朗读。
- 关闭按钮的激活只调用 `onDismiss`，不改变页面其他状态。
- 动态文案按实际宽度换行，不缩字号；窄容器下图标与文本保持顶部对齐。

## Verification

- Gallery `alert` 页展示 success / warning / error / info 四张默认 `.soft` Alert。
- DevTools 1000×760：查询到四项 `status`，`capture-ui` 确认中性卡片、tone 图标与正文对比度。
- 操作按钮和 dismiss 由 Gallery 其它状态页覆盖；`.filled` / `.outline` 由调用方按需取样。

## File map

- 主体：[Alert.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Feedback/Alert.swift)
- Gallery：[FeedbackStories.swift](../../GuavaUI/Examples/Sources/GalleryContent/Stories/Feedback/FeedbackStories.swift)
