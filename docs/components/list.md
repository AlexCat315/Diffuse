| Fluent UI v9 | 单选 / 多选为同一 List 的模式（GuavaUI 按 binding 类型选择） |# List / ListRow

垂直列表，固定行高并按可见区域虚拟化。`List` 按 selection binding 的类型选择模式：`Binding<ID?>` 为单选，`Binding<Set<ID>>` 为多选（Shift 区间、Cmd/Ctrl 切换、键盘扩展、Space 切换与全选），与 SwiftUI `List(selection:)` 一致。行视觉（选区填充、padding、字体）走 `ListRowStyle`。

## Anatomy

```
┌──────────────────────────────────┐
│  ┌────────────────────────────┐  │ ← row[0] (rowHeight)
│  │  rowContent(item, isSel)   │  │
│  └────────────────────────────┘  │
│       ↕ rowSpacing               │
│  ┌────────────────────────────┐  │ ← row[1]
│  │  rowContent(item, isSel)   │  │
│  └────────────────────────────┘  │
│  …                                │
└──────────────────────────────────┘
            ↑ ScrollView(.vertical) outer
```

## API

```swift
List(items, id: \.id, selection: $selectedID, rowHeight: 30, rowSpacing: 0) { item, isSelected in
    ListRow(item.title) {
        if isSelected { Badge("Selected", tone: .info) }
    }
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `selection` | `.constant(nil)` | 单选 binding，nil 表示未选 |
| `rowHeight` | 30 | 未缩放逻辑行高，组件自动应用 `TextScaler` 与触摸下限 |
| `rowSpacing` | 0 | 未缩放行间隙，组件自动应用 `TextScaler` |

## ListRow：标题与前后槽位

`ListRow` 是可选的通用单行内容，供 `List`（单选/多选）与 `SectionedList` 共用；列表仍接受任意自定义 View。它继承外层字体与颜色，不决定选择状态或行高。

```swift
ListRow(item.title, leading: {
    Icon(UIIcons.File.fileText, size: .medium, color: .onSurfaceMuted).accessibilityHidden()
}, trailing: {
    Badge(item.status, tone: .info)
})
// 仅标题：ListRow(item.title)
// 仅尾槽：ListRow(item.title) { Badge(item.status, tone: .info) }
```

- 前后槽保留其自然宽度；标题取得剩余宽度、单行尾部省略。非空槽与标题间距 8pt，空槽不占间距。条件徽标出现/消失不会让标题消失或替换其节点。
- 默认行样式把内容约束在可用宽度内；RTL 按逻辑 leading/title/trailing 反向排列。前后槽不随标题一起裁切。
- 极窄宽度或 200% 字号下，固定槽已占满整行时保留一个随字号缩放的 24pt 标题窗口，并允许横向滚动。嵌套滚动不增加静止行的 Tab 停靠；溢出时提供辅助功能滚动操作，LTR/RTL 都可到达全部内容。
- 标题的完整值保留在辅助功能名称及截断 tooltip。触摸面应同时在详情或选中状态区展示完整值；Gallery 通过选中行下方的状态文本提供此入口。
- 尾槽可放独立按钮；其点击优先于行选择，不把操作误判为选行。复杂多行内容仍由调用方自行布局和预算行高。

## 多选

传入 `Set` binding 即为多选，没有单独的多选组件：

```swift
@State private var selection: Set<Item.ID> = []

