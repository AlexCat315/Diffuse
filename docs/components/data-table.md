# DataTable

`DataTable` 用于大型固定行高数据集。普通 `Table` 是小型数组表格；其便捷排序/单选路径仍会遍历数组。大量记录应由应用长期持有 `DataTableModel<Record, ID>`，不在 `body` 中构造模型或数据集。

## 数据与会话

模型拥有记录、稳定 ID 索引和显示顺序。`record(at:)`、`rowID(at:)`、`index(for:)` 是 O(1)。初次加载和 `replaceRows` 各建立一次 ID 索引，重复 ID 会触发前置条件失败。模型在 UI 执行器使用；`Record` 和 `ID` 必须 `Sendable`，后台只读取不可变数组快照。

排序命令在串行后台队列建立显示顺序及反向 ID 索引；相同值在升序和降序中都保留源顺序。排序时继续显示旧投影，过期回复按命令代数丢弃。最近两个投影缓存供反复切换；数据改变使缓存失效。排序闭包必须 `@Sendable`，不能捕获 UI 状态。

`DataTableSelection`、列宽、列显隐选择、滚动位置与 `TextBuffer` 编辑草稿是会话数据，与 authored rows 分开。可由应用绑定选择、列宽与列显隐。`replaceRows` 后调用方应清空选择，或显式调用 `retainExisting(in:)`；不在每帧遍历大型选中集合。模型不隐式序列化这些会话值。

```swift
struct AssetRow: Sendable {
    let id: Int
    var name: String
}
// 在应用状态中长期持有：
let model = DataTableModel(rows, id: \.id)
var name = TableColumn<AssetRow>("name", "Name") {
    Text($0.name, lineLimit: 1)
}
name.compare = { $0.name.localizedStandardCompare($1.name) }
name.textEditing = TableTextEditing(text: { $0.name }, update: { $0.name = $1 })
name.textEditing?.validate = { $0.isEmpty ? "Name is required" : nil }

DataTable(model, columns: [name]) { table in
    table.options.selection = $selection
    table.options.selectionMode = .multiple
    table.options.frozenColumnCount = 0
}.frame(height: 360)
```

## 视口与行为

固定表头、冻结前 N 列与滚动区域共享列宽和行高。行只创建视口及三行 overscan；水平可见列由累计宽度二分查找，仅创建可见列及边缘余量。冻结列始终创建。单元格的编辑视图属于可见窗口，长期值由模型持有。

点击选择行和活动列。Command/Ctrl 点击切换单行，Shift 点击或 Shift 上下移动延伸源锚点至当前显示行；单选模式忽略这些扩展修饰。上下、Home/End、Page Up/Down 导航行，左右导航单元格并揭示目标。Command/Ctrl-A 在多选模式选择全部，Escape 清空选择。Tab 在普通浏览时继续正常焦点遍历。

双击可编辑单元格或 F2/Return 开始编辑。Return/blur 验证并提交；Escape 放弃草稿。Tab/Shift-Tab 提交后进入同一行的下一个/前一个可编辑列。拒绝草稿保留原始记录并显示错误消息；未修改的草稿不会重建排序。嵌套输入先处理键盘和指针事件。关闭编辑恢复表格焦点；禁用时不接受选择或编辑。

列分隔线提供独立较宽命中区域；拖拽或 Left/Right 调整宽度，辅助技术也可增减或设置。没有排序闭包的列是普通标题。

## 验证与仍有边界

`DataTableModelTests` 验证 200K 行后台排序、稳定相等顺序、两方向缓存、最新数据/回复、范围多选和 500 列窗口查找。`DataTableInteractionTests` 验证 200K × 100 不创建全部单元格、空闲布局不重建行、末行/水平导航、冻结列对齐、实际点击修饰键、编辑验证/取消/焦点。

原生画廊已加载 200K × 33，跳到第 100,001 行，编辑 Asset 单元格，并验证后台排序完成及横向键盘导航时冻结列保持原位。没有 FPS/Instruments 的定量证据。当前不包含分组表头、分页/远端加载、列/矩形单元格选择、CSV 导出协议或内置表格级撤销（按需）。

## 列重排与可变行高

- **列顺序**：`options.columnOrder` 绑定按列 ID 的显示顺序（省略时为会话状态）。未知 ID 被忽略，不在顺序里的列保持原始相对位置排在后面，新增列无需迁移已保存的顺序。表头横向拖动超过 6pt 进入重排：表头半透明、插入位置显示 2pt 强调色线，松开后把列移到指针中心所在列的前或后；短按仍是排序点击，列宽拖柄的拖动不会触发重排，Escape 取消。键盘在单元格上按 Option/Alt+Left/Right 移动当前列。冻结前缀按顺序中的前 N 列计算。
- **可变行高**：`table.rowHeight = { record in ... }` 返回逻辑高度（随文本缩放），`options.layout.rowHeight` 仍是下限（含触摸 44pt）。高度按模型修订、行数与缩放构建一次前缀和，滚动时不重建；视口窗口、占位、滚动范围、显露目标与翻页都使用同一份行几何。

