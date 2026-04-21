# GuavaUI Phase 8 — 动画系统详细设计

> 本文档是 `guava-ui-blueprint.md` 与 Phase 7.5 收尾的延续，为 Phase 8 动画系统给出完整落地规约。
> 目标读者：实现者本人、未来代码评审者。
> 不重复提案讨论里已经定调的内容，只补充：API 终态、文件清单、接口签名、验收标准、测试矩阵。

---

## 0. 范围与目标

**纳入 Phase 8**：

1. 显式动画 API：`withAnimation(_:body:)`
2. 隐式动画 API：`.animation(_:value:)` modifier
3. 动画值类型：`Animation` / `AnimationCurve` / `SemanticMotionRef`
4. 插值协议：`Interpolatable` + 基础类型实现（`Float` / `Double` / `Color` / `LayoutFrame` / `Insets`）
5. 运行时调度：`AnimationController` / `AnimatorScheduler`
6. 帧驱动接入：`PlatformShell.onFrame(deltaTime:)` 调用 scheduler tick
7. 可动画属性：`opacity` / `backgroundColor` / `foregroundColor` / `cornerRadius` / `frame` / `padding`
8. Style 内置过渡：`PrimaryButtonStyle` 等内建 style 自动 cross-fade hover / press
9. Demo 验证：Phase 7.5 demo 中 `.appearance` 切换通过 `withAnimation` 实现整树渐变换肤

**不纳入 Phase 8**（推迟）：

- Spring 物理动画 → Phase 8.5
- 关键帧 / 时间线序列 → Phase 9
- Transaction（SwiftUI 用作动画 + 其他元数据通道）→ 视需要再加
- Layout-shape morph（如圆 → 方）→ 不打算做
- Gesture-driven scrub → 等 hover / gesture 系统就绪
- 主题切换的 snapshot cross-fade（旧主题画一帧 + 新主题画一帧叠化）→ Phase 8.5

---

## 1. 设计原则

| 原则 | 含义 |
|------|------|
| 与 Compose 状态双驱动 | Recomposer 决定结构与目标值，Animator 只在帧上写瞬时渲染值，不触发 recompose |
| 默认即可看 | 任何 Style 默认实现内置一档 hover / press 过渡，无需用户调用动画 API |
| Token 驱动 | duration / easing 来自 `Theme.motion`，不写 magic 数字 |
| 取消可预测 | 同 Node 同属性的新动画从「当前瞬时值」起步到目标值，旧 controller 直接丢弃（保守策略） |
| 单线程 | 所有调度跑在 MainActor；动画状态不跨 Task 暴露 |
| Runtime 隔离 | 调度器与控制器落 `GuavaUIRuntime`，Compose 层只暴露值类型与 modifier；与 RHI / Render 解耦 |

---

## 2. 文件清单

```
GuavaUI/Sources/GuavaUIRuntime/Animation/
├── Animation.swift              # Animation / AnimationCurve / SemanticMotionRef
├── Interpolatable.swift         # protocol + 基础类型扩展
├── AnimationController.swift    # 单条动画状态机
├── AnimatorScheduler.swift      # 全局 tick 入口 + 活跃链表
├── ActiveAnimationContext.swift # thread-local "current animation" 槽位
└── AnimatableProperty.swift     # Node 上挂载的弱引用 controller 表

GuavaUI/Sources/GuavaUICompose/Animation/
├── AnimationModifier.swift      # .animation(_:value:) modifier
├── WithAnimation.swift          # 顶层 withAnimation(_:body:) 函数
└── BuiltinAnimatableProps.swift # 给 .opacity / .background / .frame 等 modifier 接动画

GuavaUI/Sources/GuavaUICompose/Theme/
└── SemanticMotion.swift         # SemanticMotionRef.fast/.medium/.slow 静态

GuavaUI/Sources/PlatformShell/
└── SDL3PlatformHost.swift       # onFrame 内调用 AnimatorScheduler.shared.tick(deltaTime:)

GuavaUI/Tests/GuavaUIRuntimeTests/
└── AnimationTests.swift         # 值类型 + Interpolatable + 控制器单测

GuavaUI/Tests/GuavaUIComposeTests/
├── AnimationModifierTests.swift # .animation(_:value:) 行为
├── WithAnimationTests.swift     # withAnimation 路径
└── AnimationIntegrationTests.swift # 端到端：mock 时钟步进 + 状态变化 + 瞬时值断言
```

---

## 3. API 终态

### 3.1 值类型

```swift
public struct Animation: Sendable, Equatable {
    public let duration: Double      // seconds
    public let curve: AnimationCurve
    public let delay: Double          // seconds, 0 默认

    public init(duration: Double,
                curve: AnimationCurve = .easeInOut,
                delay: Double = 0)

    public static let `default`: Animation       // = .easeInOut, 0.25s
    public static let linear: Animation          // = .linear, 0.25s
    public static let easeIn: Animation
    public static let easeOut: Animation
    public static let easeInOut: Animation

    public static func semantic(_ ref: SemanticMotionRef) -> Animation
}

public enum AnimationCurve: Sendable, Equatable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case cubicBezier(Float, Float, Float, Float)

    /// 把归一化时间 t ∈ [0,1] 映射为归一化进度 p ∈ [0,1]
    public func evaluate(_ t: Float) -> Float
}

public struct SemanticMotionRef: Sendable {
    let resolve: @Sendable (Theme) -> Animation
    public init(_ resolve: @escaping @Sendable (Theme) -> Animation)
}

public extension SemanticMotionRef {
    static let fast: SemanticMotionRef    // → Theme.motion.fast
    static let medium: SemanticMotionRef
    static let slow: SemanticMotionRef
}
```

