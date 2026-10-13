# ScrollView

可裁剪的纵向、横向或双轴滚动容器。内容尺寸由真实布局测量；普通 ScrollView 不会自动把大量内容变成虚拟列表。

```swift
ScrollView(.vertical, scrollbarGutter: .stable,
           scrollOffset: $offset,
           onGeometryChange: { geometry in /* offset / viewportSize / contentSize */ }) {
    Box(direction: .column, alignItems: .stretch, spacing: 8) {
        rows
    }.flex(0, shrink: 0)
}.frame(height: 280)
```

`scrollOffset`、`onViewportChange`、`onGeometryChange` 均可省略。程序写入不同的绑定偏移会中断旧运动并夹到有效范围；这是立即定位，尚无公开的带时长 scrollTo 动画协议。回调可能在布局/绘制时运行，应用应比较快照后才更新状态，避免每帧重组不相关的内容。

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

`ScrollAnimator.scroll(by:) / move(to:) / settle()` 的可配置惯性与解析弹簧仍供软件显式管理自定义手势使用；它们不再是原生 wheel 的自动路径。不要将系统 momentum 包送入推算释放的自定义手势接口。详见 [本轮输入验证](../guava-ui/evidence/scroll-input/README.md)。

DevTools 的 wheel 桥也携带同一 typed group；浏览器镜像按 `deltaMode` 传 points/lines/pages，并统一方向，只对 point 输入做画面到逻辑坐标的比例换算。InputRecording 格式升级为 version 2，直接保存完整事件，未增加旧格式解码层。

## 嵌套与滚动条

`.overlay` 将滚动条置于内容上方；`.stable` 在纵向 trailing 预留 12pt 槽，避免盖住尾部控件。只有内容溢出才绘制条；hover/拖动显示，离开淡出。软件自定义手势若产生越界位移，thumb 缩短且仍位于轨道内。

ScrollView / BoundedScrollView 默认 `.whenScrollable`：当前输入轴有内容溢出时，子视口在顶部和底部仍消费滚动，重复滚动或开启新手势都不会带动父级。指针移到父视口后，新手势可以正常滚动父级；已有 phase / 系统 momentum 流继续保留原消费者。没有溢出的轴允许事件交给父级，横向标签条不会截住纯纵向滚动。零增量的生命周期包不推测输入轴，也不会抢先锁定视口。

TextField 与 CodeEditor 的内部视口采用同样的有溢出边界隔离；有坐标的新手势按指针所在视口处理，没有可用坐标时保留焦点编辑器回退。`.whenOffsetChanged` 供调用方显式启用边界冒泡；`.always` 即使没有溢出也截住事件，适合菜单等临时浮层；`.never` 供显式透传。链式策略仍以完整事件交接，尚未把一次大增量的“边界剩余距离”拆分给父级。

## 性能边界

内容偏移改变绘制/命中几何，稳定内容不需要每帧重跑 Yoga。保留渲染器可复用文字等叶子的绘制缓存；本轮新增实际缓存顶点边界与视口/裁剪相交判断，不再把完全不可见的缓存叶子反复追加到帧列表。自定义 painter 超出 Node.frame 的实际绘制仍被保留；有明确裁剪边界的离屏子树可整体跳过。

这属于绘制剔除，并不减少普通 ScrollView 的节点数或首次构建成本。大集合应使用 VirtualStack / List / Tree / DataTable 对应的窗口化协议；已知可变行高可使用 [VariableVirtualStack](../guava-ui/variable-virtual-layout.md)，未知高度的自动测量仍缺失。此前版本的原生绘制计时方法和数值见 [滚动与布局历史验证记录](../guava-ui/evidence/scroll-layout/README.md)。

## 尚未完成

- Windows/Linux 精确设备、手势 phase 和系统 momentum 的原生补充；macOS 仍需真实触控板/鼠标/平滑驱动的长时间录制验证。
- 离散滚轮的可打断平滑目标插值、显式开始/结束/停止控制器和带时长的程序定位。
- 独立 Scrollbar/统一 ScrollHandle、显示策略/尺寸/配色主题、可访问性滚动条语义与键盘 Page/Home/End 操作。
- touch/pan、滚动锚定、聊天历史加载保持位置、scroll-linked 动画和大增量残余交接。
- Windows/Linux、120Hz、真实设备的视觉抖动和停止延迟，以及 GPU/合成器完成时间证据。当前合成输入验证不能代替这些证据。

## 实现

- [容器与 chrome](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/ScrollView.swift)
- [运动控制](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollAnimator.swift)、[逐轴交接](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/AxisMotion.swift)、[弹簧](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollSpring.swift)
- [可配置物理组](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollPhysics.swift)

Demo 默认使用与 AppRuntime 相同的 LayerAwareNodeRenderer；`GUAVAUI_LEGACY_RENDERER=1` 可用于原始全树绘制对照。保留路径的缓存继承屏幕 pixelScale，密度改变重新记录；第一次记录的离屏叶子也不会被追加进祖先缓存。原生测量发现并修正了 Demo 曾绕过此路径的问题，测量范围详见审计证据。
