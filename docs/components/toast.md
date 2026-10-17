# Toast / Notification

窗口级、非阻塞的短反馈。Toast 用稳定 ID 复用同一个通知槽位，支持队列、自动过期、悬停暂停、内联操作和窗口边缘定位。

## Anatomy

```
┌─────────────────────────────────────┐
│ Project saved · 3               ×   │
│ Your changes are available.         │
│ [Undo] [Retry]                      │
└─────────────────────────────────────┘
```

- **host**：窗口级；`NotificationHost` 挂一次，所有通知通过 `ToastController` 进入同一队列
- **card**：标题、正文、最多两个内联操作、可选关闭按钮
- **queue**：`maxVisible` 控制同屏卡片数，其余排队
- **anchor**：窗口四角之一；`.automatic` 在 compact 表面使用底部，其余使用右上

## API

```swift
let center = ToastController(maxVisible: 3)
center.post(ToastNotification("Project saved", id: "save") {
    $0.tone = .success
    $0.message = "Your changes are available."
    $0.duration = nil
    $0.actions = [
        ToastAction("Undo") { restore() },
        ToastAction("Retry") { retry() },
    ]
})

NotificationHost(center, width: 360, position: .automatic)
```

| 类型 | 参数 | 默认值 | 说明 |
| ---- | ---- | ---- | ---- |
| `ToastNotification` | `title` | 必填 | 单行标题，完整文本进入语义 |
| | `id` | UUID | 稳定 ID；同 ID 的 `post` 替换旧通知 |
| | `message` | `""` | 正文，可换行 |
| | `tone` | `.info` | `StatusTone` 语义色 |
| | `duration` | `5` | 秒；`nil` 表示直到手动关闭 |
| | `isDismissible` | `true` | 是否显示关闭按钮 |
| | `actions` | `[]` | 最多渲染两个 |
| `ToastAction` | `title` | 必填 | 按钮文本 |
| | `role` | `.normal` | `ButtonRole` |
| | `dismissesNotification` | `true` | 执行后是否关闭所在通知 |
| `NotificationHost` | `controller` | 必填 | 队列所有者 |
| | `width` | `360` | 卡片宽度；夹紧到窗口 − 32 |
| | `position` | `.automatic` | `topLeading` / `topTrailing` / `bottomLeading` / `bottomTrailing` |

`ToastController` 的 `notifications`、`queuedCount`、`post`、`dismiss`、`setPaused`、`advance(by:)`、`clear` 都是窗口/应用级状态；组件本身不持有队列。

## Sizing

- 卡片宽度默认 360pt，最小 120pt，窗口两侧各留 16pt；标题/正文单行或自然换行。
- 卡片 padding 14pt，队列间距 10pt；正文与操作行间距 5pt。
- 操作按钮使用真实 `Button`，触摸面继续遵守 44pt 下限；桌面使用 small control size。
- 关闭按钮是独立 ghost icon button，尺寸 12pt 图标 + 完整命中区。
- `.automatic`：`compact` 表面底部、`medium`/`expanded` 右上；底部位置按宿主 `safeArea.bottom` 预留，顶部按 `safeArea.top` 预留。

## Tokens

| 槽位 | 来源 |
| ---- | ---- |
| 卡片背景 | `theme.colors.surfaceFloating` |
| 边框 | `theme.colors.border` |
| 标题色 | `tone.color` |
| 正文色 | `theme.colors.onSurfaceVariant` |
| 圆角 | `theme.radius.controlRadius` |
| 字体 | `bodyStrong` / `body` |
| 间距 | `theme.spacing` 等价值（当前使用 14/10/8/5） |

## States

| 状态 | 行为 |
| ---- | ---- |
| 显示 | 进入队列；同一 ID 替换原槽位 |
| hover | `setPaused(true)`，到期暂停；移出恢复 |
| 操作 hover/press/focus | 由 `Button` 的 ghost 样式提供 |
| 操作激活 | 调用 action；`dismissesNotification` 为真时关闭通知 |
| 到期 | `duration` 归零后移除；暂停时不减时 |
| 关闭 | 关闭按钮或 `dismiss(id)`；同一 ID 可再次 post |
| 队列满 | 新通知排队，`queuedCount` 增加；可见项关闭后前移 |

## Behavior

- **队列**：`maxVisible` 至少 1；同 ID 替换保留位置，不重复入队。
- **时间**：由 `ToastClock` 资源按帧推进，测试可用 `advance(by:)` 确定性驱动。
- **操作**：最多两个；action 是普通按钮，键盘可达，语义名称即标题。
- **定位**：Portal 在窗口内夹紧；`.automatic` 由 `WidthClassReader` 按实际表面宽度决定，不看平台。
- **安全区**：底部锚点把 `safeArea.bottom` 计入内容 padding，顶部锚点使用 `safeArea.top`；不读取平台 API。
- **焦点**：Toast 不抢焦点；操作按钮只在用户 Tab 进入后获得焦点。
- **减少动画**：未新增进出动画，因此不受 `reducesMotion` 影响；后续若加入进出动画必须遵守该开关。

## Authoring rules

- 一个窗口只挂一个 `NotificationHost`；不要在每页重复挂载。
- 用稳定 ID 表示可替换的进度/状态；一次性消息可以省略 ID。
- 最多两个操作；撤销/重试优先，阻塞式确认用 Dialog，不用 Toast。
- 正文保持短句；长内容由调用方截断或改用 Alert/Dialog。
- 不要把 Toast 当作错误详情页；错误应保留可访问的日志或 Dialog。
- 触摸面不要依赖 hover 才能发现操作；操作按钮始终可见。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/ProductComponentTests.swift`）：

- `toastPositionResolution`：compact → 底部，medium/expanded → 右上；leading/trailing 原点。
- `toastActionPointer`：真实指针命中 action，调用一次并默认关闭通知。
- `toastActionKeyboard`：Tab 聚焦 action 后 Return 激活，`dismissesNotification: false` 时保留通知。
- `notificationQueue` / `transientResourceLifecycle`：队列、替换、暂停、时钟与 Portal 生命周期。

真实 app 闭环（DevTools）：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component notification --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'
guava-dev devtools input-ui 9229 --click-node <Toast with undo>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Undo / Retry / Dismiss
guava-dev devtools input-ui 9229 --click-node <Undo>
guava-dev devtools capture-ui 9229 /tmp/guava-toast-action.jpg
```

Gallery `notification` 页提供 Notify、Toast with undo、Replace status、Persistent warning、Clear 和位置选择，操作后可直接用 DevTools 查询/截图复核。

## References

- Material 3 Snackbar / SnackbarAction
- Flutter `SnackBar` / `SnackBarAction`
- SwiftUI 自定义 overlay + `.presentationDetents`（Toast 无系统内置）
