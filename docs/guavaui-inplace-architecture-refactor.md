# GuavaUI 底层架构原地重构方案

> 目标:**在现有 GuavaUICompose / GuavaUIRuntime 上原地重构底层架构**,根治几类反复出现的 bug,
> 全程保留现有组件库与编辑器可用。**不是**从零另起一套框架。
>
> GuavaKit(此前的从零实现)在本方案中**只作参照蓝图**——它是目标架构的干净样板,用来对照着改 GuavaUIRuntime,不作为终点、不再扩展、编辑器不切过去。
>
> 生成日期:2026-06-09

---

## 0. 为什么是"原地重构"而不是"从零重写"

现有 GuavaUI 是一套成熟框架:完整组件库(Panel / PropertyGrid / Tree / List / Select / TabView / SplitView / NumberField / Vec3Field / ColorField / JsonField / AssetRefField / ViewportHost…)+ 主题系统 + 动画 + dock 工作区 + 编辑器。这些积累了大量边角打磨。

从零重写会把这些打磨全部丢掉,并进入漫长的"重写低谷"(新表面长期不如旧框架,直到追平)。而那几类 bug 的**根因是架构层面的几条规则缺失**,完全可以**把规则原地补进现有实现**,无需推倒重来。

---

## 1. 现状架构(GuavaUIRuntime 核心)

每个 UI 元素由**四棵并行树**表示,靠手写同步保持一致:

| 树 | 类型 | 职责 | 文件 |
|---|---|---|---|
| Node 树 | `Node`(引用类型) | 几何 / 样式 / 树结构 / 脏标记 | `GuavaUIRuntime/Node.swift` |
| Layout 树 | `LayoutNode` | Yoga 布局输入,回写 `Node.frame` | `LayoutNode.swift` / `LayoutPass.swift` |
| Render 树 | `RenderObject` | 分层渲染缓存 | `RenderTree.swift` |
| Input 树 | `InputNode` / `InputScene` | 命中测试镜像 + 缓存 | `Input/InputScene.swift` / `HitTester.swift` |

