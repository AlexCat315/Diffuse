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

## 卫星窗口标题栏

`DockSatelliteView` 顶部内嵌一条 `_DockSatelliteTitleBar`：

- 高 24pt，背景取自 theme 的 `surfaceVariant`，左侧显示当前 active tab 标题。
- 在标题栏按下并拖动超过 6px → 启动一个 `origin = .satellite(leafID)` 的 DockDragSession（`tabID == nil`，因为整个 leaf 一起搬）。
- 释放时 `DockDragSession.end(commit:)` 走 `.satellite` 分支：命中已注册的主 host leaf 即触发 `.redock(satelliteID:to:)` 并销毁卫星窗口；未命中则就地保留。
- 卫星窗口本身不在拖动期间移动；标题栏只承担「告诉 dock 这是一个 redock 拖拽源」的语义。
