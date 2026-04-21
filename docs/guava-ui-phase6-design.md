# GuavaUI Phase 6 — Compose API + 输入事件管道 详细设计

> 本文档是 `guava-ui-blueprint.md §11 Phase 6` 的展开实现规约。
> 目标读者：实现者本人、未来的代码评审者。
> 不重复蓝图里已经定调的内容，只补充落地决策、文件清单、接口签名、验收标准。

---

## 0. 范围与目标

**纳入 Phase 6**：

1. 输入事件管道：SDL3 raw event → InputEvent → HitTest → 派发 → State 写入 → Recompose
2. Compose 内核：`View` / `@ViewBuilder` / `ViewModifier` 三元组
3. 静态组件：`Text` / `Image` / `Box` / `Row` / `Column` / `Spacer` / `Divider`
4. 交互组件：`Button` / `ScrollView`
5. 修饰符：`.padding` / `.background` / `.foreground` / `.frame` / `.clip` / `.onTapGesture`
6. Compose ↔ Runtime 绑定层：把 `View.body` 展开成 `Node` + `LayoutNode` 子树

**不纳入 Phase 6**（属于 Phase 7 或更后）：

- `List` / `Tree` / `Tabs` / `SplitView` / `PropertyGrid` / `ContextMenu`
- `DockContainer` / `Panel` / `ViewportHost`
- 拖拽 / IME / 富文本编辑
- 多窗口实现（仅满足接口前瞻约束，见 §1）
- 主题系统（用 `CompositionLocal` 兜底，不做 `Theme` 树）
- 动画系统（独立放 §11，见下）
- 完整样式集（M3 仅最小子集，扩展放 Phase 7，见 §10）

---

## 1. 窗口策略约束（来自 blueprint §9.4）

Phase 6 一切新建接口必须满足：

| 约束 | 体现 |
|------|------|
| 无 `Recomposer.shared` | `Recomposer` 由 `SDL3PlatformHost` 持有，移除 `static let shared` |
| `NodeTree` 显式传递 | 所有新增 API 接收 `NodeTree` 或上下文对象，不读全局 |
| `InputEvent` 携带 `WindowID` | `typealias WindowID = UInt32`，默认值 `0` |
| `EventDispatcher` 实例化 | `init(tree: NodeTree)`，每窗口一个 |

迁移既有 `Recomposer.shared` 调用点：单一调用点在 `SDL3PlatformHost.run`，
迁移成本可忽略。`State.swift` 内部当前也走 `.shared`，需要改成通过
`CompositionLocal` 注入或在 `View` 上下文里读取。

---

## 2. 文件清单

### 2.1 GuavaUIRuntime（事件管道，无 Compose 依赖）

```
GuavaUI/Sources/GuavaUIRuntime/
├── input/
│   ├── WindowID.swift           # typealias + 默认值
│   ├── InputEvent.swift         # 已存在于 PlatformShell；这里包装成 UI 层语义事件
│   ├── PointerEvent.swift       # pointer down/move/up/cancel
│   ├── KeyEvent.swift           # key down/up/repeat
│   ├── WheelEvent.swift
│   ├── HitTester.swift          # 在 LayoutNode 树上做 z-order 命中
│   ├── EventDispatcher.swift    # capture / target / bubble 三阶段派发
│   ├── PointerCapture.swift     # 显式捕获 API（拖拽必备）
│   ├── FocusChain.swift         # 当前 focus node + 焦点遍历顺序
│   └── InteractionRegistry.swift # 节点 ↔ handler 映射
├── Node.swift                   # +interactionFlags（hitTestable / focusable）
└── SDL3PlatformHost.swift       # 重构：移除 .shared、串联 EventDispatcher
```

### 2.2 GuavaUICompose（声明式层）

```
GuavaUI/Sources/GuavaUICompose/
├── core/
│   ├── View.swift               # public protocol View { associatedtype Body: View; @ViewBuilder var body: Body { get } }
│   ├── ViewBuilder.swift        # @resultBuilder
│   ├── ViewModifier.swift
│   ├── ModifiedContent.swift    # struct ModifiedContent<Content, Modifier>: View
│   ├── EmptyView.swift
│   ├── TupleView.swift
│   ├── AnyView.swift            # 类型擦除盒，给 Recomposer 用
│   └── ViewGraph.swift          # View → Node 子树的展开器（核心）
├── modifiers/
│   ├── PaddingModifier.swift
│   ├── BackgroundModifier.swift
│   ├── ForegroundModifier.swift
│   ├── FrameModifier.swift
│   ├── ClipModifier.swift
│   └── OnTapModifier.swift
├── primitives/
│   ├── Box.swift
│   ├── Row.swift                # 内部就是 Box(flexDirection: .row)
│   ├── Column.swift
│   ├── Spacer.swift
│   ├── Divider.swift
│   ├── Text.swift
│   ├── Image.swift
│   ├── Button.swift
│   └── ScrollView.swift
└── Renderer.swift               # ViewGraph + LayoutPass + DrawList 的胶水
```

