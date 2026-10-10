# ScrollView

可滚动视图。支持 `.vertical` / `.horizontal` / `.both`，根据内容尺寸自动决定是否绘制滚动条。

## Anatomy

```
┌────────────────────────────────┐
│                              ▲ │
│                              █ │ ← vertical thumb (仅 contentH > viewH 时绘制)
│         content              ░ │
│                              ░ │
│                              ▼ │
└────────────────────────────────┘
   ◀ ░░░░██████░░░ ▶                ← horizontal thumb (同条件)
```

## API

```swift
ScrollView {                  // 默认 .vertical
    Box(.column, .stretch, spacing: 8) { … }
}

ScrollView(.horizontal) { Row { … } }
ScrollView(.both) { … }
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `axes` | `.vertical` | `.vertical` / `.horizontal` / `.both` |
| `content` | 必填 | 子视图，按指定 axes 自由溢出 |

## Tokens

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| track | `theme.colors.surfaceVariant` | theme |
| thumb | `theme.colors.onSurfaceMuted` | theme |

## Behavior

- **wheel**：`SDL_MOUSEWHEEL` 路由到 hit 命中的 ScrollView，按轴位移
- **momentum / 惯性**：输入停止后按手势速度继续滑一段再慢慢停下；撞到边界时剩余速度交给回弹
- **overscroll / 橡皮筋**：推过任意一端时在边界外继续拉伸一小段，输入停止后由弹簧拉回；拉伸距离永远不会超过一个视口（`RubberBand`），且只在 `[0, max]` 之外生效
- **clipping**：`clipsToBounds = true`，超出视口的内容被裁剪
- **scrollbar**：仅在 `contentSize > viewSize` 时绘制（内容能完全显示则不显示条）；`overscroll` 期间 thumb 按比例缩短并停在轨道内
- **拖动 thumb**：按下 thumb 或轨道任意位置皆可拖动；拖出轨道末端同样进入 overscroll，松手才回弹

## Momentum / 惯性 + Overscroll / 橡皮筋

默认都开启。三个阶段串成一条链，每一段把自己剩下的速度交给下一段：

| 阶段 | 做什么 | 配置 |
| ---- | ------ | ---- |
| 滑行 | `ScrollVelocityTracker` 估出手势速度，按 `v(t) = v₀·e^(-deceleration·t)` 继续位移 | `ScrollPhysics.momentum` |
| 拉伸 | `RubberBand.project` 把越界量压成越推越紧的可见位移 | `ScrollPhysics.rubberBand` |
| 回弹 | `ScrollSpring` 以临界阻尼把越界偏移拉回边界 | `ScrollPhysics.settle` |

滚轮没有"松手"事件，所以滑行是这样起步的：最后一次输入之后安静 `idleWindow`（默认 90ms）即视为手势结束，用窗口内记录的速度甩出去。于是滚轮连打一串会顺势滑一段，触控板抬手立刻起滑，而慢慢拨一档则原地停下：`trackingWindow` 之外的采样不参与，`staleWindow` 之外的采样一律判定为"早就松手了"。thumb 拖拽有真正的松手事件，走同一个出口。

```swift
ScrollView { rows }
    .scrollPhysics(.bouncy)   // 回弹时越过边界一次
    .scrollPhysics(.clamped)  // 橡皮筋关掉，滑到边缘直接停住
    .scrollPhysics(.precise)  // 连惯性一起关：每一档滚轮落在哪里就是哪里
```

`ScrollPhysics` 通过 `CompositionLocal` 下发，子树里更近的 provider 覆盖外层，所以嵌套的横向 carousel 可以单独关掉惯性。

自己维护偏移的组件不必重复这套耦合 —— 见 `ScrollAnimator`（`GuavaUIScene/Scrolling`）：建立实例后用 `scroll(by:)` / `move(to:)` 喂输入，可见偏移从 `change` 回调里取。滚轮那种没有松手事件的输入连 `settle()` 都不用调，动画器自己会判断什么时候开始滑行。

## Known issues / TODO

- 没有内容 pan 手势：能喂出惯性的输入目前只有滚轮和 thumb 拖拽
- 没有 scroll-linked 动画钩子：滚动进度还不能驱动别的东西
- 没有"是否显示滚动条"开关 —— 目前完全自动

## Authoring rules

✅ 应当：
- 把 ScrollView 作为 Tree / List / 长内容的外层
- 给 ScrollView `.flex()` 让它撑满父容器
- 内容用 `Box(.column, .stretch)` 而不是 `Column(.leading)`（后者不撑宽）

❌ 不应：
- 嵌套 ScrollView（同轴）
- 给 ScrollView 加 `.frame(height: 内容高度)` —— 那就不需要 ScrollView 了

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| SwiftUI | `ScrollView(_:)` API 形态 |
| macOS | overlay scrollbar (Lion+) |
| Web overflow | `overflow: auto` 的"按需显示"语义 |
| UIKit | `UIScrollView` 的 deceleration rate 与 least-squares 速度估计 |

## File map

- 主体: [GuavaUICompose/Primitives/Layout/ScrollView.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/ScrollView.swift)
- 物理配置: [GuavaUICompose/Scrolling/ScrollPhysicsEnvironment.swift](../../GuavaUI/Sources/GuavaUICompose/Scrolling/ScrollPhysicsEnvironment.swift)
- 运动本体: [GuavaUIScene/Scrolling/](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling) —— `ScrollAnimator` / `ScrollVelocityTracker` / `ScrollSpring` / `RubberBand`
