# ScrollView

内容闭包使用 `@ViewBuilder`，条件空态/内容、可选区段及子视图集合与其他容器采用同一语法；内容布局由 `Column`/`Box` 明确声明。`ScrollViewInputTests.contentBuilder` 覆盖空态/非空分支，生产 Editor 的条件诊断面板构建通过。

可裁剪的纵向、横向或双轴滚动容器。内容尺寸由真实布局测量；普通 ScrollView 不会自动把大量内容变成虚拟列表。

```swift
@State var offset: CGPoint = .zero

ScrollView(.vertical, scrollbarGutter: .stable,
           scrollOffset: $offset, accessibilityLabel: "Content",
           onGeometryChange: { geometry in /* offset / viewportSize / contentSize */ }) {
    Box(direction: .column, alignItems: .stretch, spacing: 8) {
        rows
    }.flex(0, shrink: 0)
}.frame(height: 280)
```

`scrollOffset`、`onViewportChange`、`onGeometryChange` 均可省略。程序写入不同的绑定偏移会中断旧运动并夹到有效范围，这是立即定位；需要带时长的程序滚动时使用 `scrollRequest:`（见下文）。回调可能在布局/绘制时运行，应用应比较快照后才更新状态，避免每帧重组不相关的内容。

Sidebar、Tab 等键盘组显露目标时，ScrollView 先用本轮节点几何刷新滚动范围；若范围更新夹紧了偏移，同步换算目标的窗口坐标后再计算显露距离。这样在内容重排、字号或导航呈现变化时不会按旧偏移二次移动，普通用户滚动仍保持自己的位置。

## 平台输入与停止

原生 wheel/trackpad 输入直接跟随平台增量，不会再用最后输入后 90ms 的静默推算额外 fling，也不在相邻滚动包之间启动回弹。系统已经提供的加速与减速只能应用一次。

- `MouseWheelEvent.input` 是 `ScrollInput`：携带 `unit`（points/lines/pages）、`device`（unknown/wheel/continuous）、手指 `phase`、独立 `momentumPhase` 和单调秒时间戳。
- points 是逻辑点，保留小数，不乘 `wheelStep` 或屏幕密度。lines 乘可配置的 `wheelStep`（默认 30pt）；pages 乘对应轴的实际逻辑视口大小。正增量表示内容向正方向平移，正滚动 offset 相应减小；平台方向偏好已经包含在输入中，不二次反转。
- macOS 直接观察 AppKit 的原始 scrollingDelta/hasPreciseScrollingDeltas/phase/momentumPhase，启用系统 momentum，再用 SDL 队列标记保持与其他事件的顺序。重复 SDL wheel 包跳过；零位移的开始/结束/取消包保留。`continuous` 表示精确输入流，不能据此断言硬件一定是触控板。
- Windows/Linux 的 SDL 输入目前只能提供行增量和时间戳，设备与 phase 保持 unknown/none；不从小数大小猜设备，不推测释放，也不补框架惯性。平滑驱动产生的连续增量直接跟随。
- 有 phase 的手势与后续系统惯性保持原滚动消费者；指针移到另一个视口不会把惯性转过去。点击、mayBegin、取消、窗口失焦/最小化会阻止旧惯性继续；新的 began 或新输入可立即开始。移除消费者或打开 modal 后不会把旧流转交背景/相邻视口。
- thumb 拖动是绝对定位，范围内夹取，释放保持选择的位置，不额外 fling 或橡皮筋。
- 软件写入滚动绑定仍是立即定位并中断框架运动；节点卸载取消其运动控制器。
- `.reducedMotion()` 禁用框架添加的运动；OS 已提供的滚动流仍直接跟随。