### 2.3 测试

```
GuavaUI/Tests/GuavaUIRuntimeTests/
├── HitTesterTests.swift
├── EventDispatcherTests.swift
└── FocusChainTests.swift

GuavaUI/Tests/GuavaUIComposeTests/    # 新 testTarget
├── ViewBuilderTests.swift
├── ModifierChainTests.swift
├── ViewGraphTests.swift
├── ButtonInteractionTests.swift     # 端到端：模拟 PointerDown → State 变化 → 重组
└── ScrollViewTests.swift
```

---

## 3. Phase 6 子阶段与依赖顺序

| 子阶段 | 内容 | 依赖 |
|--------|------|------|
| **6.0 Runtime 接口去单例化** | 移除 `Recomposer.shared`；`State` 改成通过 `EnvironmentValues` 拿 recomposer | 无 |
| **6.1 输入事件管道** | `WindowID` / 三类事件 / `HitTester` / `EventDispatcher` / `PointerCapture` / `FocusChain` | 6.0 |
| **6.2 Compose 内核** | `View` / `ViewBuilder` / `ViewModifier` / `ModifiedContent` / `ViewGraph` | 6.0 |
| **6.3 静态组件 + 修饰符** | Text / Image / Box / Row / Column / Spacer / Divider + Padding/Background/Foreground/Frame/Clip | 6.2 |
| **6.4 交互组件** | Button（onTap）/ ScrollView（pointer drag + wheel） | 6.1 + 6.3 |
| **6.5 GuavaUIDemo 升级** | 重写 demo：用 Compose 写一个最小三面板原型（不用 Dock，用 Row + Column 凑） | 6.4 |

---

## 4. 关键接口签名

### 4.1 输入事件

```swift
// WindowID.swift
public typealias WindowID = UInt32
public extension WindowID {
    static let main: WindowID = 0
}

// PointerEvent.swift
public enum PointerPhase: Sendable { case down, move, up, cancel }
public enum PointerButton: Sendable { case left, right, middle, other(UInt8) }

public struct PointerEvent: Sendable {
    public let windowID: WindowID
    public let phase: PointerPhase
    public let button: PointerButton
    public let position: CGPoint        // 窗口本地坐标，单位像素
    public let modifiers: KeyModifiers
    public let timestamp: UInt64        // 平台时基纳秒
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}
```

### 4.2 命中测试

```swift
// HitTester.swift
public struct HitResult {
    public let node: Node
    public let localPoint: CGPoint   // 命中节点本地坐标
}

public struct HitTester {
    /// z-order：兄弟节点中 children 数组末尾在上层；先序逆序遍历。
    /// 跳过 isHitTestable == false 的节点；frame 不包含点的子树整体跳过。
    public static func hitTest(_ tree: NodeTree, point: CGPoint) -> HitResult?
}
```

`Node` 增加：

```swift
public extension Node {
    var isHitTestable: Bool { get set }     // 默认 true
    var isFocusable: Bool   { get set }     // 默认 false
    var clipsToBounds: Bool { get set }     // 默认 false；true 时子树不会命中超出 frame 的部分
}
```

### 4.3 派发器

```swift
// EventDispatcher.swift
public final class EventDispatcher {
    public init(tree: NodeTree, focusChain: FocusChain, capture: PointerCapture)

    public func dispatch(pointer event: PointerEvent)
    public func dispatch(key event: KeyEvent)
    public func dispatch(wheel event: WheelEvent)
}
```

派发顺序：`capture(root → target)` → `target` → `bubble(target → root)`。
`PointerCapture` 在 down 时可由 handler 调用 `capture.acquire(node)` 锁定后续 move/up 直接走该 node。

### 4.4 InteractionRegistry

不在 `Node` 上塞 closure 字段（侵入大），改用外挂注册表：

