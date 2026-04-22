# Dock

多面板可拖拽 / 可分裂 / 可分离窗口的工作区容器。Editor 级别 IDE chrome 的核心。

## Anatomy

```
┌── Window A (main) ────────────────────────┬── Window B (satellite) ──┐
│ ┌─ Tab Bar ────────────────────────────┐ │ ┌─ Tab Bar ────────────┐ │
│ │ [ Sidebar ] [ Workspace ]│[Inspector]│ │ │ [ Console ]          │ │
│ ├──────────────────────────┼───────────┤ │ ├──────────────────────┤ │
│ │                          │           │ │ │                      │ │
│ │  active tab content      │  content  │ │ │  detached leaf       │ │
│ │                          │           │ │ │                      │ │
│ └──────────────────────────┴───────────┘ │ └──────────────────────┘ │
└──────────────────────────────────────────┴──────────────────────────┘
```

- Tab Bar：当前 leaf 上的标签条；按下并拖动可移动 / 分裂 / 跨窗口分离。
- Splitter：水平 / 垂直拆分条；拖动即调整 fraction。
- Drop Zones：拖动期间在 leaf 四边显示边缘高亮；中央高亮表示并入当前 leaf。
- Satellite Window：拖出主窗口阈值后生成的子窗口，承载单个 leaf。

## API

```swift
let controller = DockController(root:
    .hsplit(fraction: 0.18,
        first: .tabs([sidebarTab]),
        second: .hsplit(fraction: 0.74,
            first: .tabs([workspaceTab]),
            second: .tabs([inspectorTab])))
)

DockContainer(controller: controller) { key in
    switch key {
    case "sidebar":   return AnyView(SidebarView())
    case "workspace": return AnyView(WorkspaceView())
    case "inspector": return AnyView(InspectorView())
    default:          return AnyView(EmptyView())
    }
}
```

`DockTab.userKey` 是字符串查找键，dock 层从不持有 `View` 引用，模型 100% `Sendable + Codable`。

### 跨窗口分离

```swift
let bridge = DockHostBridge(...)         // 由 host 实现 origin / size 提供器
DockContainer(controller: controller, hostBridge: bridge) { key in ... }

// 卫星窗口里：
DockSatelliteView(controller: controller,
                  leafID: someDetachedLeafID,
                  hostBridge: satelliteBridge) { key in ... }
```

详见 [`docs/guava-ui-phase8.5-dock-design.md`](../guava-ui-phase8.5-dock-design.md)。

## 持久化

`DockLayoutSnapshot` 捕获完整 layout（root + satellites + 顺序），Codable，跨进程 round-trip：

```swift
let snap = controller.snapshot()
let data = try JSONEncoder().encode(snap)
// ... write to disk ...

let decoded = try JSONDecoder().decode(DockLayoutSnapshot.self, from: data)
controller.load(decoded)
```

GuavaUIDemo 顶部的 `Save / Load / Reset` 按钮使用 `DemoLayoutPersistence`，
默认路径 `~/.guava/dock-demo.json`。

## 操作模型

`DockController.apply(_:)` 接受声明式 `DockOperation`：

| Operation | 含义 |
| --------- | ---- |
| `.insertTab(tab, into:, at:)` | 在指定 leaf 插入 tab |
| `.move(tabID, to:)` | 移动 tab 到 `DockDropTarget`（leaf 中央 / leaf 边缘 / split fraction） |
| `.removeTab(tabID)` | 删除 tab；空 leaf 自动 collapse |
| `.activateTab(tabID, in:)` | 切换 leaf 的 active tab |
| `.setSplitFraction(splitID, fraction:)` | 调整拆分比例 |
| `.spawnSatellite(leafID, hint:)` / `.closeSatellite(leafID)` | 卫星窗口生命周期 |
| `.moveLeaf(leafID, to:)` | 把整个 tabs leaf 搬到一个 `DockDropTarget`：`.tabSlot` 把所有 tab 折进目标 leaf，`.replace` / `.splitEdge` 整棵子树 graft；自动塌陷源 split |
| `.closeOthers(in:, keep:)` | 关闭 leaf 内除 `keep` 与 pinned tab 之外的所有 tab；victim 按从左到右顺序 push 进 `closedHistory` |
| `.closeToTheRight(in:, of:)` | 关闭 leaf 内 pivot 之后的所有 tab；同样 push 进 `closedHistory` |
| `.reopenLastClosed` | 弹出 `closedHistory` 末尾，按原 leaf + 原 index 复位；原 leaf 已塌陷则 fallback 到第一个 `.tabs` 叶子，再不行替换 `.empty` 根 |
| `.setPinned(tabID:, isPinned:)` | 翻转 tab 的 `isPinned` 标记；`closeOthers` 永不波及 pinned tab |

