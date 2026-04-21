# GuavaUI Phase 8.5 — Dock 系统详细设计（D 系列归档）

> 本文档归档 D0–D5 完成后的 Dock 系统设计与实现实情。
> 与 Phase 8 动画系统并行编号；Dock 不依赖动画运行时。
> 目标读者：实现者本人、未来代码评审者、Editor 蓝图后续阶段的对接者。

---

## 0. 范围与目标

**纳入 D 系列**：

1. 纯模型层：`DockLayoutNode` / `DockTab` / `DockController` / `DockOperation`
2. Codable 持久化：`DockLayoutSnapshot`（root + satellites + 顺序）
3. 视图层：`DockContainer` / `DockSatelliteView` / `DockTabBar` / `DockSplitDivider` / `DockDropOverlay`
4. 交互层：tab 拖拽重排、5 向边缘 dock、跨窗口 detach / redock
5. 多窗口基础设施：`SDL3PlatformHost` 的多窗口 API + `DockHostBridge` + `DockHostCoordinator`
6. Demo：`GuavaUIDemo`（单窗口三栏 + 持久化工具栏）+ `GuavaUIDemoDockMultiWindow`（真实跨窗口 detach 演示）

**不纳入 D 系列**（推迟）：

- Tab 上下文菜单（关闭其他 / 关闭右侧）
- 拖拽时 magnetic snap
- Tab 重命名 / 自定义图标
- Layout preset 的 JSON 手编 UI
- 卫星窗口的 redock 反向流程（卫星 → 主窗口 title-bar 拖回）
- Stacking / floating window manager（多卫星 z-order 规则）

---

## 1. 数据模型（D0）

### 1.1 Layout 节点

```swift
public indirect enum DockLayoutNode: Sendable, Codable {
    case split(id: DockNodeID, axis: DockSplitAxis, fraction: Float,
               first: DockLayoutNode, second: DockLayoutNode)
    case tabs(id: DockNodeID, tabs: [DockTab], activeTabID: DockTabID?)
    case empty(id: DockNodeID)
}
```

- `DockNodeID` / `DockTabID` 都是 UUID 包装；Codable，跨进程稳定。
- `DockTab.userKey: String` 是视图工厂的查找键 — dock 层 **永不持有** `View` 引用，从而模型保持 `Sendable + Codable`。
- `.split` 的 `fraction ∈ [0, 1]`，由 `DockSplitDivider` 拖拽更新，DockController 校正越界。

### 1.2 DockController

```swift
public final class DockController {
    public private(set) var root: DockLayoutNode
    public private(set) var satellites: [DockNodeID: DockLayoutNode]
    public private(set) var satelliteOrder: [DockNodeID]
    public private(set) var version: UInt64

    public func apply(_ op: DockOperation)
    public func replace(root:satellites:satelliteOrder:)
    public func subscribe(_ handler: @escaping (DockController) -> Void) -> Subscription
}
```

- 每次 `apply` / `replace` 自动 `version &+= 1` 并触发订阅者。
- 订阅快照：通知前 copy `subscribers` 字典，允许 handler 内取消订阅。
- 视图层通过 `version` 触发重组，避免传 `Binding<DockLayoutNode>` 整树 diff。

### 1.3 操作枚举

```swift
public enum DockOperation: Codable, Sendable {
    case insertTab(DockTab, into: DockNodeID, at: Int)
    case move(DockTabID, to: DockDropTarget)
    case removeTab(DockTabID)
    case activateTab(DockTabID, in: DockNodeID)
    case setSplitFraction(DockNodeID, fraction: Float)
    case spawnSatellite(leaf: DockNodeID, hint: SatelliteOriginHint)
    case closeSatellite(leaf: DockNodeID)
}
```

- `DockDropTarget`：`.insertTab(parent, index)` / `.splitEdge(parent, edge, fraction)` / `.replace(parent)`
- 模型自动维持不变量：空 `.tabs` collapse、单子 `.split` 替换为子节点、`activeTabID` 失效则取首个 tab。

---

## 2. 持久化（D5）

### 2.1 DockLayoutSnapshot

```swift
public struct DockLayoutSnapshot: Codable, Equatable, Sendable {
    public var root: DockLayoutNode
    public var satellites: [DockNodeID: DockLayoutNode]
    public var satelliteOrder: [DockNodeID]
    public var schemaVersion: Int      // 默认 1
}

extension DockController {
    public func snapshot() -> DockLayoutSnapshot
    public func load(_ snapshot: DockLayoutSnapshot)
}
```

- `init(from:)` 容忍缺省字段：缺 `satellites` → `[:]`；缺 `satelliteOrder` → `Array(satellites.keys)`；缺 `schemaVersion` → `currentSchemaVersion`。
- decode 后 `satelliteOrder` 自动 filter 掉 dict 里不存在的 ID（防 stale）。
- `[DockNodeID: DockLayoutNode]` 走 Swift 默认 keyed-array 编码（`[k, v, k, v, ...]`）— 损失一点可读性换取零自定义 coding 代码；后续若需要平铺可加 `userInfo` flag。

### 2.2 Demo 持久化