```swift
// InteractionRegistry.swift
public final class InteractionRegistry {
    public init()

    public func setOnPointer(_ node: Node, _ handler: @escaping (PointerEvent, EventPhase) -> EventResult)
    public func setOnKey(_ node: Node,     _ handler: @escaping (KeyEvent,     EventPhase) -> EventResult)
    public func setOnWheel(_ node: Node,   _ handler: @escaping (WheelEvent,   EventPhase) -> EventResult)
    public func remove(_ node: Node)
}

public enum EventPhase: Sendable { case capture, target, bubble }
public enum EventResult: Sendable { case handled, ignored }
```

`Compose` 层的 modifier（`.onTapGesture` 等）落地时通过它注册。

### 4.5 Compose 内核

```swift
// View.swift
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

// 终止递归的两个 View
public struct EmptyView: View {
    public typealias Body = Never
    public init() {}
}
extension Never: View { public typealias Body = Never }

// ViewBuilder.swift
@resultBuilder
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView
    public static func buildBlock<C: View>(_ c: C) -> C
    public static func buildBlock<each C: View>(_ c: repeat each C) -> TupleView<(repeat each C)>
    public static func buildIf<C: View>(_ c: C?) -> C?
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F>
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F>
}
```

> Swift 6 `each` 参数包可以替代 `buildBlock<C0,C1,...,C10>` 那一坨重载。

### 4.6 ViewGraph（Compose → Node 桥梁）

这是 Phase 6 工程量最大的部分，**单独立项设计**：

```swift
// ViewGraph.swift
public final class ViewGraph {
    public init(tree: NodeTree, recomposer: Recomposer)

    /// 用 root view 构建初始树。
    public func install<V: View>(root: V)

    /// 由 Recomposer 在状态变化后调用，按受影响的 scope 重新计算子树。
    public func recompose(scope: ScopeID)
}
```

实现要点：

- 每个 `View` 在树上对应一个 `ViewScope`（节点 + body 闭包 + 依赖的 State 列表）
- `body` 求值期间通过 thread-local 收集 `State` 读取，建立依赖
- 重组时 diff 新旧 `View`：相同位置的相同类型 → 复用 `Node`，更新属性；否则销毁重建
- `Modifier` 不产生新 `Node`，作为属性叠加
- 容器 View（`Box` / `Row` / `Column`）创建一个带 `LayoutNode` 的 Node
- 叶子 View（`Text` / `Image`）创建一个挂 draw 回调的 Node

### 4.7 修饰符示例

```swift
// PaddingModifier.swift
public struct PaddingModifier: ViewModifier {
    public let insets: EdgeInsets
    public func apply(to node: LayoutNode) {
        node.padding(.all, insets.top)   // 简化：四边一致；EdgeInsets 支持四边时分别设
    }
}

public extension View {
    func padding(_ value: Float) -> some View {
        modifier(PaddingModifier(insets: EdgeInsets(all: value)))
    }
}
```

---

## 5. SDL3PlatformHost 重构

**前**：

```swift
host.onFrame = { _ in /* user submits draws */ }
recomposer.commitAll()
tree.flush()
```

**后**：

```swift
public final class SDL3PlatformHost: PlatformHost {
    public let recomposer: Recomposer            // 改成实例字段
    public let tree: NodeTree
    public let dispatcher: EventDispatcher
    public let interactions: InteractionRegistry
    public let focusChain: FocusChain

    public init(title: String) {
        self.recomposer = Recomposer()
        self.tree = NodeTree()
        self.focusChain = FocusChain()
        self.interactions = InteractionRegistry()
        let capture = PointerCapture()
        self.dispatcher = EventDispatcher(
            tree: tree, focusChain: focusChain,
            capture: capture, interactions: interactions
        )
    }

    public func run<V: View>(rootView: V) {
        let viewGraph = ViewGraph(tree: tree, recomposer: recomposer,
                                  interactions: interactions)
        viewGraph.install(root: rootView)

        // 主循环
        while host.isRunning && _isRunning {
            recomposer.commitAll()
            tree.flush()                          // layout pass

            for raw in host.pollEvents() {
                if let ui = mapToUIEvent(raw) {
                    dispatcher.dispatch(ui)
                }
            }

            // 渲染
            renderer.render(...)
        }
    }
}
```

旧的 `run(tree:)` 入口保留作为低级 API，给不想用 Compose 的纯 DrawList 用户用。

---

## 6. 关键决策记录（ADR-style）

### ADR-1：handler 不放在 Node 上

