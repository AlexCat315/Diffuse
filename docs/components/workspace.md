# Workspace

GuavaUI 的 docking 系统公开名称是 `GuavaUIWorkspace` 模块和 `WorkspaceView / WorkspaceController / WorkspaceDocument`。保留 Workspace 名称：它表达带文档状态、标签分组、区域、浮动面板和布局持久化的工作区；docking 是其中的交互能力。普通尺寸分配使用 SplitView/Flex，不必引入工作区模型。本页替换了描述旧 DockController/DockOperation 的过期文档。

## 模型与操作

- `WorkspacePanel`：软件定义的稳定面板 ID、标题、图标键、关闭/拖拽/折叠能力与 `WorkspacePanelSizing` 内容尺寸契约。
- `WorkspaceTabGroup`：面板顺序、activePanelID、折叠状态与 pinnedPanelIDs。
- `WorkspaceSlot`：开放的槽 ID、kind、尺寸策略和该槽的布局树。软件可以新增区域或 chrome 槽。
- `WorkspaceLayoutNode`：group 或横/纵 split，比例存储在实际拆分节点。
- `WorkspaceDocument`：上述面板、分组、槽、折叠、浮动面板、外层区域比例及关闭记录，直接 Codable。已移除未参与渲染且会脱节的第二份 layoutTree。
- `WorkspaceController`：分发命令、聚焦/最大化、版本与订阅。指针拖拽和绘制预览不会写入持久化文档。

```swift
let controller = WorkspaceController(document: document)
WorkspaceView(controller: controller) { panelID in
    AnyView(applicationPanel(panelID))
}

controller.dispatch(.movePanel("preview",
    to: .split(slot: .center, anchorGroupID: "editor", edge: .trailing)))
let saved = try JSONEncoder().encode(controller.document)
controller.replace(try JSONDecoder().decode(WorkspaceDocument.self, from: saved))
```

## 当前可用能力

标签点击、关闭、同组重排、跨组移动、边缘拆分、拖拽 ghost/落点预览；区域折叠/恢复与可选动画；聚焦/最大化/恢复；关闭其他/右侧、重开关闭面板、pin 的模型操作；浮动组的位置、层级与重新停靠；紧凑视图中的面板切换。

面板是卡片，不是描边矩形。停靠分组和浮动窗口共用一份 `workspaceCardSurface`：`surfaceRaised` 面板体、`theme.radius.xl` 圆角、一道弱化的 1px 描边和一层浅阴影。分组间隙由 `WorkspaceTheme.splitDividerThickness + 2 × splitDividerHitSlop` 决定，默认 6 点——两卡片之间露出的画布细缝，不是每个面板四周的 margin。标签条用 `surface` 作为表头，与白色面板体形成一档明度差；圆角由卡片裁切，不需要单独处理。

两块卡片之间没有间隔区域，只有一根 1px 分隔线：`WorkspaceTheme.splitDividerThickness` 是这条线本身的宽度，`WorkspaceLayoutMetrics.divider` 等于它。分隔线的可拖拽区域用负 margin 悬在两侧卡片之上（`splitDividerHitSlop`），因此不占布局宽度——分隔区域节点 `clipsToBounds = false` 且 `zIndex` 高于卡片，否则这段悬空区域会被裁掉，或被面板内容抢走指针。区域边界因此落在分隔节点的**中点**上，而不是它的任一边缘。标签条里的活动标签走 `SelectionAppearance` 的 `.navigation` role，与 List 行、Sidebar 目的地共用同一套填充、圆角和内缩。

面板用 `WorkspacePanelSizing(width:height:)` 声明逻辑内容尺寸，每个轴拥有 `minimum / preferred / maximum`，直接随面板 Codable 持久化。约束跟随面板移动，分组综合所有标签的约束，避免换标签时跳动；同轴拆分累加最小/最大值和 divider，交叉轴取共同边界。标题栏高度额外计入垂直约束，200% 字体时同步扩高。初始化和解码会归一化非有限值、负值以及 min/max 冲突，缺失尺寸组使用独立默认值。

```swift
WorkspacePanel(id: "inspector", title: "Inspector", sizing: .init(
    width: .init(minimum: 180, preferred: 260, maximum: 360),
    height: .init(minimum: 90, preferred: 160, maximum: 240)))
```

