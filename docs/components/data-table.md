# DataTable

`DataTable` 用于大型固定行高数据集。普通 `Table` 是小型数组表格；其便捷排序/单选路径仍会遍历数组。大量记录应由应用长期持有 `DataTableModel<Record, ID>`，不在 `body` 中构造模型或数据集。

## 数据与会话

模型拥有记录、稳定 ID 索引和显示顺序。`record(at:)`、`rowID(at:)`、`index(for:)` 是 O(1)。初次加载和 `replaceRows` 各建立一次 ID 索引，重复 ID 会触发前置条件失败。模型在 UI 执行器使用；`Record` 和 `ID` 必须 `Sendable`，后台只读取不可变数组快照。

排序命令在串行后台队列建立显示顺序及反向 ID 索引；相同值在升序和降序中都保留源顺序。排序时继续显示旧投影，过期回复按命令代数丢弃。最近两个投影缓存供反复切换；数据改变使缓存失效。排序闭包必须 `@Sendable`，不能捕获 UI 状态。

`DataTableSelection`、列宽、滚动位置与 `TextBuffer` 编辑草稿是会话数据，与 authored rows 分开。可由应用绑定选择和列宽。`replaceRows` 后调用方应清空选择，或显式调用 `retainExisting(in:)`；不在每帧遍历大型选中集合。模型不隐式序列化这些会话值。

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

原生画廊已加载 200K × 33，跳到第 100,001 行，编辑 Asset 单元格，并验证后台排序完成及横向键盘导航时冻结列保持原位。没有 FPS/Instruments 的定量证据。当前不包含列拖拽重排、分组表头、分页/远端加载、列/矩形单元格选择、可变行高、CSV 导出协议或内置表格级撤销。