每次 apply 自动 `version &+= 1` 并通知订阅者。

## 依赖

- 模型：`DockLayoutNode`、`DockController`、`DockOperation`、`DockLayoutSnapshot`
- 视图：`DockContainer`、`DockSatelliteView`、`DockTabBar`、`DockSplitter`、`DockHostBridge`
- 协调器：`DockHostCoordinator`（spawn / close 卫星窗口回调）

## 测试覆盖

- `DockLayoutTests` — 树构造与 IDs
- `DockControllerTests` — 操作语义、Codable
- `DockSerializationTests` — `DockOperation` 序列化
- `DockTabBarTests` / `DockSplitterTests` / `DockContainerLayoutTests` — 视图层
- `DockTabBarCrossWindowTests` — 跨窗口拖拽
- `DockLayoutSnapshotTests` — 持久化 round-trip
- `DockDetachThresholdTests` — 80px detach 距离阈值
- `DockSatelliteTitleBarTests` — 卫星窗口标题栏拖拽 redock
- `DockMoveLeafTests` — `.moveLeaf` 操作的 tabSlot/replace/splitEdge 三种目标 + cycle/no-op 守卫
- `DockEscCancelTests` — Esc 取消活跃 drag 的 PointerCapture 路由
- `DockLeafDragTests` — leaf-handle 拖拽端到端流程
- `DockTabCapabilityTests` — D9 能力位：`isClosable` 控制关闭按钮、`closeTab` 点击落地、右键转发到 `onTabContextMenu`、旧快照 Codable 兼容
- `DockAppearanceWiringTests` — Phase T：自定义 `DockStyle` 注入后 tab strip / 关闭按钮 / 分割条 / 卫星标题栏几何全部跟随 token 变化
- `DockGestureIntentTests` — Phase G：`pendingClick → reorderInStrip → detachOrSplit` 单调升级；`leaf-handle` 拖拽跳过 reorder 档直接到 lift
- `DockCloseHistoryTests` — Phase R.A：`closeOthers` / `closeToTheRight` / `reopenLastClosed` 语义、history FIFO 截断、reopen fallback 链
- `DockTabPinnedTests` — Phase O：`isPinned` 标记 + `setPinned` op + `closeOthers` 跳过 pinned tab + `decodeIfPresent` 旧快照兼容
- `DockCommandMenuTests` — Phase R.C：`defaultTabMenu(for:leafID:)` 描述符项齐全、enable 旗标随状态翻转、Pin/Unpin 标题切换、各 action 真正派发对应 op

## 卫星窗口标题栏

`DockSatelliteView` 顶部内嵌一条 `_DockSatelliteTitleBar`：

- 高 24pt，背景取自 theme 的 `surfaceVariant`，左侧显示当前 active tab 标题。
- 在标题栏按下并拖动超过 6px → 启动一个 `origin = .satellite(leafID)` 的 DockDragSession（`tabID == nil`，因为整个 leaf 一起搬）。
- 释放时 `DockDragSession.end(commit:)` 走 `.satellite` 分支：命中已注册的主 host leaf 即触发 `.redock(satelliteID:to:)` 并销毁卫星窗口；未命中则就地保留。
- 卫星窗口本身不在拖动期间移动；标题栏只承担「告诉 dock 这是一个 redock 拖拽源」的语义。

## 拖拽体验（D8）

- **Ghost 预览**：drag 期间，根容器 `overlayDraw` 在指针右下角绘制一块半透明深色矩形 + accent underline + 当前拖拽 tab/leaf 的标题文本（通过 `TextEnvironment.shape` + `TextLayout.layout` + `DrawList.addText`）。Ghost 跟随窗口本地坐标（已经过 HiDPI 转换），跨窗口拖拽时各窗口独立绘制各自的 ghost。
- **Esc 取消**：`EventDispatcher.dispatchKey` 在分发到 focused 节点之前，先把 key 事件交给当前 `PointerCapture.target` 的 key handler。Tab item / leaf handle / satellite title bar 三处 drag 源都注册了 `setKey(node)` 监听 `DOCK_KEY_SCANCODE_ESC`（SDL3 scancode 41），命中即释放 capture、清状态、`session.cancel()`，且不递增 `controller.version`。
- **整 leaf 拖拽**：tab strip 末端的 `Spacer()` 替换为 `_DockLeafDragHandle`（cursor `.move`，flexGrow=1）。在该区域按下并拖动 → `DockDragSession.start(tabID: nil, origin: .mainTreeLeaf(leafID))`，释放时走 `.moveLeaf(leafID:to:)`（命中其它 host leaf）或 `.detach(leafID)`（拖出所有 host 且超过 80px 阈值）。


