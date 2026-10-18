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
- **title**：可换行的强调文本，完整语义进入 label
- **message**：可换行的说明
- **actions**：可选真实按钮组，窄宽或字号预算不足时堆叠
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
Alert("Import failed", message: "The format is unsupported.", tone: .danger) {
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
| `tone` | `.info` | neutral / success / warning / danger / info |
| `variant` | `.soft` | 见上表 |
| `icon` / `showsIcon` | tone 图标 / `true` | 覆盖或隐藏图标 |
| `onDismiss` | `nil` | 设置后显示关闭按钮 |

## Sizing / Tokens

- 内边距 `theme.spacing.md`，图标与文本间距 `sm`，圆角 `theme.radius.md`。
- 图标槽与图标共用 IconMetrics，尊重主题/局部缩放覆盖；垂直行盒至少容纳图标和随字号缩放的 `bodyStrong` 第一行。正文与操作组复用同一逻辑 leading 缩进，RTL 镜像。关闭按钮仅占标题行，不挤占正文和操作区。
- 标题 `bodyStrong`，正文 `body`；正文可为空。卡片最大宽度为宿主 viewport − 32，嵌入较窄容器时继续按容器收缩。
- `.soft` 使用 `surfaceRaised` 与 `border`；`.filled` 使用 tone 与 `tone.ink(onSolid:)`。
- 操作使用真实 Button，触摸面遵守 44pt 下限；compact 纵向堆叠，其他表面按实际可用宽度和按钮自然宽度自动选择同行或堆叠。按钮顺序、节点与焦点保持，间距 8pt；关闭按钮为 ghost icon button。

## Behavior

- 非阻塞：Alert 自身不创建 modal scope，不抢焦点，不改变背景输入。
- 辅助功能 role=`status`，label 为 title，help 为 message；图标装饰不重复朗读。
- 关闭按钮的激活只调用 `onDismiss`，不改变页面其他状态。
- 动态文案按实际宽度换行，不缩字号；窄容器下标题、正文与操作始终共享同一条 leading edge。
- `showsIcon = false` 时文本缩进归零，标题直接贴齐卡片内边距。

## Verification

- Gallery `alert` 页展示 success / warning / error / info 四张默认 `.soft` Alert。
- DevTools 1000×760：查询到四项 `status`；`Project saved` 与 `All changes are available…` 的 staticText 均为 `x = 323`，`capture-ui` 确认图标居中于标题行、正文同边。
- `ProductComponentTests.alertTextAlignment` 断言 title 与 message 的 `absoluteFrame.minX` 相等，防止只改视觉 padding 的回归。
- `AlertAdaptiveTests`：三档宽度、100%/200%、LTR/RTL、明暗主题与三种 variant，覆盖标题/正文同边、动作边界、44pt 下限、完整 status 语义；720→320→720 保留同一动作节点/焦点并验证键盘重连与关闭回调。
- Gallery 新增 Actions & dismissal，提供长文案、重连、离线、关闭与重新显示；DevTools 实际验收见规范第 5 节。

## File map

- 主体：[Alert.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Feedback/Alert.swift)
- 共用操作布局：[ActionGroup.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Responsive/ActionGroup.swift)
- Gallery：[FeedbackStories.swift](../../GuavaUI/Examples/Sources/GalleryContent/Stories/Feedback/FeedbackStories.swift)
