# Refreshable List

`List` 与 `VirtualStack` 通过 `RefreshOptions` 提供下拉刷新。调用方拥有异步工作与 `isRefreshing` 生命周期；组件负责触摸阈值、指示器和 Cmd+R 入口。

```swift
@State private var isRefreshing = false

List(items, id: \.self, selection: $selection,
     refresh: RefreshOptions(isRefreshing: $isRefreshing, threshold: 64) {
    isRefreshing = true
    Task {
        await reload()
        isRefreshing = false
    }
}) { item, selected in
    Text(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `isRefreshing` | 必填 | 调用方维护；为 true 时显示指示器并预留 36pt top inset，清除后回弹 |
| `threshold` | 64 | 触摸下拉触发阈值，最小 24pt；实际位移含 `ScrollView` 阻尼 |
| `action` | 必填 | 越过阈值时只调用一次；Cmd+R/Ctrl+R 也调用它 |

## 行为

- **触摸下拉**：`ScrollView` 在顶部产生负向 overscroll 时，`VirtualStack` 读取真实 offset；越过阈值后置位 armed 并调用一次 `action`，直到内容回到顶部才重新 arm。指示器位于滚动内容顶部，根据 pull 距离显示 “Release to refresh”，刷新中显示 “Refreshing”。
- **完成回弹**：`isRefreshing` 为 true 时内容顶部预留 36pt inset，指示器落在 inset 内；binding 清除后 inset 与指示器移除，`ScrollView` 自然回弹。
- **减少动态**：指示器复用 `Spinner`，`reducedMotion` 下冻结为静态环，仍表达忙碌状态。
- **键盘/命令**：列表子树内的 Cmd+R（macOS）或 Ctrl+R 调用同一 action；`isRefreshing` 为 true 时忽略重复按键。指针用户可由调用方放一个显式刷新按钮，Gallery 示例即如此。
- **宽度**：指示器作为滚动内容中的绝对定位子节点，不包裹 `ScrollView`；列表在 stretch 宿主中仍保持完整宽度（Gallery 720 例为 548pt，保留 12pt 滚动条槽）。

## 边界

- 只有 `List`/`VirtualStack` 暴露 `refresh`；`Table`/`DataTable` 若需要刷新，应通过其内部 List 或外层命令接入。
- `action` 是同步入口；异步生命周期由调用方写入 `isRefreshing`，组件不持有 Task。
- 下拉手势依赖触摸拖动；DevTools 的 pointer 输入不会产生 overscroll，触摸路径由单元测试覆盖。
- 指示器覆盖在滚动内容顶部；刷新中通过 36pt inset 让出空间，没有额外的下拉阻尼动画。

## 验证

- `RefreshTests.pull`：触摸下拉越过 64pt 只触发一次，`isRefreshing` 为 true 时指示器保持，清除后指示器移除。
- `RefreshTests.keyboard`：聚焦 ScrollView 后 Cmd+R 触发一次，重复 Cmd+R 在刷新中不再触发。
- Gallery `refreshableList` 页：显式 Refresh now、计数文本与 6 行列表；DevTools 720×820 点击后查询到 `Refreshing`，计数 `Refreshes: 1`，3 秒后指示器消失；列表行宽 548pt。
- `ScrollViewInputTests` 与 List/SectionedList/SwipeList/ReorderableList 套件回归通过。

## File map

- 选项与指示器：[Refresh.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Refresh.swift)
- 列表接入：[List.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/List.swift) · [VirtualStack.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/VirtualStack.swift)
- 测试：[RefreshTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/RefreshTests.swift)