### 3.2 Interpolatable 协议

```swift
public protocol Interpolatable {
    static func interpolate(_ a: Self, _ b: Self, t: Float) -> Self
}

extension Float: Interpolatable { … }
extension Double: Interpolatable { … }
extension Color: Interpolatable { … }          // RGBA 通道线性
extension LayoutFrame: Interpolatable { … }     // 各分量线性
extension Insets: Interpolatable { … }
```

### 3.3 显式 / 隐式 API

```swift
// 显式：闭包内的状态写入应用 animation
@MainActor
public func withAnimation<R>(
    _ animation: Animation = .default,
    _ body: () throws -> R
) rethrows -> R

// 隐式：value 变化时自动起一段动画
public extension View {
    func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View
}
```

### 3.4 Style 集成示例

```swift
public struct PrimaryButtonStyle: ButtonStyle {
    public func makeBody(_ c: ButtonStyleConfiguration) -> AnyView {
        let bg: Color = {
            if !c.isEnabled { return c.theme.colors.surfaceVariant }
            if c.isPressed  { return c.theme.colors.accent.darker(0.10) }
            if c.isHovered  { return c.theme.colors.accent.lighter(0.06) }
            return c.theme.colors.accent
        }()
        return AnyView(
            c.label
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(bg)
                .cornerRadius(c.theme.radius.sm)
                .animation(.semantic(.fast), value: bg)   // 内置过渡
        )
    }
}
```

---

## 4. Runtime 调度

### 4.1 控制器

```swift
public protocol AnyAnimationController: AnyObject {
    var isFinished: Bool { get }
    func tick(deltaTime: Double)
}

public final class AnimationController<Value: Interpolatable>: AnyAnimationController {
    public let from: Value
    public let to: Value
    public let animation: Animation
    public private(set) var elapsed: Double = 0
    public var isFinished: Bool { elapsed >= animation.duration + animation.delay }
    public let apply: @MainActor (Value) -> Void

    public func tick(deltaTime: Double) {
        elapsed += deltaTime
        let raw = max(0, elapsed - animation.delay)
        let t = Float(min(1, raw / animation.duration))
        let p = animation.curve.evaluate(t)
        apply(Value.interpolate(from, to, t: p))
    }
}
```

### 4.2 调度器

```swift
@MainActor
public final class AnimatorScheduler {
    public static let shared = AnimatorScheduler()
    private var active: [AnyAnimationController] = []

    public func register(_ c: AnyAnimationController) {
        active.append(c)
    }

    public func tick(deltaTime: Double) {
        for c in active { c.tick(deltaTime: deltaTime) }
        active.removeAll(where: \.isFinished)
    }
}
```

### 4.3 Node 上的属性表

```swift
public extension Node {
    /// key = property identifier, value = 当前活跃的 controller
    /// 写入新动画时丢弃同 key 旧 controller。
    var animations: [String: AnyAnimationController] { get set }
}
```

### 4.4 帧接入

```swift
// PlatformShell.SDL3PlatformHost.onFrame
host.onFrame = { [weak self] deltaTime in
    AnimatorScheduler.shared.tick(deltaTime: deltaTime)
    nodeRenderer.render(...)
}
```

---

## 5. 写入路径

```
state 写入
    │
    ▼
Recomposer 调度下一帧 recompose
    │
    ▼
modifier apply 阶段（如 BackgroundColorModifier）
    │
    ├─ 读 ActiveAnimationContext.current
    │       │
    │  ┌────┴─────┐
    │  │ 有动画？ │
    │  ├─ 否 ─→ node.backgroundColor = newValue
    │  └─ 是 ─→ 创建 AnimationController(from: oldValue, to: newValue, animation: ctx)
    │           ├─ Node.animations["backgroundColor"] = controller
    │           └─ AnimatorScheduler.shared.register(controller)
    ▼
（每帧）AnimatorScheduler.tick → controller 写回插值瞬时值 → Node 标记需重绘
```

`ActiveAnimationContext.current` 的来源：

- `withAnimation` 闭包：进入时压栈，退出时弹栈（thread-local，但首版只 MainActor）
- `.animation(_:value:)` modifier：apply 阶段如果检测到 value 变化，临时设置 current = 自己的 animation，然后让下游 modifier 跑完，再清理

---

## 6. 取消语义