理由：Node 已是引用类型且不知道 Compose 的存在。把 closure 挂上去会让
Runtime 反向依赖 interaction 概念，且阻碍 Node 的可序列化（远期需求）。
改用 `InteractionRegistry` 字典外挂。

### ADR-2：Recomposer 去 `.shared` 但保留 `init()`

理由：兼容已有的 RecomposerTests（独立实例化），并满足窗口前瞻约束。
状态写入路径需要拿到对应实例 —— 通过 `DynamicProperty.update(in:)` 注入
当前 `ViewGraph` 的 recomposer 引用。

### ADR-3：Phase 6 不实现 SDF 圆角

理由：当前 `DrawList.addRoundedRect` 用三角形扇近似已够用，shader 改造放
Phase 7 之后做。Phase 6 不动 GPU 层。

### ADR-4：ViewBuilder 用 `each` 参数包

理由：避免重载爆炸；要求 Swift 6+，仓库 Package.swift 已 `swift-tools-version: 6.0`。

### ADR-5：单元测试用 `swift-testing`，不引入 XCTest

理由：仓库现有测试已统一用 `Testing` 框架。

---

## 7. 验收标准

每个子阶段独立验收：

### 6.0
```bash
swift test --filter RecomposerTests   # 旧测试全过；Recomposer.shared 全删
grep -r "Recomposer.shared" GuavaUI/  # 应为空
```

### 6.1
```bash
swift test --filter HitTesterTests EventDispatcherTests FocusChainTests
# 至少覆盖：z-order 命中、capture/bubble 顺序、PointerCapture 锁定、focus tab 顺序
```

### 6.2
```bash
swift test --filter ViewBuilderTests ModifierChainTests ViewGraphTests
# 覆盖：buildBlock/buildIf/buildEither、Modifier 叠加、State 变化触发子树重组
```

### 6.3 + 6.4
```bash
swift test --filter ButtonInteractionTests ScrollViewTests
# Button：模拟 PointerDown→Up，State 切换，body 重新执行
# ScrollView：wheel 滚动，contentOffset 更新，子节点 frame 跟随
```

### 6.5（M3 出口）
```bash
swift run GuavaUIDemo
# 窗口出现：左侧 Tree-like 列、右侧 Inspector-like 列、底部 Console-like 列
# 点击列表项：右侧内容刷新；点击 Button：计数器 +1；ScrollView 可滚动
# 关闭无崩溃；FPS ≥ 60；CPU 空闲帧 < 5%
```

---

## 8. 风险与对策

| 风险 | 对策 |
|------|------|
| `each` 参数包在某些 ViewBuilder 场景下推断不出 | 保留 `buildBlock` 1–10 元的传统重载作为后备 |
| ViewGraph diff 算法首版做错 | 第一版只做"位置 + 类型相同则复用"，不做 key 重排；Phase 7 再优化 |
| 输入事件坐标系混乱（DPI 缩放） | `PointerEvent.position` 始终是物理像素；DPI 由 Renderer 单点处理 |
| State 写入死循环（重组中再写入） | `Recomposer.invalidate` 内部加 reentrancy 守护，本帧重复写同 scope 直接 dedupe |
| 测试覆盖不到真实 SDL 事件 | 在 `EventDispatcher` 上加 `dispatch(_ event:)` 公共入口，测试用合成事件直接喂 |

---

## 9. 与 Phase 7 的接口预留

Phase 7 要做的 `DockContainer` / `ViewportHost` / `List` 都依赖：

- `View` + `ViewModifier` 内核（6.2 给）
- `EventDispatcher` + `PointerCapture`（6.1 给，拖拽分割条会用）
- `ScrollView`（6.4 给，List 内核就是虚拟化的 ScrollView）
- `ViewGraph` 增量更新（6.2 给，长列表性能依赖）

Phase 6 不需要为 Phase 7 单独埋接口，按上述清单交付即可。

---

## 10. 样式系统

### 10.1 核心定位

GuavaUI 不引入独立的 CSS-style 表（避开"两套真相"问题）。
**所有视觉属性 = `ViewModifier`**。这是 SwiftUI 的路线，不是 CSS 路线。
对应关系：

| CSS / Web 概念 | GuavaUI 实现 |
|---------------|--------------|
| `class`、`stylesheet` | `extension View { var primaryButton: some View { ... } }` 复用闭包 |
| `:hover` / `:active` | `.onHover { ... }` / Button 内部 PressedState |
| `var(--foo)` 主题变量 | `EnvironmentValues` + `CompositionLocal`（Phase 7 系统化） |
| 继承（`color: inherit`） | `Environment` 自然向下传递 |
| 内联 `style="..."` | 链式 modifier 调用 |