`GuavaUIDemo`：
- `DemoLayoutPersistence.save(_:) / .load() / .delete()` — `~/.guava/dock-demo.json`，原子写。
- 顶部工具栏 `Save / Load / Reset` 三个 ghost button。
- 启动时 `DockController` 初始化器自动尝试 `load()`，失败回落到 `makeDefaultLayout()`。

---

## 3. 视图层（D1 / D2）

### 3.1 DockContainer

```swift
DockContainer(controller: DockController,
              hostBridge: DockHostBridge? = nil,
              content: @escaping (String) -> AnyView)
```

- 内部递归把 `DockLayoutNode` 渲染为 `Box` + `DockSplitDivider` + `DockTabBar` + content。
- Drop overlay 是单层 `_DragGhostOverlay`，挂在容器根；拖拽期间显示 ghost 与 5 向 indicator。
- HiDPI 注意：layout / 命中走 logical size，scissor 在 `DrawListRenderer` 里统一乘 dpr 转 pixel。

### 3.2 DockTabBar

- 每个 tab 项是 `_DockTabBarItemHost` primitive。
- 拖拽进入：`setMotion` 闭包内 **lazy 读** `DockHostBridgeLocal`（必须 lazy — `_updateNode` 在 `parent.addChild` 之前执行，eager 读永远 nil；详见 repo memory `primitive-update-node-parent-chain`）。
- 跨窗口分支（`hostBridge != nil`）：调用 `session.start(globalX:globalY:origin:)` + `MainActor.assumeIsolated { session.updatePointerCrossWindow(...) }`。
- 同窗口 fallback：`session.updatePointer(x:y:registry:)`。

### 3.3 DockSplitDivider

- 自带 hover state；按下后 `setMotion` 走 fraction 计算，`controller.apply(.setSplitFraction(...))`。
- 双向 axis 共用一个 primitive，hit area 加宽到 8pt 提升可拖性。

---

## 4. 多窗口（D3 + D4）

### 4.1 SDL3PlatformHost 新 API

```swift
public func windowPosition(_ windowID: WindowID) -> (x: Float, y: Float)?
public func setWindowPosition(_ windowID: WindowID, x: Float, y: Float)
public func closeWindow(_ windowID: WindowID)   // delegates to shell?.destroyWindow
```

### 4.2 DockHostBridge

```swift
public final class DockHostBridge: Sendable {
    public init(originProvider: @escaping () -> (x: Float, y: Float),
                logicalSizeProvider: @escaping () -> (w: Float, h: Float),
                hostKind: HostKind)   // .main / .satellite(leafID)
}
```

- Composition local `DockHostBridgeLocal`，由 `_DockContainerRoot._updateNode` / `_DockSatelliteHost._updateNode` **显式** publish：
  ```swift
  node.setCompositionValue(DockHostBridgeLocal, hostBridge)
  ```
  不能用 `.compositionLocal()` modifier — modifier 包一层 wrapper node，子树能取到，但 host 自身在 `_updateNode` 里取不到（同 timing pitfall）。

### 4.3 DockHostCoordinator

```swift
public final class DockHostCoordinator {
    public var onSpawnSatellite: ((leafID: DockNodeID,
                                    snapshot: DockLayoutNode,
                                    originHint: (x: Float, y: Float)) -> Void)?
    public var onCloseSatelliteWindow: ((DockNodeID) -> Void)?
}
```

- 由 demo / Editor 实现，决定如何创建 SDL window + 渲染器。
- DockController 持有一个 coordinator 引用；`apply(.spawnSatellite(...))` / `apply(.closeSatellite(...))` 触发回调。

### 4.4 跨窗口拖拽流程

1. 主窗口 tab item 按下 → `DockDragSession.start(...)` 记录 origin。
2. 拖动超过阈值（当前 32px，TODO: 改 80px）→ session 进入 `.dragging` 态。
3. 每帧 motion 闭包：
   - `bridge` 非 nil → 转 global 坐标 → `session.updatePointerCrossWindow(globalX:globalY:registry:)`。
   - registry 询问所有已注册 bridge：命中谁的 logical rect → 设置 `dropHit`；都不命中 → `isOutsideAllHosts = true`。
4. 抬起：
   - `dropHit` 命中 → `controller.apply(.move(tabID, to: target))`。
   - `isOutsideAllHosts` → `controller.apply(.spawnSatellite(leafID, hint: lastGlobalPos))`。
5. Coordinator 创建新 SDL window，`DockSatelliteView(controller:leafID:hostBridge:)` 渲染。

---

## 5. Demo

### 5.1 GuavaUIDemo（单窗口）

- 三栏：Sidebar / Workspace / Inspector，hsplit fraction 0.18 / 0.74。
- 顶栏：导航 + Save / Load / Reset / Run / Inspect / 主题切换。
- `~/.guava/dock-demo.json` 自动 load 启动布局。

### 5.2 GuavaUIDemoDockMultiWindow（多窗口）