| 场景 | 行为 |
|------|------|
| 同属性新动画到来 | 旧 controller 立即丢弃；新 controller 从「当前瞬时值」（即 Node 的最新写入）起步到新目标 |
| 节点被销毁（recompose tag 不匹配） | Node 的 animations 表随节点一起释放；scheduler 下一 tick 摘除 isFinished 项时不会读到悬空（弱引用 + tick 内部检查） |
| `withAnimation(nil) { … }` | 闭包内写入直接同步生效，跳过控制器路径 |

---

## 7. Theme.motion token 规约

```swift
public struct MotionScale: Sendable, Equatable {
    public var fast: Animation     // 默认 0.15s, easeOut
    public var medium: Animation   // 默认 0.25s, easeInOut
    public var slow: Animation     // 默认 0.40s, easeInOut
}
```

dark / light theme 共享同一份 motion 默认值。用户可通过 `var theme = Theme.defaultDark; theme.motion.fast = .init(duration: 0.10, curve: .easeOut)` 覆盖。

---

## 8. 测试矩阵

| 维度 | 用例 |
|------|------|
| Curve 单测 | linear/easeIn/easeOut/easeInOut/cubicBezier 在 t=0/0.25/0.5/0.75/1 的值符合预期 |
| Interpolatable | Float/Color/LayoutFrame/Insets 在 t=0/0.5/1 的值正确 |
| Controller | tick 累计 elapsed；isFinished 在 elapsed ≥ delay+duration 时为 true；finished 后多次 tick 不写无效值 |
| Scheduler | register 后 tick 调用所有；finished 自动摘除；空表 tick 是 no-op |
| `withAnimation` | 闭包内写 backgroundColor 创建 controller；闭包外写直接同步 |
| `.animation(_:value:)` | value 变化触发动画；value 不变不触发 |
| 取消 | 动画进行中再次 setter 丢弃旧 controller，从瞬时值起步 |
| Style 集成 | hover/press 状态变化 button 自动 cross-fade（mock 时钟步进） |
| 端到端 | mock 时钟 + state 切换 + 多帧 tick → 节点 backgroundColor 在中间帧是插值值 |

---

## 9. 实施顺序

| 步骤 | 内容 | 依赖 |
|------|------|------|
| 1 | `Animation` / `AnimationCurve` / `SemanticMotionRef` 值类型 + curve evaluate 单测 | — |
| 2 | `Interpolatable` 协议 + Float/Double/Color/LayoutFrame/Insets 实现 + 单测 | 1 |
| 3 | `AnimationController` + `AnimatorScheduler` + 单测（mock tick） | 2 |
| 4 | 接 `PlatformShell.SDL3PlatformHost.onFrame` 调用 `AnimatorScheduler.shared.tick` | 3 |
| 5 | `ActiveAnimationContext` 与 `withAnimation` thread-local 路径；先跑通 `opacity` 一种属性 | 3 |
| 6 | 扩展到 `backgroundColor` / `foregroundColor` / `cornerRadius` / `frame` / `padding` | 5 |
| 7 | `.animation(_:value:)` modifier | 5 |
| 8 | Style 集成：`PrimaryButtonStyle` / `SecondaryButtonStyle` 内置 hover/press 过渡 | 6, 7 |
| 9 | Demo：`.appearance` 切换包 `withAnimation(.semantic(.medium))` | 6 |
| 10 | 集成测试套件（mock 时钟） | 全部 |

---

## 10. 已知风险与缓解

| 风险 | 缓解 |
|------|------|
| Recomposer 与 Animator 双写 Node 字段竞争 | 二者均 MainActor 调度；约定：Animator 只写"已被 modifier apply 过"的字段，且写入不触发 recompose |
| `withAnimation` 的 thread-local 不能跨 await | 首版禁止 async；需要时改用显式 `Animation` 参数 |
| 同属性多动画叠加（additive） | 首版不支持，新动画直接替换旧；Phase 8.5 视需要再加 |
| 性能：每帧遍历所有 controller | 链表 + 完成自动摘除；预期同时活跃 controller 数百量级，开销可忽略 |
| Hover 事件未联通 | Phase 8 不依赖 hover；`PrimaryButtonStyle` 的 hover 过渡先注释或仅在 `isPressed` 维度生效 |
| 主题切换全树重建 vs cross-fade | Phase 8 仅做 token 值的插值（颜色/字号），不做整棵节点 snapshot 叠化；后者推迟 |

---

## 11. 与 Phase 7.5 的接口

- `Theme.motion` 已存在，`MotionScale` 字段全部复用，无破坏
- `Style.makeBody` 返回 `AnyView`，可在内部包 `.animation(_:value:)`，对调用方透明
- `Appearance` 切换走 Theme 重新下发；用户只需 `withAnimation(.semantic(.medium)) { appearance = .light }`，整棵子树渐变（color 类属性自动插值，layout 类属性同步切换）

---

## 12. 与 Phase 9（编辑器接入）的接口

- 编辑器面板拖拽分隔条时，可选用 `withAnimation(nil)` 跳过插值，保证拖拽响应即时
- 列表行 hover 高亮、tree disclosure 三角旋转等微交互全部通过 `.animation(_:value:)` 实现，无需面板代码显式介入
- 主题热切换面板（Editor 设置）触发 `withAnimation(.semantic(.slow))` 即可获得整棵编辑器渐变换肤
