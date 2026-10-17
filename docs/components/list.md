# List / MultiSelectList / ListRow

垂直列表，固定行高并按可见区域虚拟化。`List` 是单选；`MultiSelectList` 使用稳定 ID 集合，支持 Shift 区间、Cmd/Ctrl 切换、键盘扩展与全选。行视觉（选区填充、padding、字体）走 `ListRowStyle`。

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
    Text(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `selection` | `.constant(nil)` | 单选 binding，nil 表示未选 |
| `rowHeight` | 30 | 未缩放逻辑行高，组件自动应用 `TextScaler` 与触摸下限 |
| `rowSpacing` | 0 | 未缩放行间隙，组件自动应用 `TextScaler` |

## MultiSelectList

```swift
@State private var selection: Set<Item.ID> = []

MultiSelectList(items, id: \.id, selection: $selection,
                onActivate: { open($0) }) { item, isSelected in
    Text(item.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `selection` | `.constant([])` | 稳定 ID 集合 binding |
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
    Text(item.title)
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
- 当前为全量挂载的非虚拟列表（适合设置、图层、播放列表等中等规模顺序），拖到视口边缘的自动滚动尚未实现；大集合应等待后续虚拟化重排。

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
- **虚拟化**：`List` 内部使用 `VirtualStack`；`VirtualStack(data, id: \.id, rowHeight: 30, scrollToIndex: target)` 和 `VirtualList(data, id: \.id, rowHeight: 30)` 可单独使用，默认额外挂载视口前后各 3 行。行内容需符合指定固定高度，视口应有明确高度。
- **调用方的尺寸约束生效**：`List` 最外层是键盘 host，所以 `.frame`/`.flex` 落在它上面，内部滚动容器取剩余高度并裁切。缺少这条时滚动容器会按自身内容撑高，行会画到容器外面去。
- **`scrollToIndex` 首次布局不生效**：第一帧还没有视口高度，此时做 reveal 会多滚一行并把这次请求消费掉，所以本来可见的目标也会把列表滚过头。`VariableVirtualStack` 用同一条规则。
- **多选**：使用 `MultiSelectList`；List 保持单选。多选行仍由同一个 `_ListRowHost` 处理点击，modifier 由指针事件传入。
- **sticky 区段**：`SectionedList(stickyHeaders: true)` 根据真实滚动 offset 计算当前区段；标题只在原行滚出顶部后接替，下一标题进入标题高度范围时上推它。计算复用虚拟化的固定 `rowHeight + rowSpacing`，因此触摸行高、字号缩放和 `scrollToIndex` 显露都得到同一条几何。固定副本不参与命中与语义，滚动仍由同一个 `ScrollView` 接收。
- **重排**：`ReorderableList` 在每行尾部提供 44pt handle；指针拖动只由 handle 的捕获事务驱动，放置线覆盖显示而不改变行几何，释放后一次回调；Escape 取消、方向键与辅助功能 increment/decrement 走同一 `onMove`。顺序属于调用方，组件不持久化。

## Authoring rules

✅ 应当：
- 把 List 放在已有明确高度的容器内（否则会塌成内容高度）
- `selection: $someID` 时配合 `id: \.id` 提供稳定 ID
- 自定义视觉走 `ListRowStyle` + `.listRowStyle(_:)`；沿用 `SelectionAppearance` 的 role，不要自己拼选中填充和圆角
- 行内容高于 `rowHeight` 会被居中并裁切；把 Badge 之类的小控件算进行高预算里

❌ 不应：
- 在 row content 里再嵌一个 ScrollView
- 给 row content 写自己的选中高亮 —— style 已经处理；冲突会双高亮
- 为新的可选行 surface 重新发明选中样式 —— 加一个 role，或复用现有 role

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Material 3 | List item 高度（48 standard, 30 dense） |
| Fluent UI v9 | 单选 / 多选模式分离（List / MultiSelectList） |
| SwiftUI | `List(items, id:, selection:)` 调用形态 + ListStyle |

## Verification

- `SectionedListTests`：header/footer 文本、2 个 item 行、点击与键盘选择/激活。
- `SectionedListTests.stickyHeaders`：通过真实 `ScrollView` offset 验证首区段标题固定、下一标题上推 15pt、标题交接，以及 End 程序化显露后固定标题跟随到末区段；固定副本隐藏语义、关闭命中。
- `SectionedListTests.stickyHeadersDisabled`：默认关闭时滚动不生成固定标题，普通 header 仍在行内。
- `MultiSelectListTests.pointerSelection`：点击 20、Shift-click 40、Cmd-click 30 的集合变化。
- `MultiSelectListTests.keyboardSelection`：Shift+Arrow 扩展、普通 Arrow 收拢、Cmd+A 全选。
- `ReorderableListTests`：指针拖动显示放置线并只移动一次、键盘与辅助功能 increment/decrement、Escape 取消且不改顺序、触摸 handle ≥44pt。
- `SwipeListTests`：触摸左滑与 44pt 操作、Actions 按钮/上下文菜单的非滑动路径、纵向滚动让路、禁用态与指针面不响应滑动。
- Gallery `multiSelectList` 页提供 12 行、初始选中与状态文本；`sectionedList` 页提供可滚动的三段列表并默认开启 sticky；`reorderableList` 页提供 6 行真实拖动与顺序文本。

## SwipeList

`SwipeList` 在 List 的选择与键盘基础上增加 trailing 滑动操作。仅触摸面响应左滑，最多露出两个 74pt 操作；行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口。完整 API、RTL 与虚拟化边界见 [SwipeList](swipelist.md)。

## File map

- 主体: [List.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/List.swift) · [MultiSelectList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/MultiSelectList.swift) · [SectionedList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/SectionedList.swift) · [ReorderableList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/ReorderableList.swift) · [SwipeList.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/SwipeList.swift)
- Style + 默认: [GuavaUICompose/Theme/ListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/ListRowStyle.swift) · [DefaultListRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultListRowStyle.swift)

## 响应式与输入密度

List 先用 `TextScaler` 缩放 authored `rowHeight` 与 `rowSpacing`，再在 touch surface 上把行高提升至至少 44pt。行 host、VirtualStack 的窗口化与滚动 extent 使用同一高度；返回 pointer 后仅移除触摸下限，字号缩放仍生效。不要在调用方预先缩放这两个参数。通用 VirtualList/VirtualStack 不假定每行可交互，仍使用调用方的实际高度。touch-only surface 不展示行 hover。

`TextScaleRowTests.collectionGeometry` 覆盖 390/720/1280pt、light/dark、100%/125%/200% 字号与输入切换，验证缩放一次、行间距、窗口化及状态保留。

`ReorderableList` 使用同一条缩放与触摸下限规则；指针/键盘 handle 高度为 `max(scaledRowHeight, touch ? 44 : 0)`，触摸面行高与 handle 均为 44pt。当前非虚拟化，行数与滚动由外层固定高度的 `ScrollView` 管理。

SectionedList 的 sticky 标题使用与虚拟化相同的已缩放行高与触摸下限：sticky 容器的标题高度取 `effectiveHeight`，下一标题位置取 `entryIndex × (effectiveHeight + scaledSpacing)`。因此字号或输入集合变化后，固定标题与行几何不会错位。