- 主窗口：`hsplit(0.45, .tabs([Outline, Properties]), .tabs([Log]))`。
- 拖拽任意 tab 出主窗口 → `coordinator.onSpawnSatellite` 触发 → 新 SDL window 在 origin hint 处打开。
- 卫星窗口关闭按钮 → `coordinator.onCloseSatelliteWindow` → `host.closeWindow(windowID)`。
- 共享 `SharedUIResources`（WGPU + 字体 atlas），每窗口一个 `DockWindowRenderer` 实例。

---

## 6. 测试矩阵

| Suite | 数量 | 关注点 |
| ----- | ---- | ------ |
| `DockLayoutTests` | 13 | 树构造、ID 唯一、Codable round-trip |
| `DockControllerTests` | 17 | apply 语义、collapse、replace |
| `DockSerializationTests` | — | DockOperation Codable |
| `DockTabBarTests` | — | 拖拽阈值、reorder |
| `DockSplitDividerTests` | — | fraction clamp、命中 |
| `DockContainerLayoutTests` | — | 递归布局、overlay 挂载 |
| `DockTabBarCrossWindowTests` | 3 | 跨窗口 origin 转换、isOutsideAllHosts |
| `DockLayoutSnapshotTests` | 4 | snapshot/load、JSON round-trip、容缺省、order filter |

全套：**318/318 通过**（截至 D5 收尾）。

---

## 7. 已知限制与后续工作

1. **拖拽阈值**：D6 已上调到 80px 全局欧氏距离，避免主窗口内小幅 hover 误 detach。
2. **卫星窗口 → 主窗口 redock**：D7 已落地。`DockSatelliteView` 顶部的 `_DockSatelliteTitleBar` 标题栏拖动会启动 `origin = .satellite(leafID)` 的 DockDragSession，命中已注册主 host leaf 即触发 `.redock`；卫星窗口在 `onCloseSatelliteWindow` 回调里被销毁。
3. **Bridge 自动 unregister**：D6 改为显式 API（`Node.dockHostID() -> DockHostID?`），由 host 在关闭窗口前调用 `coordinator.unregisterHost(_:)`。最初尝试的 `Node.deinit` + `onTeardown` 方案在 Swift 6 严格并发下崩溃（MainActor 闭包不能从任意线程的 deinit 触发），已记录为 repo memory `node-deinit-actor-isolation`。
4. **Snapshot keyed-array shape**：`[DockNodeID: DockLayoutNode]` 序列化为数组对，不便于人手编辑；若做 preset 编辑器可加扁平化 coder。
5. **Multi-window 持久化**：`GuavaUIDemoDockMultiWindow` 尚未接入 `DemoLayoutPersistence`；启动时不能恢复卫星窗口。

---

## 8. 关键陷阱（必读）

### 8.1 `_updateNode` 在 `addChild` 之前

`ViewGraph.materialisePrimitive` 在 `parent.addChild(node)` **之前** 调用 `view._updateNode(node)`。
所以在 `_updateNode` 里通过 `node.compositionValue(of:)` 取 composition local 永远只能看到 **本节点自身** 写入的值，父链上的 provider 无法触达。

**解决方法**：
- 如果要读父链上的 local，把读取移到事件回调闭包内（handlers 在树完整 wire 之后才会触发）。
- 如果要把 local 暴露给子树，且要求自身 `_updateNode` 也能取到，**显式** 在自身 `_updateNode` 里 `node.setCompositionValue(...)`，而不是依赖 `.compositionLocal()` 包装 modifier。

### 8.2 MainActor 隔离

`updatePointerCrossWindow` 标 `@MainActor`，但 `setMotion` / `setPointer` 闭包是 nonisolated。跨调用必须包 `MainActor.assumeIsolated { ... }`。

### 8.3 测试并发

涉及 `PointerCaptureHolder.current` / `AnimatorScheduler.shared` 等共享全局的 Dock / Animation 测试必须包 `GlobalTestLock.locked { ... }`，否则 swift-testing 并发跑会随机崩溃。

---

## 9. 文件总索引

模型 / 控制：
- `GuavaUI/Sources/GuavaUICompose/Dock/DockLayout.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockController.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockOperation.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockSerialization.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockLayoutSnapshot.swift`

视图 / 交互：
- `GuavaUI/Sources/GuavaUICompose/Dock/DockContainer.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockSatelliteView.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockTabBar.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockSplitDivider.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockDropOverlay.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockDragSession.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockHitRegistry.swift`

跨窗口：
- `GuavaUI/Sources/GuavaUICompose/Dock/DockHostBridge.swift`
- `GuavaUI/Sources/GuavaUICompose/Dock/DockHostCoordinator.swift`
- `GuavaUI/Sources/GuavaUIRuntime/SDL3PlatformHost.swift`（新增 windowPosition / setWindowPosition / closeWindow）

Demo：
- `GuavaUI/Sources/GuavaUIDemo/main.swift`
- `GuavaUI/Sources/GuavaUIDemo/DemoLayoutPersistence.swift`
- `GuavaUI/Sources/GuavaUIDemoDockMultiWindow/main.swift`

文档：
- `docs/components/dock.md`
- `docs/guava-ui-phase8.5-dock-design.md`（本文）