List(items, id: \.id, selection: $selection,
     onActivate: { open($0) }) { item, isSelected in
    ListRow(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `selection` | 必填 | 稳定 ID 集合 binding；单选形式默认 `.constant(nil)` |
| `rowHeight` | 30 | 与 List 同一条缩放/触摸规则 |
| `rowSpacing` | 0 | 与 List 同一条缩放规则 |
| `onActivate` | nil | Return 或行点击后的激活回调 |

- 普通点击：`selection = [id]`，并记录 anchor/cursor。
- Shift-click：从 anchor 到当前行按数据顺序取闭区间；anchor 由最近一次点击/键盘选择维护。
- Cmd/Ctrl-click：切换单行，不清空其他行。
- Shift+Arrow：从 anchor 扩展到新 cursor；普通 Arrow：只选新行并移动 anchor。
- Cmd/Ctrl+A：全选；Cmd/Ctrl 点击已选行可取消。
- Space：切换 cursor 行；Return：激活 cursor 行。
- 行节点 role=listItem、selected 态由集合 membership 决定；列表本身仍是唯一键盘 host/Tab 停靠。
- 视觉、虚拟化、滚动与 List 完全共用 `_ListRowHost`/`VirtualStack`/`ListRowStyle`。

## SectionedList

```swift
SectionedList([
    ListSection("favorites", title: "Favorites", items: favorites),
    ListSection("scene", title: "Scene", footer: "3 objects", items: scene),
], selection: $selectedID, stickyHeaders: true,
   onActivate: { open($0) }) { item, isSelected in
    ListRow(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `sections` | 必填 | `[ListSection<SectionID, Item>]` |
| `selection` | `.constant(nil)` | 单选 `Item.ID?` binding |
| `rowHeight` | 30 | 区段内 item 行高；header/footer 同高 |
| `rowSpacing` | 0 | 行间距；同时作用于 header/footer |
| `stickyHeaders` | false | 滚动时固定当前区段标题，由下一标题上推 |
| `stickyHeaderBackground` | `.surfaceRaised` | 固定标题的不透明底色；列表位于其他表面时传入对应 token |
| `onActivate` | nil | Return/点击后的激活 |

- 区段按传入顺序平铺；`title`/`footer` 为空时不生成对应行。
- header/footer role=staticText，不进入焦点顺序、不参与键盘选择。
- 方向键/Home/End 只在 item 行之间移动，跨区段时跳过 header/footer。
- 普通点击/Return 复用 `_ListRowHost` 与 `ListRowStyle`；`scrollToIndex` 跟随 cursor。
- `stickyHeaders` 打开后，当前区段标题固定在视口顶部；下一区段标题接近时把它向上推出。
  固定副本只负责绘制，不进入焦点、不接收指针、不重复暴露语义；原 header 行仍是唯一语义来源。
  列表自身裁剪，推出的标题不会覆盖列表上方的页面内容；固定条覆盖行内容区并保留右侧 12pt 稳定
  滚动条槽，底部 1pt 分隔线与半露行分开且不改变行高。
- header 标题单行省略，完整标题保留在辅助功能 label；footer 是平面文本，不支持独立交互内容。
- 行高统一为 `rowHeight`（触摸 44）；section header 不再单独用 28pt，以保证虚拟化行高一致。
- 虚拟化使用 `VirtualStack`；`ListSection` 与 item 数据应稳定，避免每次 body 重新构造大量临时值。
- 固定标题默认按列表常见所在的高一层面板取 `.surfaceRaised`；放在 `surface` 或自定义卡片上时，
  把 `stickyHeaderBackground` 设为该表面的颜色 token，避免出现色带。

## ReorderableList

```swift
ReorderableList(items, id: \.id, rowLabel: { $0.title }, onMove: { from, to in
    let moved = items.remove(at: from)
    items.insert(moved, at: to)
}) { item, isDragging in
    Row { Text(item.title); Spacer() }
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `data` / `id` | 必填 | 调用方持有的顺序与稳定 ID |
| `rowHeight` | 36 | 未缩放行高；触摸面提升到 44 |
| `rowSpacing` | 0 | 未缩放行距 |
| `isEnabled` | true | 关闭后 handle 不接指针、不参与焦点 |
| `rowLabel` | 空 | handle 的辅助功能名称来源；为空时用 “Reorder item N” |
| `onMove` | 必填 | `(from, to)`，`to` 是移除后的最终索引 |
| `rowContent` | 必填 | `(item, isDragging)`；拖动中的行可自行弱化/高亮 |

- 每行尾部有 44pt 宽拖拽 handle（`UIIcons.Action.grip`）。指针拖动期间在目标边界绘制 2pt accent 放置线；释放才调用一次 `onMove`，Escape 取消且不改顺序。
- 键盘聚焦 handle 后 Up/Down 立即上移/下移；辅助功能为 slider 语义，value 为 `"Position x of n"`，increment/decrement 映射同一操作。
- 行身份由 `id` 保留，移动后焦点、草稿与行内容节点跟随原行。
- 拖动时被拖行浮起为一份副本（同一 rowContent，`dragging = true`，surface 底、accent 细边与中等阴影、带把手），跟随指针移动并限制在视口内，自动滚动时停在边缘，内容在其下方滚动；原位置保留为 35% 不透明度的占位，滚出视口后仍能看到正在移动的项。预览不参与布局与命中，移动只改宿主的绘制偏移，不重组列表或重新布局。
- 拖动时指针进入视口上下边缘 48pt（视口高度的 1/4 以内）区域，列表按深度平方加速自动滚动，最高 1200pt/s；指针停在边缘或移出视口也会持续滚动。放置位置按“指针位移 + 自动滚动距离”在内容坐标中计算，放置线随内容移动；松开、Escape 或卸载立即停止。滚动通过内部 `EnclosingScroll` 直接调整最近的外层 ScrollView 偏移，不重组列表；同一 `EdgeAutoScroll` 可供其他拖动源复用。
- 只挂载视口及上下各 4 行余量（行绝对定位于 `index × (行高 + 间距)`）；正在拖拽的行与最近一次键盘移动的行即使滚出视口也保持挂载，保证指针捕获与焦点不丢失。`VirtualizationEstimateTests.reorderWindow` 验证 1,000 行只构建窗口内的行，键盘移动照常回调。
- 为列表本身提供有界高度，无需再套一层同向 ScrollView；当前重排行仍使用固定行高，不会自动使用 VirtualStack 的未知行高估测。离开挂载窗口的普通行会卸载，需长期保留的草稿由调用方模型持有。

## Tokens (DefaultListRowStyle)

选中态不在这张表里各自推导：`SelectionAppearance.resolve(.navigation, theme:)` 是唯一的
“这一行被选中了”的定义，Sidebar 目的地和 List 行共用同一个 role。行 style 只决定
role，不自己从原始颜色拼填充和圆角。

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| 选中 / hover / press 填充 | `SelectionAppearance.resolve(.navigation, …)` | theme |
| 选中圆角 | `theme.radius.md` | theme |
| 选中内缩 | horizontal `theme.spacing.sm`，vertical `theme.spacing.xs` | theme |
| 行高 | `rowHeight`；style 在其中居中内容，超出即裁切 | 调用方 |
| 文本颜色 | `onSurface` | theme |

hover 由行 host 直接绘制（不触发重组），圆角取同一个 appearance，所以 hover 与选中不会
一个圆一个方。

## Behavior

- **指针**：down + up 在同一行内 → 写 `selection.wrappedValue = id`
- **键盘**：↑ / ↓ 移动选择，Home / End 到首尾，Return / keypad Enter 选择当前行
- **滚动**：外层 `ScrollView(.vertical)`，wheel 自动支持；只挂载视口附近的行，用占位高度保留完整滚动范围。
- **虚拟化**：`List` 内部使用 `VirtualStack`；`VirtualStack(data, id: \.id, rowHeight: 30, scrollToIndex: target)` 可单独使用（闭包 `rowHeight` 为可变行高形态），默认额外挂载视口前后各 3 行。行内容需符合指定固定高度，视口应有明确高度。行高只有渲染后才知道时用 `VirtualStack(data, id:, estimatedRowHeight: 32)`：未测量的行按估计值（随文本缩放）占位，挂载的行回报实际布局高度并按 ID 缓存（宽度或文本缩放变化时作废）；视口上方的行高度修正时保持第一可见行不跳动。`VirtualizationEstimateTests` 覆盖估计、测量收敛与缓存作废。
- **调用方的尺寸约束生效**：`List` 最外层是键盘 host，所以 `.frame`/`.flex` 落在它上面，内部滚动容器取剩余高度并裁切。缺少这条时滚动容器会按自身内容撑高，行会画到容器外面去。
- **`scrollToIndex` 首次布局不生效**：第一帧还没有视口高度，此时做 reveal 会多滚一行并把这次请求消费掉，所以本来可见的目标也会把列表滚过头。可变行高形态用同一条规则。
- **多选**：`List(selection: Binding<Set<ID>>)`；单选与多选共用同一实现、行 host 与键盘路径。多选行仍由同一个 `_ListRowHost` 处理点击，modifier 由指针事件传入。
- **sticky 区段**：`SectionedList(stickyHeaders: true)` 根据真实滚动 offset 计算当前区段；标题只在原行滚出顶部后接替，下一标题进入标题高度范围时上推它。计算复用虚拟化的固定 `rowHeight + rowSpacing`，因此触摸行高、字号缩放和 `scrollToIndex` 显露都得到同一条几何。固定副本不参与命中与语义，滚动仍由同一个 `ScrollView` 接收。
- **重排**：`ReorderableList` 在每行尾部提供 44pt handle；指针拖动只由 handle 的捕获事务驱动，放置线覆盖显示而不改变行几何，释放后一次回调；Escape 取消、方向键与辅助功能 increment/decrement 走同一 `onMove`。顺序属于调用方，组件不持久化。

## Authoring rules

✅ 应当：
- 把 List 放在已有明确高度的容器内（否则会塌成内容高度）
- `selection: $someID` 时配合 `id: \.id` 提供稳定 ID
- 自定义视觉走 `ListRowStyle` + `.listRowStyle(_:)`；沿用 `SelectionAppearance` 的 role，不要自己拼选中填充和圆角
- 行内容高于 `rowHeight` 会被居中并裁切；把 Badge 之类的小控件算进行高预算里

❌ 不应：
- 在 row content 里另嵌垂直 ScrollView；通用单行的极窄横向回退由 `ListRow` 自身处理
- 给 row content 写自己的选中高亮 —— style 已经处理；冲突会双高亮
- 为新的可选行 surface 重新发明选中样式 —— 加一个 role，或复用现有 role

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Apple HIG | 触摸行 ≥ 44pt；指针紧凑行保持 30/38pt |
| Fluent UI v9 | 单选 / 多选为同一 List 的模式（GuavaUI 按 binding 类型选择） |
| SwiftUI | `List(items, id:, selection:)` 调用形态 + ListStyle |

## Verification

- `ListRowTests`：三种列表 × 240/390/720/1280pt × 100%/200% × pointer/touch/mixed × light/dark × LTR/RTL；标题单行、尾槽无重叠、完整语义、节点/选择状态稳定。另测空槽、条件徽标、独立操作按钮、键盘激活、极窄横滚和 200K 数据窗口化。
- Gallery `ListRowLayoutTests`：真实字体和三种页面在 330/600/970pt、100%/200%、light/dark 下，验证未选行可见、选中徽标和实际点击后的几何。
- 命令：`./guava test GuavaUI --no-parallel --filter ListRowTests`；`./guava test GuavaUI/Examples --no-parallel --filter ListRowLayoutTests`。

- `SectionedListTests`：header/footer 文本、2 个 item 行、点击与键盘选择/激活。
- `SectionedListTests.stickyHeaders`：通过真实 `ScrollView` offset 验证首区段标题固定、下一标题上推 15pt、标题交接，以及 End 程序化显露后固定标题跟随到末区段；固定副本隐藏语义、关闭命中。
- `SectionedListTests.stickyHeadersDisabled`：默认关闭时滚动不生成固定标题，普通 header 仍在行内。
- `ListMultipleSelectionTests.pointerSelection`：点击 20、Shift-click 40、Cmd-click 30 的集合变化。
- `ListMultipleSelectionTests.keyboardSelection`：Shift+Arrow 扩展、普通 Arrow 收拢、Cmd+A 全选。
- `ReorderableListTests`：指针拖动显示放置线并只移动一次、键盘与辅助功能 increment/decrement、Escape 取消且不改顺序、触摸 handle ≥44pt；`edgeAutoScroll` 在 30 行 200pt 视口中验证视口中部不滚动、停在底边持续滚动、松开后落点与内容坐标一致且停止滚动，`edgeVelocity` 验证速度曲线，`floatingPreview` 验证预览起于原行、跟随指针、自动滚动时贴住视口底边、原行变为占位且松开后消失。DevTools 在 1280 Gallery 中按住 Main Camera 下拖 60pt 后，以独立连接截图仍保持拖动状态：浮起行位于 y=334、放置线 y=345，松开后顺序为 Key Light → Main Camera → …。DevTools 在 Gallery `--component reorderableList` 的 Long list（40 行、220pt）中按住第一行 handle 停在底边 0.8s，列表滚到 Layer 30 以后，松开后 Layer 1 位于第 39 位；按住时镜像显示放置线紧贴指针。
- `SwipeListTests`：触摸左滑与 44pt 操作、Actions 按钮/上下文菜单的非滑动路径、纵向滚动让路、禁用态与指针面不响应滑动。
- `RefreshTests`：触摸下拉只触发一次且指示器保持到 binding 清除；Cmd+R 触发一次并忽略刷新中的重复按键。
- Gallery `multiSelectList` 页提供 12 行、初始选中与状态文本；`sectionedList` 页提供可滚动的三段列表并默认开启 sticky；`reorderableList` 页提供 6 行真实拖动与顺序文本。

## SwipeList

`SwipeList` 在 List 的选择与键盘基础上增加 trailing 滑动操作。仅触摸面响应左滑，最多露出两个 74pt 操作；行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口。完整 API、RTL 与虚拟化边界见 [SwipeList](swipelist.md)。

## Refreshable List

`List`/`VirtualStack` 通过 `RefreshOptions(isRefreshing:threshold:action:)` 接入下拉刷新。触摸下拉越过阈值只触发一次，指示器在 binding 清除前保持并预留 36pt inset；Cmd+R/Ctrl+R 为键盘入口。完整 API 与边界见 [RefreshableList](refresh.md)。

## File map

- 通用行: [Row.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Row.swift)
- 主体: [List.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/List.swift) · [Selection.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Selection.swift) · [SectionedList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/SectionedList.swift) · [Reorderable.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Reorder/Reorderable.swift) · [SwipeList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/SwipeList.swift) · [Refresh.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Refresh.swift)
- Style + 默认: [GuavaUICompose/Theme/Styles/Components/ListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/Styles/Components/ListRowStyle.swift) · [DefaultListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/Styles/Components/DefaultListRowStyle.swift)

## 响应式与输入密度

List 先用 `TextScaler` 缩放 authored `rowHeight` 与 `rowSpacing`，再在 touch surface 上把行高提升至至少 44pt。行 host、VirtualStack 的窗口化与滚动 extent 使用同一高度；返回 pointer 后仅移除触摸下限，字号缩放仍生效。不要在调用方预先缩放这两个参数。通用 VirtualStack 不假定每行可交互，仍使用调用方的实际高度。touch-only surface 不展示行 hover。

`TextScaleRowTests.collectionGeometry` 覆盖 390/720/1280pt、light/dark、100%/125%/200% 字号与输入切换，验证缩放一次、行间距、窗口化及状态保留。

`ReorderableList` 使用同一条缩放与触摸下限规则；指针/键盘 handle 高度为 `max(scaledRowHeight, touch ? 44 : 0)`，触摸面行高与 handle 均为 44pt。行按视口窗口化，滚动由内部 `ScrollView` 管理。

SectionedList 的 sticky 标题使用与虚拟化相同的已缩放行高与触摸下限：sticky 容器的标题高度取 `effectiveHeight`，下一标题位置取 `entryIndex × (effectiveHeight + scaledSpacing)`。因此字号或输入集合变化后，固定标题与行几何不会错位。