## DockTab 能力位（D9）

`DockTab` 在原有 `id` / `userKey` / `title` 之外新增两个可选字段，允许调用方按 tab 单独配置 UI 行为：

| 字段 | 默认 | 含义 |
| ---- | ---- | ---- |
| `isClosable: Bool` | `true` | `false` 时 tab strip 不渲染 `×` 关闭按钮，关闭只能由调用方显式触发（例如右键菜单调用 `controller.apply(.closeTab(id))`）|
| `icon: DockTabIcon?` | `nil` | 可选小图标（`TextureID` + `width`/`height`），渲染在标题左侧；`Codable` 仅持久化 `assetKey` + 尺寸，运行时 `textureID` 由宿主在装载时重新解析 |

关闭按钮以独立的 hit-testable 子节点 `_DockTabCloseButtonHost` 实现，cursor 同样是 `.pointer`，但带 sentinel attachment `_DockTabCloseButtonHost.kCloseButtonMarker`，测试 helper 据此把关闭按钮从「tab item 节点」集合中排除。点击只响应 `.left` 按键，松手即 `controller.apply(.closeTab(tab.id))`，不影响 active tab 切换或拖拽状态。

右键（`MouseButton == .right`）在 tab item 的 pointer handler 中被截短：不获取 PointerCapture、不进入 drag 状态机，而是把 `(tabID, leafID, x, y)` 转发给 `controller.onTabContextMenu`。Dock 层不渲染弹出菜单 — popover/menu 基础设施目前不存在；调用方自行用 SDL 弹出原生菜单或在 GuavaUI 这一层后续补足时再绑定。

`DockTab` 的 `Codable` 实现使用 `decodeIfPresent` 容忍缺失字段，旧持久化快照（仅含 `id` / `userKey` / `title`）解码时新字段自动落到默认值。

## DockTab.isPinned（Phase O 模型层）

`DockTab` 又新增第三个能力位 `isPinned: Bool`（默认 `false`）：

- `controller.apply(.setPinned(tabID:, isPinned:))` 翻转标记；`Codable` 同样走 `decodeIfPresent`，旧快照解码后 `isPinned == false`。
- 模型语义：`closeOthers(in:, keep:)` 永远把 pinned tab 排除出 victim 集合，`keep` 参数仅决定哪个非-pinned tab 保留。
- 视图层（pinned tab 永远在前 + 与可滚动行分离 + 滚轮溢出 + `···` overflow 菜单）尚未落地，待 Popover/Menu 原语补齐后接通。

## 手势分级（Phase G）

`DockDragSession` 的 `intent: DragIntent` 表征当前拖拽强度，单调升级、永不下降：

| 值 | 触发条件 | 视觉契约 |
| -- | -------- | -------- |
| `.pendingClick` | session 未激活；指针仍在 4 px 阈值内 | 不渲染 ghost、不画 drop overlay |
| `.reorderInStrip` | tab item 拖动越过 `DOCK_REORDER_THRESHOLD = 4`（横向）但未达 lift | 同 leaf 重排：仅展示 ghost，不画 5 向 drop overlay |
| `.detachOrSplit` | 越过 `DOCK_LIFT_THRESHOLD = 12` 或纵向 `DOCK_LIFT_VERTICAL_THRESHOLD = 8` | 完整 5 向 edge indicator + 完整 ghost；leaf-handle 拖拽永远直接进入此档 |

`DockDragSession.escalateIntent(to:)` 是只升不降的入口；`DockDropOverlay.installDropOverlay` 只在 `intent == .detachOrSplit` 时才画 5 向 fill。

## 关闭历史与上下文菜单描述符（Phase R.A / R.C 模型层）

- `DockController.closedHistory: [ClosedTabRecord]` 是关闭操作的撤销栈（容量 `closedHistoryLimit`，默认 50，FIFO 截断）。`.closeTab` / `.closeOthers` / `.closeToTheRight` 在删除前按从左到右把 victim push 进栈；`.reopenLastClosed` 弹出末尾，按 `(sourceLeafID, originalIndex)` 复位，原 leaf 已塌陷则 fallback 到第一个 `.tabs` 叶子，再不行替换 `.empty` 根。
- `DockController.defaultTabMenu(for:leafID:) -> MenuDescriptor` 输出右键菜单的纯数据描述：Close Tab / Close Others / Close to the Right / Pin Tab(或 Unpin Tab) / Detach into New Window / Reopen Closed Tab，以及对应的 enable 旗标。dock 层不绘制菜单 — 调用方可直接传给 SDL 原生菜单或后续 GuavaUI 内部 Popover/Menu 原语渲染。Pin 项标题随当前 `isPinned` 自动切换。