`Node` 通过 `weak var layoutNode / renderObject / inputNode` 互连([Node.swift:61-73](../GuavaUI/Sources/GuavaUIRuntime/Node.swift#L61-L73))。

注册表 / 全局态(均为 `.current` 单例或 `static`):
- `InvalidationLogHolder.current`(失效日志)
- `InteractionRegistryHolder.current`(指针/悬停/键盘处理器登记)
- `FocusChainHolder.current`(焦点链)
- `PointerCaptureHolder.current`(指针捕获)
- `PortalRegistry`(`enum` + `static var storage`,弹层/菜单/工具提示)

声明导出:`ViewGraph`(reconciler,778 行)把声明式 `View` 物化成四棵树并驱动重组。

---

## 2. 病根分析(四类架构坏味 → 具体 bug)

### 坏味 #1 — 失效逻辑散落在各属性 `didSet`(→ "用一次就卡死")

`Node` 的每个几何/样式属性各写一份失效:
- `frame.didSet` 手动调 `inputNode?.scene?.invalidateHitCache()`([Node.swift:38-53](../GuavaUI/Sources/GuavaUIRuntime/Node.swift#L38-L53))
- `contentOffset.didSet` 调 `inputNode?.scene?.invalidateHitCache()`
- `zIndex.didSet` 走**另一条路** `parent?.inputNode?.scene?.invalidateHitCache()`([Node.swift:193-200](../GuavaUI/Sources/GuavaUIRuntime/Node.swift#L193-L200))
- 另有 ~12 个样式 `didSet` 各自调 `markRenderDirty`

**根因**:命中缓存(`InputScene`,键为"结构版本 + 点")只在 add/remove 时 bump 版本,**布局移动(仅改 frame)不 bump**。所以一旦忘了在某个 `didSet` 里手动失效缓存,resize/reflow 后命中测试继续返回旧几何下的结果 → 控件"点一次就不响应了"。`frame.didSet` 的注释([Node.swift:42-51](../GuavaUI/Sources/GuavaUIRuntime/Node.swift#L42-L51))**亲口承认了这个 bug**。
新增任何会移动节点的属性,都必须记得补这一行——这正是"卡死下拉"反复出现的结构性原因。

### 坏味 #2 — 多棵树靠手写同步(→ 漂移/陈旧状态)

`Node.reorderChildren` 要**手动**把 `renderObject.children` 和 `inputNode.children` 按新顺序重排([Node.swift:317-359](../GuavaUI/Sources/GuavaUIRuntime/Node.swift#L317-L359))。命中测试也有**两套走查**(Node 树 + InputScene 镜像,[HitTester.swift:34-129](../GuavaUI/Sources/GuavaUIRuntime/Input/HitTester.swift#L34-L129))。任一处同步漏掉 → 四棵树漂移、命中/渲染对不上。

### 坏味 #3 — 进程级可变单例(→ 一个陈旧项污染全局)

`PortalRegistry` 是 `enum` + `nonisolated(unsafe) private static var storage`([PortalRegistry.swift:30-33](../GuavaUI/Sources/GuavaUICompose/Primitives/Portal/PortalRegistry.swift#L30-L33)),`Holder.current` 同理。**不按窗口/上下文隔离**:一个窗口的陈旧弹层项会污染所有实例;多窗口或测试并发都不安全。`Node` 还整体 `@unchecked Sendable`。

### 坏味 #4 — 清理靠副作用(→ portal 泄漏)

弹层项的注销分散在**多条清理路径**:`_PopoverFrontmostModifier` 关闭时、以及 `ViewGraph` teardown 时,各自读 `popoverPortalEntryAttachmentKey` 去 `unregister`([PortalRegistry.swift:8-11](../GuavaUI/Sources/GuavaUICompose/Primitives/Portal/PortalRegistry.swift#L8-L11))。只要有一条 teardown 路径没走到那个 modifier,条目就**泄漏**(关了下拉但条目还在 → 下次卡住/重影)。清理依赖"某个 modifier 恰好执行",而不是绑定到节点生命周期。

---

## 3. 目标架构原则(从 GuavaKit 蓝图回填)

GuavaKit 已经验证这几条规则能让上述 bug **在架构上无法表达**。原地把它们补进 GuavaUIRuntime:

### 规则 1 — 几何通过唯一入口变更
所有几何变更(frame / contentOffset / zIndex / clipsToBounds)走**同一个内部函数**,该函数 diff 旧→新成失效标记集,并在**这一个地方**通知所有缓存(命中/渲染/布局)。删掉 ~15 处各自为政的 `didSet` 失效。参照 GuavaKit `UINode.setGeometry` + `Geometry.diff`。
→ 根除坏味 #1 与"卡死下拉"类。

### 规则 2 — 外部注册随节点生命周期释放
节点向外部登记的任何东西(portal 条目、指针捕获、输入处理器、焦点)都是一个**绑定到该节点的资源**;节点离开树(关闭/父级移除/面板切换,任意原因)时,detach 自动 `unmount` 全部资源。清理不依赖任何 modifier 执行。参照 GuavaKit `NodeResource` / `PortalResource`。
→ 根除坏味 #4 与"portal 泄漏"类。

### 规则 3 — 作用域,而非全局
注册表(portal / 命中索引 / 焦点 / 捕获 / 失效日志)归属**每窗口一个的上下文对象**,显式传递,不再是 `static` / `Holder.current`。一棵树的状态永远污染不到另一棵。参照 GuavaKit `UIContext`。
→ 根除坏味 #3。

### 规则 4 — 单一同步路径(收敛多树)
四棵树的增/删/重排只走**一条 reconciler 路径**,使部分更新不可表达;长期目标是收掉镜像树。
→ 根除坏味 #2。

---

## 4. 原地分期重构计划

每一期都保持**整包编译通过、全组件可用、测试绿**。

### Phase 0 — 护栏:先用"复现测试"钉死 bug 类(0.5–1 天)
- 对**现有框架**写出会失败的复现测试:reflow 后命中错位(卡死下拉)、teardown-while-open 后 portal 条目残留、多上下文互不污染。
- 这些测试就是验收基线:重构后必须 red→green,且全程不退化。

### Phase 1 — 几何单一入口(2–3 天)
- 在 `Node` 内部把 frame/contentOffset/zIndex/clipsToBounds 的写入收敛到一个 `applyGeometry(diff)` 函数;`didSet` 只调它,不再各写失效。
- 失效标记集统一驱动 命中缓存 / 渲染脏 / 布局脏。
- **公开 API 不变**(`node.frame = …` 照常),纯内部收敛 → 改动面可控。
- 验收:Phase 0 的"卡死下拉"测试转绿;现有渲染/命中测试不退化。

### Phase 2 — 资源随生命周期清理(2–3 天)
- 引入 `NodeResource` 协议(mount/unmount),`Node` 持有资源数组,`removeChild`/detach 时统一 unmount。
- 把 `PortalRegistry` 条目改成**节点持有的资源**:Popover/Menu/Tooltip 注册时挂资源,节点 detach 自动注销。删掉 `_PopoverFrontmostModifier` 等副作用清理路径。
- 验收:Phase 0 的"portal 泄漏"测试转绿。

### Phase 3 — 作用域化注册表(2–4 天)
- 引入每窗口的 `UIScope`(或复用现有 `InputScene` 扩成全量上下文),持有 portal / 命中索引 / 焦点 / 捕获 / 失效日志。
- 把 `PortalRegistry.static`、`*Holder.current` 逐个改为从 scope 取。先做兼容垫片(Holder 内部转发到当前 scope),再逐处替换调用点,最后删全局。
- 验收:多 scope 隔离测试转绿;去掉核心路径的 `nonisolated(unsafe)`。

### Phase 4 — 收敛多树同步(3–5 天,最难)
- 把 add/remove/reorder 的四树同步收进 reconciler 的单一路径,使"只更新了渲染树没更新输入树"不可表达。
- 评估能否收掉 InputNode 镜像(命中直接走 Node 树 + scope 缓存),减少一棵需要同步的树。
- 验收:reorder/teardown 压力测试下四树一致;命中与渲染顺序一致。

### Phase 5 — 验证 + 生产级清理(1–2 天)
- 跑全部 Phase 0 验收测试 + 现有套件。
- 生产级 pass:去掉核心 `@unchecked Sendable` / `nonisolated(unsafe)`、清掉 phase 脚手架式死代码、补关键路径文档与不变量注释。

---

## 5. GuavaKit(从零那套)取舍

原则:**留关键参照,删多余干扰**(按你的决定)。

**保留(作参照蓝图,重构期间不删)**
- `GuavaUI/Sources/GuavaKit/Architecture.md` —— 两条规则的权威表述
- `GuavaKit` 里 `Geometry`/`DirtyFlags`/`UINode.setGeometry`/`PortalResource`/`UIContext` 的干净实现 —— Phase 1–3 直接对照移植

**删除(走偏/多余,污染编辑器与认知)**
- `Editor/Sources/EditorApp/EditorShell.swift`(脚手架壳)
- `main.swift` 里的 GuavaKit 编辑器路径 `runGuavaKitEditor`,并**把默认切回 legacy**(`swift run EditorApp` 直接进真编辑器)
- 本次做进 GuavaKit 的 `Tree.swift`、`GuavaKitHost` 键盘/滚轮/渲染接线(legacy 已有自己的对应实现)
- GuavaKit 脚手架相关测试(`InputFocusTests`/`TreeTests` 中针对 GuavaKit 的部分)

> 待 GuavaUIRuntime 重构验收通过后,`GuavaKit` 整个 target 可作为最后一步删除(蓝图使命完成)。

---

## 6. 验证与生产级标准

### 6.1 bug 类验收(必须 red→green 且不退化)
1. reflow/resize 后命中测试不错位(下拉/按钮"点一次就不响应"消失)
2. teardown-while-open 后无 portal 条目残留
3. 多窗口/多 scope 状态互不污染
4. 四树在 reorder/teardown 后保持一致

### 6.2 生产级代码标准
- 几何失效**只有一条路径**;无法新增"忘了失效"的属性
- 外部注册**只由节点生命周期释放**;无 modifier 副作用清理
- 核心运行时**无进程级可变单例**;注册表按窗口作用域
- 多树**无手写部分同步**;增删重排走单一 reconciler 路径
- 核心去除 `@unchecked Sendable` / `nonisolated(unsafe)`(或有明确不变量注释)
- 现有组件库 + 编辑器全程编译通过、测试绿

---

## 7. 风险与约束

1. **四树同步(Phase 4)是最高风险**:InputScene 镜像 + RenderObject 分层缓存耦合深。控制:放最后,先用 Phase 0 的一致性测试兜底;能收镜像就收,收不动就只收敛同步路径。
2. **全局→作用域(Phase 3)触及面广**:`*Holder.current` 调用点散布在组件库各处。控制:先垫片转发、再逐处替换、最后删全局,每步可编译。
3. **公开 API 尽量不破**:Phase 1–2 纯内部收敛;若 Phase 3 需改 modifier/组件签名,先扩展兼容、保留旧 case。
4. **编辑器始终在 legacy 上跑**:重构期间编辑器不切框架,你随时能验证真编辑器是否退化。

---

## 8. 执行顺序(按你定的)

1. ✅ 本文档(重构计划)
2. ✅ 移除走偏代码(§5 删除项 + 默认切回 legacy)
3. ✅ 原地重构 GuavaUIRuntime 架构(Phase 0 → 5)
4. **你验证**:原编辑器依赖的 GuavaUI 组件 bug 是否解决 + 代码是否生产级 ← 当前在这里
5. 架构验收通过后:做新组件 + 对着 mockup 重设计编辑器 UI

---

## 9. 执行记录(2026-06-09 完成 step 2–3)

| 阶段 | 提交 | 内容 | 验收测试 |
|---|---|---|---|
| Step 2 | `4060202a` | 编辑器默认切回 legacy;删 `runGuavaKitEditor`/`EditorShell`/`Tree.swift`+`TreeTests`;`EditorApp` 去掉 `GuavaKitHost` 依赖。GuavaKit/GuavaKitHost 作蓝图保留。batch-6 面板按你的决定保留。 | — |
| Phase 0 | `4060202a` | `GeometryFunnelReproTests` 钉死"点一次就卡死":`clipsToBounds`/`isHitTestable` 运行时改动后命中缓存+输入镜像不失效(red)。 | red→green |
| Phase 1 | `4060202a` | `Node.invalidateGeometry` 单一入口,收敛 frame/contentOffset/zIndex/clipsToBounds/isHitTestable 的失效;公开 API 不变。 | 上面的 repro 转绿 |
| Phase 2 | `7bd9e323` | `NodeResource`(mount/unmount)+ `Node` 资源数组;`removeChild` 递归 unmount 整棵子树。Popover 改为节点持有的 `PortalResource`;删 `_PopoverFrontmostModifier` 与 ViewGraph 里的 attachment-key 清理。 | `NodeResourceTests` + 既有 `PopoverTests`(泄漏/churn/reopen) |
| Phase 3 | `e350e8d5` | Portal/Tooltip 存储下沉到每窗口实例(`PortalStore`/`TooltipStore`);`PortalRegistry`/`TooltipOverlayRegistry` 变转发垫片;`PlatformInputContext` 加 `ScopedAmbient` 钩子,`AppRuntime` 给每个窗口挂独立 `PortalStore`。 | `PortalScopeTests`(多 scope 隔离 + 嵌套 save/restore) |
| Phase 4 | `1d8f7002` | `Node.reorderChildren` 只重排 Node.children(唯一真源);渲染/输入镜像只由 reconciler 的 `reconcileChildren` 重建,删掉重复的手写镜像重排。 | `FourTreeConsistencyTests`(reorder/remove/insert 压力下三树不漂移) |
| Phase 5 | `d808a63b` | 验证全套(Runtime 174 / Compose 306+5 / Kit 蓝图 101 / App+Workspace XCTest 全绿;Editor 包编译通过);补 `@unchecked Sendable` / 每窗口 ambient 的不变量注释。 | 全套绿 |
| Phase 6 | `7b327530` | 把 §6.2"外部注册只由节点生命周期释放"补全:交互处理器 / tooltip 改为注册时挂的节点资源(`InteractionCleanupResource`/`TooltipCleanupResource`);指针捕获 / 焦点在 `Node.releaseFromTree` 集中释放(顺带修了 `PointerCapture.target` 强引用导致的捕获泄漏/卡死);`ViewGraph.tearDownSubtreeBookkeeping` 不再做任何外部注册清理。 | `NodeLifecycleCleanupTests`(含捕获泄漏修复) |
| Phase 7 | `e84e2e97` | **收掉 InputNode 镜像(四树→三树)**:删 `InputScene`/`InputNode` + `Node.inputNode` + ViewGraph 的镜像维护;命中测试只走活的 Node 树(`HitTester.hitTest(rootNode:)`),`EventDispatcher`/`FocusChain` 直接读 Node 的分类字段;DevTools 从活树算 inventory。命中缓存:不再引入进程级 ambient 缓存(那是 core path 上的坏味 #3、且并行测试互相打架),直接**去掉缓存**——每次命中重走 Node 树(O(节点) 的廉价矩形判定),于是 stale-hit(坏味 #1)在结构上无法发生(没有可失效的东西)。 | `GeometryFunnelReproTests` / `FourTreeConsistencyTests`(改为活 Node 模型) |
| Phase 8 | `597dd6de` | **删掉 `PortalRegistry`/`TooltipOverlayRegistry` 转发垫片**(Phase 3 的"最后删全局"):primitive 走 scoped ambient(`PortalStoreHolder`/`TooltipStoreHolder.current`),帧钩子显式读窗口 store(`host.tooltips` / `session.inputContext.tooltips`)。顺带修了垫片掩盖的两个跨 scope 隐患:① tooltip 的 `drawAll` 在 `withCurrent` 外跑、读的是 shared 默认 store,而 Button 注册进的是每窗口 store(注册/绘制不同实例→tooltip 不显示);② `PortalHostObserver`/`PortalResource` 注销走的是 deinit/unmount 时刻的 ambient,可能是别的窗口的 store——现在两者都(弱)记住注册时的 store 并在那里清理。 | 既有 portal/tooltip 套件全绿 |
| §5 final | `0b841955` | **删除 GuavaKit/GuavaKitHost 蓝图**(sources/tests/products/targets),Editor 去掉 GuavaKit 依赖 + 删孤儿 batch-6 面板(从未接进 legacy 编辑器);过时 "batch 6" TODO 改写为 TODO(editor-redesign)。蓝图使命完成,代码库回到单一 UI 栈。 | Runtime 168 / Compose 307 / App+Workspace+DevTools 绿;Editor 编译 |

**已知遗留**(非本次回归):GuavaUI 整包 `swift test`(swift-testing 侧)在并行下偶发 signal 11/5,崩在 image-decode / DevServer-socket 等无关用例,`--no-parallel` 仍现;HEAD 基线(改动全 stash)同样复现。用 `--filter <Suite>` 跑各套件稳定全绿。详见 memory `project-test-gotchas`。

**镜像已收掉**(Phase 7):`InputNode` 镜像已删除,四树收敛为三树(Node / Layout / Render)。命中测试直接走活的 Node 树。命中缓存被一并去掉(见 Phase 7 行)——若日后实测命中是热点,可加一个真正按窗口、由帧驱动失效的缓存(别用进程级 ambient)。

**`*Holder.current` ambient 保留**(有意为之,非垫片):它就是"每窗口 scope"的取用机制——存储按窗口,`withCurrent` 成对换入换出,不变量见 Phase 5 注释。把组件库 ~100 处调用改成显式传参会破坏公开 API(§7 约束 3)。

> step 2–3 + §5 全部完成。下一步:**你验收**(step 4)——跑真编辑器确认下拉/resize/捕获/hover/tooltip;通过后进 step 5(新组件 + 对着 mockup 重设计编辑器 UI)。