### 10.2 样式属性归类

按"哪一层负责"切分：

| 层 | 属性 | M3 是否实现 |
|----|------|------------|
| **Layout（LayoutNode/Yoga）** | width/height/padding/margin/flex/align | ✅ 6.3 |
| **Box decoration（DrawList）** | backgroundColor / cornerRadius / border / shadow / opacity | 部分 ✅（background/foreground/clip） |
| **Text（DrawList glyph）** | font / fontSize / fontWeight / color / lineHeight / textAlign | 仅 fontSize+color（6.3） |
| **Transform（DrawList matrix）** | translate / rotate / scale | ❌ Phase 7 |
| **Effects** | blur / colorMatrix / blendMode | ❌ Phase 8（依赖 shader 改造） |

### 10.3 M3 实际交付的样式 modifier

```swift
.padding(_:)                     // 四边或单边
.frame(width:height:alignment:)
.background(_ color: Color)
.foregroundColor(_ color: Color)  // Text/Image 着色
.cornerRadius(_:)                 // 与 .clip 协同
.clip()
.opacity(_:)                      // 简单 alpha，Phase 6 加（成本低）
.font(_ font: Font)               // 仅 size + weight，无字体族切换
```

后续 Phase 7+ 增量补：`.shadow` / `.border` / `.rotationEffect` / `.scaleEffect` /
`.blur` / `.gradient`。每个新 modifier 独立 commit，不需要回头改内核。

### 10.4 主题（Theme）

M3 不做 Theme 树。颜色直接硬编码在 demo / Editor 里。
Phase 7 引入 `EnvironmentValues.colorScheme` + `EnvironmentValues.theme: Theme`，
通过 `.environment(\.theme, .dark)` 注入。**modifier 永远是真相**，
Theme 只是注入默认值。

### 10.5 ADR-6：不做 CSS-like 选择器

理由：编辑器场景下 UI 树小、组件复用靠 Swift 函数即可。引入选择器 = 引入
全局副作用、级联、特异性计算，与 Compose 单向数据流相悖。如果将来要做
"用户自定义皮肤"，方案是导出 `Theme` 结构体让用户填字段，而不是匹配规则。

---

## 11. 动画系统

### 11.1 不在 Phase 6 实现

Phase 6 一切 modifier 立即生效，**无任何插值**。Demo 和 Editor 在 M3
不依赖动画也能完整工作。

### 11.2 何时实现

- **Phase 7（隐式动画）**：`.animation(_ animation: Animation, value: V)` —— SwiftUI 风格，状态变化时自动插值
- **Phase 8（显式动画 + 关键帧）**：`withAnimation { state.x = ... }` / `Animation.keyframes(...)`

### 11.3 关键设计预留（Phase 6 必须做对的）

为不让动画后期重写内核，Phase 6 需保证：

1. **每帧渲染**：`SDL3PlatformHost.run` 主循环已是"每帧 commit→flush→render"，
   动画引擎只需在 commit 前推进一次插值，无需改循环结构。
2. **DrawList 每帧重建**：当前实现就是这样，动画修改属性 → 下一帧 DrawList
   自然反映，零额外机制。
3. **Modifier 是值类型**：所有 style modifier 用 `struct`，方便插值器比较新旧值。
   Phase 6 设计接口时强制这一点。
4. **Recomposer 支持每帧 tick**：增加 `recomposer.tick(now: UInt64)` 接口
   （Phase 6 留空实现，Phase 7 注入动画驱动）。

### 11.4 ADR-7：动画走 Recomposer，不走 Renderer 线程

理由：插值结果会改变 layout（例如 width 动画），必须走 layout pass。
不能像 CSS Transform 那样在合成层短路。代价是性能上限低于浏览器，
但编辑器场景 UI 量小，可接受。

### 11.5 不做的事

- CSS keyframes 字符串语法
- CSS transition timing function 字符串（用 `Animation.easeInOut` 等枚举）
- Web Animations API 兼容
- GPU-only transform 加速（统一走 layout，简化模型）

---

## 12. 实施顺序与时间盒

按 §3 子阶段顺序推进。每个子阶段独立 commit，独立通过验收。
不预估时间。完成 6.5 后才算 Phase 6 done，进入 Phase 7。