## TreeTable

`TreeTable(roots, id:, children:, columns:)` 把层级放在首列：按深度缩进（`options.indentation`，随文本缩放）和披露按钮（名称 Expand/Collapse，暴露展开态），其余能力（列宽、优先级、重排、窗口化、选择、网格键盘）来自 DataTable。`children` 返回 `nil` 表示叶子，`[]` 表示空分支。首列聚焦时 Right 展开或进入第一个子项，Left 折叠或回到父项。展开集合可由 `options.expanded` 绑定。只遍历已展开分支，代价随可见行而非整棵树增长。不提供排序与单元格编辑，兄弟项保持原顺序。

`DataTableLayoutTests` 覆盖顺序模型、键盘与拖拽重排（含短按仍排序）、可变行高几何、TreeTable 缩进/展开/方向键遍历与展开投影；Gallery `dataTable` 页提供列重排与 TreeTable 示例。

## 响应式与输入密度

Table 与 DataTable 共用行高解析：先按 `TextScaler` 缩放 authored `rowHeight` 与 `headerHeight`，touch（包含混合输入）再应用 44pt 下限；pointer 仅移除触摸下限。不要在调用方预先缩放高度。DataTable 的冻结列、可见窗口、占位、滚动范围、目标显露和 PageUp/Down 使用同一行高；Table 将 authored 行高交给内部 List，单元格使用解析后的高度，避免二次缩放。触摸单元格移除纵向内容 inset，使内嵌按钮与编辑器的 44pt 命中不被裁剪。解析只作用于当前视图值，不写回配置或数据模型。

`RowDensityTests.collectionRows` 在 390/720/1280pt 验证 touch-only、混合输入、pointer 恢复、较大 authored 行高和节点/选择保留；`dataTableNavigation` 验证触摸翻页、最后一行、冻结列对齐与编辑取消后的焦点恢复。`TextScaleRowTests.collectionGeometry` / `dataTableNavigation` 验证 100%/125%/200% 字号、表头高度、选择/焦点保留及翻页与滚动 extent。

### 列优先级与可见性

`Table` 与 `DataTable` 的 `TableColumn.visibility` 使用与命名 Grid 共享的 `ColumnVisibility`。默认 `.required` 保留列；`.automatic(priority:)` 按实际容器宽度移除低优先列，相同优先级先移除靠后的列。列宽使用当前拖拽宽度，不缩小列宽、字号或触摸行高来塞进视口。冻结前缀与正在编辑的列不自动隐藏，至少保留一列。

```swift
let details = TableColumn<AssetRow>("details", "Details", configure: {
    $0.layout.width = 110
    $0.visibility = .automatic(priority: 10)
}) { Text("ID \($0.id)") }

DataTable(model, columns: [name, details]) {
    $0.options.columnVisibility = $columnChoices
}
```

`columnVisibility` 是可选的 `[String: Bool]` binding：`true` 强制显示，`false` 隐藏，缺省使用自动策略；必要列、冻结列和活动编辑仍优先。无 binding 时选择只属于当前挂载会话，卸载重置。有自动列时，表格自带“Columns”按钮、可见数量和复用 Menu 的勾选入口；“Automatic columns”清除用户选择。触发器及菜单行至少 44pt，必要列的菜单项保持选中并禁用。

用户强制显示超出容器的列时保留横向滚动。冻结区域本身宽于可用区时，当前呈现暂时使用整体横向滚动，保留全部必要列；恢复空间后恢复冻结。显隐不改写模型、排序或列宽。键盘仅导航当前列；隐藏焦点列时交接到可见性入口并释放拖拽捕获。正在编辑的列保留到提交/取消，冻结/滚动区迁移不触发失焦提交；普通点击离开仍验证并提交。程序化导航到隐藏列会将它显式显示并揭示目标。窗口化允许隐藏列卸载，单元格的长期值仍由模型管理。

`TableColumnsTests` 覆盖两类表格的宽度、100%/200% 字号、三种输入和明暗主题，以及显隐、排序、选择、焦点、草稿和会话重置；AI 查询验证隐藏列不暴露可交互单元格，恢复显示后可按列名发现。Gallery `table` / `dataTable` 提供优先级、菜单和三种容器预览。

2026-10-16 macOS 原生 Gallery 加载 200,000×33：1280pt 窗口保留 6 列，390pt 窗口保留 Asset；显式恢复 Quantity 后保留两列与横向滚动。经 [DevTools 即时 AI 工具](../architecture/agent-framework.md#诊断工具) 查询，当前窄屏视口有 7 个 row，隐藏 Quantity 的可见单元格为 0，恢复后为 7。100%/200% 字号的入口命中分别为 79×44 / 125×50pt，200% 菜单行高 52pt，必要列禁用勾选、恢复自动模式均已实际操作。空数据仍保留已分配的表头；仅剩冻结列时不产生重复空行语义。以上不是 GPU 帧时间或物理设备触摸测量。
