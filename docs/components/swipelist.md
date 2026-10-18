# SwipeList

`SwipeList` 是带 trailing 滑动操作的列表。滑动只在触摸面启用；每个行同时提供 44pt Actions 按钮与右键上下文菜单，因此指针、键盘和读屏用户不依赖滑动。

```swift
@State private var selection: Int? = 0

SwipeList(items.indices, id: \.self, selection: $selection,
          rowHeight: 44, rowLabel: { items[$0] },
          actions: { index in
    [
        SwipeAction(id: "archive-\(index)", title: "Archive") { archive(index) },
        SwipeAction(id: "delete-\(index)", title: "Delete", tone: .danger) { delete(index) }
    ]
}, onActivate: { index in open(items[index]) }) { index, selected in
    Text(items[index])
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `data` / `id` | 必填 | 数据与稳定身份 |
| `selection` | `.constant(nil)` | 单选绑定；点击、键盘和辅助功能 activate 都走同一选择路径 |
| `rowHeight` | 36 | 逻辑行高；触摸面提升到 ≥44，字号按 `TextScaler` 缩放 |
| `rowSpacing` | 0 | 行间距，参与缩放 |
| `isEnabled` | true | 关闭时不渲染滑动操作或 Actions 按钮 |
| `rowLabel` | `""` | 行的辅助功能标签 |
| `actions` | 必填 | 每行操作；滑动与 Actions 按钮展示前两个，右键菜单展示全部 |
| `onActivate` | nil | 点击、Return 或辅助功能 activate 时回调 |
| `rowContent` | 必填 | `(element, isSelected) -> View` |

`SwipeAction` 提供 `title`、`tone`（`.danger` 使用 destructive 样式/菜单角色）、`isEnabled` 与 `action`。

## 手势

- **触摸面**：只在 `SurfaceEnvironment.input` 含 `.touch` 时启用。按下先观察、不消费；横向移动 ≥8pt 且大于纵向时夺取指针捕获，内容向逻辑 leading 移动（LTR 左移、RTL 右移），在 trailing 边最多露出两个 74pt 操作；释放按 45% 阈值吸附全开或关闭。Escape 从任一操作按钮焦点关闭，不执行动作。
- **纵向**：行在纵向手势上立即让路，`ScrollView` 接管滚动。`ScrollView` 的触摸拖动阈值改为轴感知（纵向看 `dy`、横向看 `dx`），纵向滚动不会再抢占横向滑动。
- **非触摸**：滑动不响应。行尾 44pt Actions 按钮展开同一组操作；`ContextMenu` 在右键时提供同一组命令。操作按钮为真实 `Button`，打开后进入 Tab 顺序。
- **键盘/读屏**：行选择由外层 `SelectionKeyHost` 处理 Up/Down/Home/End/Return；行语义为 `listItem`，activate 触发选择/`onActivate`。

## 边界

- 当前为全量挂载的非虚拟列表，适合设置、收件箱和播放列表等有界集合；长列表请等待虚拟化版本。
- `.layoutDirection(.rtl)` 同步镜像手势、内容位移、Actions 按钮与操作排列；展开量按逻辑值保存。
- 滑动操作固定展示前两个；更多操作只在 Actions 按钮/上下文菜单中出现。
- 操作按钮基准宽 74pt，随字号缩放并以可用行宽均分夹紧（触摸宽至少 44）；高度取行高，标题单行省略并保留完整语义。

## 验证

- `SwipeListTests.swipeAction`：触摸左滑露出 Archive/Delete，按钮高度 ≥44，释放后无残留指针捕获，执行 Archive 后回调一次。
- `mirroredActions`：LTR/RTL 拒绝反向揭示，正确方向滑动后操作位于逻辑 trailing、100%/200% 字号下宽 74/148、高 ≥44，操作按钮焦点下 Escape 收起且不执行动作，再通过辅助功能入口执行一次。
- `actionsMenu`：点击行尾 Actions 按钮后展开同一组操作，执行 Delete 走同一回调。
- `verticalDrag`：从第 4 行上拖 90pt 滚动列表且不露出操作。
- `pointerDoesNotSwipe`：指针面左滑不响应，Actions 按钮仍可展开操作。
- `disabled`：禁用行不渲染操作按钮。
- Gallery `swipeList` 页与自适应预览；DevTools 720×820 点击 Inbox 的 Actions 后查询到 Archive（74×52）/Delete，执行 Archive 后日志为 “Archived Inbox”。

## File map

- 主体：[SwipeList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/SwipeList.swift)
- 滚动手势：[ScrollView.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/ScrollView.swift)
- 测试：[SwipeListTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/SwipeListTests.swift)
