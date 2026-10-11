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

## 滚动与停止

- wheel 的小数增量保持原精度，目前乘 `wheelStep`（默认 30 个逻辑点）；平台尚未提供设备种类、像素/行单位和手势阶段。
- 框架用最后一个样本后 90ms 的 quiet window 推断释放。至少三个有效样本且速度超过 `minimumVelocity` 才起惯性；单次拨动只移动输入距离。这种推断仍存在交接停顿的可能，不能代替触控板原生 phase/momentum 协议。
- 惯性按指数解析积分；起滑阈值 50pt/s 与停止阈值 `restVelocity = 2pt/s` 分离，避免在慢速尾段突然截断。不对运动或停止位置做整点取整。
- 每个轴在抵达自己的边界时把速度交给自己的弹簧；另一个轴继续滑行，不等待两轴一起耗尽。弹簧使用解析阻尼解，零/负数/非有限时间步不改变位置；长帧不会触发不稳定积分。
- 新滚轮输入中断旧惯性、清除旧采样并从当前位置继续。容器内按下鼠标取消正在运行和等待起滑的惯性；回弹仍返回边界，子控件照常收到按下事件。
- thumb 拖动捕获指针，松开后根据新采样决定惯性或回弹；停止拖动一段时间后才松开不会产生旧速度甩动。
- 权威偏移、内容缩小导致的夹取和取消清除待释放任务；节点卸载立即取消动画并解除原调度器注册。
- `.reducedMotion()` 保留直接滚动，关闭框架添加的惯性与弹性，并结束旧运动。

## 嵌套与滚动条

`.overlay` 将滚动条置于内容上方；`.stable` 在纵向 trailing 预留 12pt 槽，避免盖住尾部控件。只有内容溢出才绘制条；hover/拖动显示，离开淡出。越界时 thumb 缩短且仍位于轨道内。

默认 `.whenOffsetChanged` 下，同轴子 ScrollView 在边界向外滚动时把事件交给滚动祖先；无溢出的轴不会凭空产生橡皮筋。`.always` 允许显式截住事件。当前以完整事件交接，尚未把一次大增量的“边界剩余距离”拆分给父级，也未提供统一 scroll-chain policy。

## 性能边界

内容偏移改变绘制/命中几何，稳定内容不需要每帧重跑 Yoga。保留渲染器可复用文字等叶子的绘制缓存；本轮新增实际缓存顶点边界与视口/裁剪相交判断，不再把完全不可见的缓存叶子反复追加到帧列表。自定义 painter 超出 Node.frame 的实际绘制仍被保留；有明确裁剪边界的离屏子树可整体跳过。

这属于绘制剔除，并不减少普通 ScrollView 的节点数或首次构建成本。大集合应使用 VirtualStack / List / Tree / DataTable 对应的窗口化协议；可变行高虚拟列表仍缺失。原生测量方法和数值见 [滚动与布局验证记录](../guava-ui/evidence/scroll-layout/README.md)。

## 尚未完成

- 原生触控板 phase、系统 momentum 与框架 momentum 的互斥，以及像素/行单位、时间戳、输入设备信息。
- 离散滚轮的可打断平滑目标插值、显式开始/结束/停止控制器和带时长的程序定位。
- 独立 Scrollbar/统一 ScrollHandle、显示策略/尺寸/配色主题、可访问性滚动条语义与键盘 Page/Home/End 操作。
- touch/pan、滚动锚定、聊天历史加载保持位置、scroll-linked 动画和大增量残余交接。
- Windows/Linux、120Hz、真实触控板长时间操作以及 GPU/合成器完成时间证据。

## 实现

- [容器与 chrome](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/ScrollView.swift)
- [运动控制](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollAnimator.swift)、[逐轴交接](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/AxisMotion.swift)、[弹簧](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollSpring.swift)
- [可配置物理组](../../GuavaUI/Portable/Sources/GuavaUIScene/Scrolling/ScrollPhysics.swift)

Demo 默认使用与 AppRuntime 相同的 LayerAwareNodeRenderer；`GUAVAUI_LEGACY_RENDERER=1` 可用于原始全树绘制对照。保留路径的缓存继承屏幕 pixelScale，密度改变重新记录；第一次记录的离屏叶子也不会被追加进祖先缓存。原生测量发现并修正了 Demo 曾绕过此路径的问题，测量范围详见审计证据。