外层 leading / trailing / top / bottom 与内部 docking 拆分使用同一尺寸范围解析。`WorkspaceSplitFractions` 的轴值为可选值：nil 使用面板 preferred 作为初始提示，没有提示时使用工作区默认比例；用户拖动后写入显式比例，恢复文档后继续尊重用户比例。测量到的窗口尺寸、动画、滚动位置、聚焦和 pointer 状态均留在运行时，不进入文档。外层区域的箭头、Shift + 箭头（大步长）、Home/End，以及辅助功能 increment/decrement 与指针写入相同边界。

填满式拆分在约束可以同时满足时执行 min/max；窗口比总 minimum 还小时，按 minimum 比例压缩，保持区域不向窗口外溢出。总 maximum 小于可用空间时，填满容器会使上限不可同时满足，剩余空间按 maximum 比例分配。这是明确的冲突规则，不等同于自动折叠或吸附。浮动层也执行面板尺寸边界，但仍是当前应用窗口中的浮层。

标签条采用水平滚动，长标题限制为单行，独立保留全部面板菜单、最大化和折叠按钮。活动标签切换或 viewport 改变时滚入可见区域，普通滚动不重置位置；一个 tab group 只有活动标签进入 Tab 顺序，Left/Right/Home/End 切换选择。菜单通过 portal 展开，不受面板 clipping 限制。标签高度与操作按钮消费文字缩放，200% 字体仍可操作。pin 当前继续使用图标标识。

内部 docking 拆分使用原生 SplitView，支持 pointer、箭头和辅助功能 increment/decrement；`resizeLayoutSplit(WorkspaceLayoutSplit, fraction:)` 写回所属 slot 的实际树，触发订阅并标记 persistenceDirty。

拆分地址用 slot 与两侧代表 group ID 定位其共同祖先，不依赖压缩后视图的数组下标；折叠隐藏分支仍保留在作者布局中。失效地址、非有限比例和相同比例不产生变化。测试覆盖嵌套树、隐藏分支、真实事件拖动/键盘及 JSON 恢复。

## 仍需完善

- **尺寸交互深化**：通用 N 面板联动、自动折叠阈值、吸附、最大值冲突时留白策略尚缺；当前二叉拆分按明确的填满规则退化。
- **标签条**：滚动、全部面板菜单、活动标签键盘导航和 200% 尺寸已接入；pin 的专属视觉区、关闭其他/右侧的可见操作、长标题完整提示仍需完善。模型中有 pin/closeOthers 不代表 UI 已完整。
- **主题**：WorkspaceTheme 存在，但一些 chrome/图标/高度仍硬编码，未全部消费 theme 字段与文字缩放。内部新分隔柄使用 SplitView 的主题线条；外层柄已共享尺寸范围与键盘/辅助功能调整。
- **浮动**：WorkspaceFloatingWindow 是当前应用窗口中的浮动面板层，不能宣称具有独立 OS 窗口、跨窗口拖拽或多屏恢复。
- **持久化边界**：比例/分组 round trip 已测试；整个 document 的外部不可信解码校验、重复引用/缺失 panel、屏幕变更后的位置修复及可版本化应用格式仍需成套实现。
- **维护性与性能**：View/controller 仍有大型文件，需要继续按 shell、tabs、drag、floating 分域拆分；大型面板数、复杂内容、快速跨组拖动和长期运行需单独原生测量。
- **可访问性/本地化**：标签条已具备完整语义——标签容器为 `tabList`（值为当前标签标题），每个标签为 `tab`，帮助文本给出“Tab N of M”，固定标签的值为 Pinned，标识符为面板 ID；面板内容区为以标题命名的 `tabPanel`（macOS 映射为 tabGroup 与 group）。RTL 下标签条随布局镜像，Left 移到视觉上的下一个标签。标签标题经 Text 使用双向段落排版。平台读屏的进一步桥接与系统尺寸偏好仍有缺口。`WorkspaceViewTests.testTabStripExposesTabListPanelAndPositionAndMirrorsArrowsInRTL` 覆盖 LTR/RTL。

原生检查另确认外层固定 frame 曾在组件局部重组后被内部布局覆盖，本轮在 ComposeCore 修复调用方修饰器的重放规则，避免调整分隔符时工作区高度自行变化。

这些是 docking 的后续工作，不应仅为名字整齐再做一次全仓 API 更名，也不应称为成熟 DockArea 等价物。

实现：[Model](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceModel.swift)、[Controller](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceController.swift)、[内部布局树](../../GuavaUI/Sources/GuavaUIWorkspace/Layout/Tree.swift)、[拆分地址](../../GuavaUI/Sources/GuavaUIWorkspace/Layout/Split.swift)、[WorkspaceView](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceView.swift)。