`ScrollAnimator.scroll(by:) / move(to:) / settle()` 的可配置惯性与解析弹簧仍供软件显式管理自定义手势使用；它们不再是原生 wheel 的自动路径。不要将系统 momentum 包送入推算释放的自定义手势接口。详见 [本轮输入验证](https://github.com/AlexCat315/GuavaStudio/tree/main/GuavaUI/Portable/Tests/GuavaUISceneTests/Scrolling)。

DevTools 的 wheel 桥也携带同一 typed group；浏览器镜像按 `deltaMode` 传 points/lines/pages，并统一方向，只对 point 输入做画面到逻辑坐标的比例换算。InputRecording 格式升级为 version 2，直接保存完整事件，未增加旧格式解码层。

## 触摸拖动与键盘

- 触摸面（`UIEnvironment.input` 含 `.touch`）可在内容区拖动：按下只登记起点，不抢子控件点击；超过 4pt 阈值后捕获指针，用 `ScrollAnimator.move(to:)` 跟随，释放交给 `settle()` 进入惯性与边界回弹。
- 同轴嵌套时最深滚动容器先识别，异轴按主位移判定。Button 的待完成点击可让位于滚动并取消按下态；Slider 等明确拖动默认独占捕获，不被滚动抢走。`.stable` 在纵轴右侧、横轴底部各预留 12pt（双轴两边均预留），避免 chrome 覆盖末列/末行。
- 指针面（鼠标/触控板）不启用内容拖动，避免与文本选择、按钮拖拽冲突；鼠标仍走 wheel/滚动条。
- 有实际溢出且没有可 Tab 到达的子控件时，ScrollView 提供键盘 Tab 停靠点；菜单、表格、表单等已有内部操作入口时不额外抢占焦点。聚焦视口后 ArrowUp/Down/Left/Right 行滚动 40pt，PageUp/PageDown 滚一屏的 90%，Home/End 到两端；只处理实际可滚动的轴，无位移时不吞事件。
- 键盘滚动是立即定位，不启动惯性；触摸释放才走 `settle()`。`.reducedMotion()` 仍会关闭框架添加的运动。

独立 `Scrollbar` companion 已提供可聚焦 thumb（见 [Scrollbar](scrollbar.md)）；ScrollView 内建 chrome 不会自动叠加它。

`ScrollKeyboardFocusTests` 验证无溢出 → 只读溢出 → 添加子按钮 → 恢复只读的焦点归属变化。`AppBarTests`、`MenuHierarchyTests`、`SelectionFieldTests` 与 `ProductInteractionRegressionTests` 验证滚动包装不增加工具栏停靠、不抢菜单初始焦点，选择/关闭仍回到原入口。零尺寸的内部视口不进入键盘链；实际溢出的只读视口保留 Page/Home/End 滚动入口。

## 程序化滚动

```swift
@State private var request: ScrollRequest?

ScrollView(.vertical, scrollRequest: request) { content }
Button("End") {
    request = ScrollRequest(offset: CGPoint(x: 0, y: 2_000), duration: 0.42)
}
```

- `ScrollRequest` 每次初始化获得新 `id`；ScrollView 只在 `id` 变化时消费。offset 在应用时按当前 content/viewport 夹到有效范围，并按轴清零另一轴。
- `duration > 0` 时从当前 offset 缓动到目标；滚轮、拖动、`scrollOffset` 写入或新的 request 会取消旧动画。`duration == 0` 与 `.reducedMotion()` 直接吸附。
- 旧 request 值不会重新触发；应用再次点击同一目标时要创建新的 `ScrollRequest`。
- 帧推进由 `AnimatorScheduler` 驱动，不依赖 SwiftUI 事务；测试可手动 tick。

## 滚动锚定

给需要保持可见的内容加 `.scrollAnchor()`：

```swift
ScrollView(.vertical, scrollOffset: $offset) {
    Box(direction: .column, alignItems: .stretch, spacing: 0) {
        for message in messages {
            MessageRow(message).scrollAnchor().id(message.id)
        }
    }
}
```

- ScrollView 在当前视口内选择**最靠上的完整 anchor**（没有完整项时取仍相交的最后一项），记录它与视口的相对位置和 contentSize。
- 下一次布局 contentSize 变化且同一节点的 identity 仍存在时，按 anchor 的位移修正 offset：在顶部插入聊天历史会增大 offset，当前阅读行保持原位；追加底部内容不会移动视口。
- 普通滚动会刷新 anchor 基线，所以用户主动滚动不会被下一次布局拉回。
- 锚点被卸载或消失时重新选择，不做猜测；多个 anchor 时只使用视口顶部那个。
- 约束：只修正布局内容尺寸变化；异步图片在 anchor 上方改变高度仍要求调用方稳定行高或显式 `.scrollAnchor()`。横向锚定按 x 轴同样处理。

## 嵌套与滚动条

`.overlay` 将滚动条置于内容上方；`.stable` 在纵向 trailing 预留 12pt 槽，避免盖住尾部控件。只有内容溢出才绘制条；hover/拖动显示，离开淡出。

仅触摸（无指针）的表面没有 hover 与可抓取的 thumb，滚动条按平台习惯改为 3pt 细指示条：不绘制轨道、不预留 gutter（`.stable` 在该表面同样为零），内容移动时立即出现，静止 0.7s 后 0.3s 淡出；减少动画时保持可见而不做淡出动画。触摸 + 指针的混合表面保留 12pt gutter 与可拖动滚动条。验收：`ScrollIndicatorTests`（三种输入的 gutter、触摸滚动显示指示条且不抓取 thumb、指针拖动 thumb），DevTools 390pt 触摸 `input @drag.json --capture` 取样滚动中与静止 1.5s 后的镜像。软件自定义手势若产生越界位移，thumb 缩短且仍位于轨道内。

内建 chrome 的扩大命中区限制在视口与祖先裁剪的交集内，不能抢占相邻按钮或 Sidebar 调宽分隔柄；捕获成功后，移出视口仍可继续拖拽和释放。`ScrollViewInputTests` 覆盖普通边界和祖先裁剪边界。祖先应用 `.allowsHitTesting(false)` 时立即取消该子树的指针捕获与焦点，恢复输入后仍可正常开始新操作；Sidebar 的调宽生命周期测试覆盖此路径。

ScrollView / BoundedScrollView 默认 `.whenScrollable`：当前输入轴有内容溢出时，子视口在顶部和底部仍消费滚动，重复滚动或开启新手势都不会带动父级。指针移到父视口后，新手势可以正常滚动父级；已有 phase / 系统 momentum 流继续保留原消费者。没有溢出的轴允许事件交给父级，横向标签条不会截住纯纵向滚动。零增量的生命周期包不推测输入轴，也不会抢先锁定视口。

TextField 与 CodeEditor 的内部视口采用同样的有溢出边界隔离；有坐标的新手势按指针所在视口处理，没有可用坐标时保留焦点编辑器回退。`.whenOffsetChanged` 供调用方显式启用边界冒泡；`.always` 即使没有溢出也截住事件，适合菜单等临时浮层；`.never` 供显式透传。链式策略仍以完整事件交接，尚未把一次大增量的“边界剩余距离”拆分给父级。

## 性能边界

内容偏移改变绘制/命中几何，稳定内容不需要每帧重跑 Yoga。保留渲染器可复用文字等叶子的绘制缓存；本轮新增实际缓存顶点边界与视口/裁剪相交判断，不再把完全不可见的缓存叶子反复追加到帧列表。自定义 painter 超出 Node.frame 的实际绘制仍被保留；有明确裁剪边界的离屏子树可整体跳过。

这属于绘制剔除，并不减少普通 ScrollView 的节点数或首次构建成本。大集合应使用 VirtualStack / List / Tree / DataTable 对应的窗口化协议；已知可变行高可使用 [VariableVirtualStack](https://github.com/AlexCat315/GuavaStudio/blob/main/GuavaUI/Tests/GuavaUIComposeTests/VariableVirtualStackTests.swift)，未知高度的自动测量仍缺失。此前版本的原生绘制计时方法和数值见 [滚动与布局历史验证记录](https://github.com/AlexCat315/GuavaStudio/blob/main/GuavaUI/Tests/GuavaUIComposeTests/ButtonScrollViewTests.swift)。

## 辅助功能

`ScrollView` 暴露 `.scrollArea` 语义：`accessibilityLabel`（默认 "Scrollable content"）、当前位置百分比（垂直 `80%`，水平 `80%`，双轴 `Horizontal 80%, vertical 40%`）与键盘滚动 hint。辅助功能 increment/decrement 每次滚动约一页（视口 − 40pt），偏移变化后 value 随之重算。滚动条 thumb 仍不是独立可聚焦节点，屏幕阅读器通过滚动区域本身操作。

```swift
ScrollView(.vertical, accessibilityLabel: "Timeline") {
    TimelineRows()
}
```

## 尚未完成

- Windows/Linux 精确设备、手势 phase 和系统 momentum 的原生补充；macOS 仍需真实触控板/鼠标/平滑驱动的长时间录制验证。
- 显式开始/结束/停止控制器与连续目标插值。
- 统一 ScrollHandle、显示策略/尺寸/配色主题；独立 `Scrollbar` 已提供可聚焦 thumb。
- chat 历史预取、scroll-linked 动画和大增量残余交接；基础滚动锚定已由 `.scrollAnchor()` 补齐。
- Windows/Linux、120Hz、真实设备的视觉抖动和停止延迟，以及 GPU/合成器完成时间证据。当前合成输入验证不能代替这些证据。

## 实现

- [容器与 chrome](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/ScrollView.swift)
- [运动控制](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollAnimator.swift)、[逐轴交接](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/AxisMotion.swift)、[弹簧](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollSpring.swift)
- [可配置物理组](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollPhysics.swift)

Demo 默认使用与 Application 相同的 LayerAwareNodeRenderer；`GUAVAUI_LEGACY_RENDERER=1` 可用于原始全树绘制对照。保留路径的缓存继承屏幕 pixelScale，密度改变重新记录；第一次记录的离屏叶子也不会被追加进祖先缓存。原生测量发现并修正了 Demo 曾绕过此路径的问题，测量范围详见审计证据。
