# Workspace

GuavaUI 的 docking 系统公开名称是 `GuavaUIWorkspace` 模块和 `WorkspaceView / WorkspaceController / WorkspaceDocument`。保留 Workspace 名称：它表达带文档状态、标签分组、区域、浮动面板和布局持久化的工作区；docking 是其中的交互能力。普通尺寸分配使用 SplitView/Flex，不必引入工作区模型。本页替换了描述旧 DockController/DockOperation 的过期文档。

## 模型与操作

- `WorkspacePanel`：软件定义的稳定面板 ID、标题、图标键与关闭/拖拽/折叠能力。
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

外层区域分隔符修改 `WorkspaceSplitFractions`。内部 docking 拆分原来只渲染 8pt 空隙，没有拖动柄；本轮改用原生 SplitView，支持 pointer、箭头和辅助功能 increment/decrement。新的 `resizeLayoutSplit(WorkspaceLayoutSplit, fraction:)` 写回所属 slot 的实际树，触发订阅并标记 persistenceDirty。

拆分地址用 slot 与两侧代表 group ID 定位其共同祖先，不依赖压缩后视图的数组下标；折叠隐藏分支仍保留在作者布局中。失效地址、非有限比例和相同比例不产生变化。测试覆盖嵌套树、隐藏分支、真实事件拖动/键盘及 JSON 恢复。

## 仍需完善

- **尺寸协议**：内部拆分已经可调整，但 WorkspacePanel 还没有可序列化的 min/preferred/max 内容尺寸。外层区域仍只依赖比例，窗口很窄时可能挤压内容；通用 N 面板联动、折叠阈值与吸附尚缺。
- **标签条**：当前标签条固定高度，200% 文字、超长标题、大量标签、可滚动条与 overflow 菜单、pin 的专属视觉区以及完整 roving keyboard 尚未统一完成。模型中有 pin/closeOthers 不代表 UI 已完整。
- **主题**：WorkspaceTheme 存在，但一些 chrome/图标/高度仍硬编码，未全部消费 theme 字段与文字缩放。内部新分隔柄使用 SplitView 的主题线条；外层柄尚未统一到同一键盘/辅助功能协议。
- **浮动**：WorkspaceFloatingWindow 是当前应用窗口中的浮动面板层，不能宣称具有独立 OS 窗口、跨窗口拖拽或多屏恢复。
- **持久化边界**：比例/分组 round trip 已测试；整个 document 的外部不可信解码校验、重复引用/缺失 panel、屏幕变更后的位置修复及可版本化应用格式仍需成套实现。
- **维护性与性能**：View/controller 仍有大型文件，需要继续按 shell、tabs、drag、floating 分域拆分；大型面板数、复杂内容、快速跨组拖动和长期运行需单独原生测量。
- **可访问性/本地化**：完整 tab/区域语义、RTL、平台读屏桥接与系统尺寸偏好仍有缺口。

原生检查另确认外层固定 frame 曾在组件局部重组后被内部布局覆盖，本轮在 ComposeCore 修复调用方修饰器的重放规则，避免调整分隔符时工作区高度自行变化。

这些是 docking 的后续工作，不应仅为名字整齐再做一次全仓 API 更名，也不应称为成熟 DockArea 等价物。

实现：[Model](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceModel.swift)、[Controller](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceController.swift)、[内部布局树](../../GuavaUI/Sources/GuavaUIWorkspace/Layout/Tree.swift)、[拆分地址](../../GuavaUI/Sources/GuavaUIWorkspace/Layout/Split.swift)、[WorkspaceView](../../GuavaUI/Sources/GuavaUIWorkspace/WorkspaceView.swift)。
