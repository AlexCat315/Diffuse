# NavigationStack

`NavigationStack` 是 session 持有的页面栈。调用方拥有 `[Route]` 路径：追加 route 入栈、移除最后一个出栈；非空初始 path 在首帧恢复深链。

```swift
@State private var path: [Route] = []

NavigationStack(path: $path) {
    WorkspaceRoot() // put .navigationTitle("Workspace") on the page heading
} destination: { route in
    DetailPage(route: route)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `path` | 必填 | `[Route]` binding；约定 `append` 入栈、`removeLast` 出栈 |
| `transitionDistance` | 32 | push/pop 的水平位移，逻辑点 |
| `root` | 必填 | 栈底页面 |
| `destination` | 必填 | 每个 route 的页面 |

## 行为

- **状态保留**：root 与当前 path 中的页面保持挂载；隐藏页停止绘制、命中、焦点与辅助功能暴露，但 `@State`、草稿、滚动和节点身份保留。`AnimatedVisibility(retainsContent: true)` 负责该切换。
- **push**：新页从 trailing 滑入并淡入；旧顶页向 leading 滑出。页动画使用 `Transition.navigation(distance:forward:)`；`reducedMotion` 时直接吸附终态。
- **pop**：新顶页（已在栈内挂载）以反向 move+opacity 显露；被弹出的页面立即卸载。这样不必保留已经离开栈的页面内容。
- **深链**：初始化 `NavigationStack` 时 path 已经非空即可直接显示最后一页，无需先安装 root 再导航。
- **尺寸**：`ContainerSizeReader` 测量实际容器并将页面固定到该尺寸；页面背景为 `theme.colors.background`，避免下层页透出。
- **标题焦点**：页面标题加 `.navigationTitle("Details")`；新顶页完成布局后，栈把焦点移到该 heading，`visible: false`，因此不出现键盘焦点环。pop 回上一页同样恢复其标题焦点。未标记标题的页面保持调用方自己的焦点策略。
- **过渡去重**：一次 path 变化启动过渡后，在动画 settle 前的第二次 path 变化会被拒绝，path 写回上一次接受的 routes；settle 后恢复接受。这样快速双击不会重复入栈，代价是过渡期间的合法连续导航需要等待。
- **宿主返回**：Android 系统返回 / iOS 边缘手势由宿主处理，宿主删除最后一个 route；组件不消费 Escape，浮层仍优先。

## 边界

- 平台返回手势不内建；宿主删除最后一个 route。未使用 `.navigationTitle` 的页面不会自动获得标题焦点。
- 所有路径页面保持挂载，极深栈会保留全部页面节点；需要淘汰时由调用方管理 route 生命周期。
- push 的旧页滑出与 pop 的新页显露使用非对称过渡；被弹出页面本身不做退出动画。

## 验证

- `NavigationStackTests`：push/pop 后 root 状态保留且只有顶层页面进入辅助功能树；非空初始 path 深链；多页栈只保留最后一页可交互；`titleFocus` 验证 push/pop 后 heading 获得焦点且无可见环；`transitionGuard` 验证动画中的第二次 path 变化被回退。
- Gallery `navigationStack` 页：root 草稿、两个 push 入口、Back 与当前 path 文本；自适应预览覆盖 390/720 触摸/指针档。
- DevTools 实测（720×820）：点击 `Open details` 后 `query_ui_nodes` 返回 `Details` 的 `role=heading` 与 `Path: details`，顶层页几何铺满 560×260 容器；点击 Back 后 root 草稿仍为 “Draft kept across push and pop”。

## File map

- 主体：[NavigationStack.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Navigation/NavigationStack.swift)
- 过渡：[Transition.swift](../../GuavaUI/Sources/GuavaUICompose/Animation/Transition.swift) · [AnimatedVisibility.swift](../../GuavaUI/Sources/GuavaUICompose/Animation/AnimatedVisibility.swift)
