# GuavaUI 动画系统

GuavaUI 用 `Animation` 描述时间与曲线，`withAnimation` 和 `.animation(_:value:)` 驱动属性变化；`AnimatedVisibility` 管理进入、退出与卸载。关键帧、相位、循环、数值和共享几何使用同一调度器与节点生命周期。应用只传普通值、binding 和内容，不需要注册全局对象、传调度器或继承动画基类。

## 状态变化与完成

```swift
Box {}.frame(width: expanded ? 200 : 80, height: 24)
    .animation(.easeInOut(duration: 0.25), value: expanded)

withAnimation(.spring(response: 0.4, dampingFraction: 0.75),
              completionCriteria: .removed) {
    expanded.toggle()
} completion: {
    status = "Finished"
}
```

隐式动画首帧吸附，只有 key 改变才采用新动画；与目标无关的重组不会重启在飞动画。`.animation(nil, value:)` 和 `withAnimation(nil)` 显式取消插值并吸附目标，禁用语义会随排队的状态变更传到提交阶段。

完成回调覆盖该次提交创建的属性控制器。固定时长动画的两种判定相同；物理弹簧的 `.logicallyComplete` 在名义 `duration` 到达时完成，`.removed` 等待收敛尾部停止。回调只执行一次，无动画的变更在下一次调度扫描完成；中断、替换或卸载取消回调。减少动画把同一目标吸附到终值时仍正常完成。几何动画在布局前保留登记，兼容原生宿主“提交 → tick → 布局”的帧顺序。

颜色、透明度、边框、圆角、阴影、尺寸、padding、flex、`.offset(x:y:)` 与 `.scaleEffect(_:anchor:)` 均可参与属性动画。普通属性动画直接写节点；关键帧、相位和数值发布局部视图状态，拖拽 binding 的更新由调用方的状态作用域接收。

## 曲线与物理弹簧

| 能力 | API | 行为 |
| --- | --- | --- |
| 常用缓动 | `.linear`、`.easeIn`、`.easeOut`、`.easeInOut` | 后三者使用二次近似；精确形状用自定义 Bezier |
| Bezier | `.cubicBezier(x1, y1, x2, y2)` | 按时间反解 x，可表达 back / anticipation |
| 阶梯 | `.steps(5, position: .end)` | 默认在区间结束跳变；`.start` 在时间 0 即为首阶，非正阶数按 1 处理 |
| 多点折线 | `.piecewiseLinear(LinearTimingCurve(points))` | 支持平台、反向和过冲，按时间二分查找区间 |
| 命名曲线 | `.bounceOut`、`.elasticOut` | 有限时长的弹跳 / 衰减振荡；elastic 周期为归一化时间 0.4 |
| 物理弹簧 | `.spring(response:dampingFraction:delay:initialVelocity:allowsOvershoot:)` | 按真实秒数求解析解，支持释放速度与中断后的速度延续 |
| 弹簧预设 | `.snappy`、`.bouncy`、`.smooth` | 适合快速、活泼和临界阻尼运动；语义引用读取当前主题 |

`LinearTimingCurve` 至少包含两个点，必须以 `(0, 0)`、`(1, 1)` 为端点，所有值有限、时间严格递增。内部 progress 可超出 0…1；构造时校验一次。它接受显式点列，不解析 CSS 字符串或推导省略的时间点。

```swift
let curve = LinearTimingCurve([
    .init(time: 0, progress: 0), .init(time: 0.25, progress: 0.6),
    .init(time: 0.5, progress: 0.6), .init(time: 0.75, progress: 1.2),
    .init(time: 1, progress: 1)
])
let motion = Animation(duration: 0.4, curve: .piecewiseLinear(curve), allowsOvershoot: true)
```

曲线求值保留过冲，控制器默认把进度限制在 0…1。只在已知可承受过冲的位移、缩放等几何属性上使用 `allowsOvershoot: true`；不要把同一过冲作用域用于颜色或透明度。

物理弹簧的 `response` 是自然振荡周期，`dampingFraction` 小于 1 欠阻尼、等于 1 临界阻尼、大于 1 过阻尼。参数由 `SpringSolution` 统一校验：response 为 0.001…30 秒，阻尼为 0.01…20；非有限输入分别回退到 0.4 和 1。解不改变目标平衡点来强行钉住某一帧，控制器在收敛上界吸附精确终值；接近无阻尼时的收敛估算上限为 30 秒，显式名义时长仍生效。

同一属性的几何弹簧中断时同时延续当前值和各分量的实际速度，改变方向或目标距离不会误用旧的归一化速度。`initialVelocity` 是初始进度/秒。受边界约束的动画保持有限进度并从静止启动；拖拽入口负责把实际指针速度交给物理解。

```swift
@State var position = CGPoint.zero

card.springDrag(offset: $position, restingAt: .zero,
                spring: SpringSolution(response: 0.4, dampingFraction: 0.82))
```

`springDrag` 在按下时取消旧尾部并从显示位置继续，拖动直接更新 binding，释放后使用短窗口拟合的速度回到目标。重新抓取、禁用、减少动画和卸载均释放捕获与调度。拖动改变实际绘制 frame，点击区域与显示位置一致。

## 关键帧、相位与循环

```swift
let track = KeyframeTimeline(initialValue: Float(1), keyframes: [
    .init(1.12, duration: 0.12, curve: .easeOut),
    .init(0.94, duration: 0.12, curve: .easeInOut),
    .init(1, duration: 0.16, curve: .easeOut)
])
KeyframeAnimator(track, trigger: revision) { scale in
    badge.scaleEffect(scale)
}
```

关键帧目标和每段的正有限时长组成不可变时间轴；`value(at:)` 可独立取样。丢帧跨越多个分段时按绝对时间求值。普通轨道在 trigger 改变时从起点播放；`repeating: true` 在挂载时开始循环，卸载立即停止。

```swift
enum SavePhase { case idle, working, done }
PhaseAnimator([SavePhase.idle, .working, .done], trigger: revision,
              animation: { _ in .easeInOut(duration: 0.2) }) { phase in
    badge.scaleEffect(phase == .working ? 1.08 : 1)
}
```

相位是调用方的普通 Equatable 值，不需要实现插值协议。第一相位为静态初值，trigger 改变后依次进入后续相位；每阶段按对应 Animation 的名义时长推进，属性过渡仍遵守自己的曲线 / 弹簧。循环模式会返回第一相位。单相位不创建时钟，修改相位列表或时长会重新建立当前序列。

```swift
let pulse = Animation(duration: 0.6, curve: .easeInOut).repeatCount(3, autoreverses: true)
let loop = Animation.linear.repeatForever(autoreverses: false)
```

有限重复按完整周期计数：往返一次算一个 autoreverse 周期，结束在起点；关闭 autoreverse 时结束在目标。delay 只发生在整个播放开始前。零时长循环只吸附一次，不创建忙等；大 tick 保留周期余量。停止 keyed 循环时把动画改为 nil，或卸载其拥有者。

## 共享几何与数值

```swift
selectionSurface.matchedGeometry("selection")
NumericText(progress * 100) { String(format: "%.0f%% complete", $0) }
```

`matchedGeometry` 的 ID 在当前场景内唯一，不需要 namespace 句柄或全局注册。同一次提交中，旧表面移除、新表面插入时复用其显示矩形，插值窗口位置和宽高；存活表面的布局位置变化也可动画。布局立即预留目标槽位，绘制和命中使用当前矩形。它调整表面 frame，不复制旧内容或插值字形；跨内容显隐可组合 `AnimatedVisibility`。旧记录只为紧邻的布局交接短暂保留，场景销毁时清空。

默认共享几何使用当前主题的 smooth 弹簧；显式 `withAnimation` 优先于默认值，也可逐处传 animation。目标中途改变时从当前显示矩形继续。减少动画下立即定位目标。

`NumericText` 首帧显示初值，随后对 Double 数值插值；未逐处指定动画时读取显式作用域或当前主题，`withAnimation(nil)` 会吸附；格式化由调用方提供，辅助功能立即获得最终文本。运行中重新赋值从当前显示值继续，减少动画立即吸附。它是数值过渡，不解析普通 Text 中的任意数字或执行字符滚轮效果。

## 生命周期缩放与阴影

```swift
AnimatedVisibility(
    isVisible: shown,
    transition: .opacity.combined(with: .scale(from: 0.94, anchor: CGPoint(x: 1, y: 0))),
    animation: Animation(duration: 0.2, curve: .easeOut)
) { panel }
```

锚点是节点 frame 内的归一化坐标：`(0, 0)` 左上，`(0.5, 0.5)` 中心，`(1, 1)` 右下。过渡到单位缩放时保持锚点，完成后恢复 identity；反转从当前显示值继续。同锚点缩放组合时倍率相乘；不同锚点用嵌套容器。非有限倍率回退到 1，负倍率夹到 0，非有限锚点分量回退到 0。

| 使用方式 | 表面、内容、圆角、描边 | ambient / key 阴影的 offsetX、offsetY、blur |
| --- | --- | --- |
| `Transition.scale(from:anchor:)` | 跟随过渡倍率 | 保留 authored 长度，保持入场高度感 |
| 普通 `.scaleEffect` / `Node.transform` | 跟随缩放倍率 | 同步缩放 |

普通变换默认 `NodeTransform.scalesShadow = true`，生命周期过渡内部使用 false。嵌套时独立累计绘制与阴影倍率；外层常驻缩放仍影响内层阴影，入场倍率不重复相乘。渲染不回写 authored `SurfaceShadow`。直接与缓存渲染采用同一规则，缓存比较包含阴影倍率，扩大的阴影重新进入视口时重新记录。文字、图像、自定义绘制与 overlay 的顶点和局部裁剪也随几何缩放。

进入中的内容在当前区域可点击，退出立即禁止输入、保留绘制至完成后移除。零倍率不接受命中。运行中减少动画会完成当前目标、取消尾部并释放调度。

## 圆形主题切换

在窗口根内容上启用；Gallery 的主题按钮已应用：

```swift
RootView().appearance(appearance, transition: .circular(duration: 1.0))

// 自定义配色用普通领域值标识一次主题变化。
RootView().theme(palette, transition: .circular(), value: themeMode)
```

默认 `.instant`。Button、Toggle / Switch 和 Checkbox 的指针、键盘、辅助功能激活均以控件中心为圆心；程序直接改变主题时使用窗口中心。只有传入的 appearance / value 改变才播放，普通重组和首次挂载不播放。每个窗口独立保存来源位置，输入提交后清除。

原生 GPU 渲染器在重绘前保留上一张已呈现画面，用全屏 shader 在圆外覆盖旧画面，在圆内显示新主题；每次播放只保存一次旧画面，每帧更新半径。布局、输入与语义立即使用新主题，文字、阴影和毛玻璃一起揭示。半径为零的首帧完整保留旧画面，避免先闪出新主题；中途反向以当前混合画面为起点。结束、取消或卸载清除请求并释放保留纹理，不把截图或进度写入工程配置。

减少动画、非法或非正时长立即显示新主题。窗口尺寸改变、尚无上一帧、后端没有可采样的上一帧来源时也立即切换；当前 in-game HUD 的快照路径使用此回退。Metal 与 SPIR-V 的离线 shader 已同步，macOS 原生窗口与 1× / 2× GPU 像素回读已验证；其他平台的设备表现仍需取样。

## 主题与 GuavaUI 应用

| 位置 | 应用 |
| --- | --- |
| Button 内置 chrome | `theme.motion.pressScale`（默认 0.97）与几何弹簧；外层激活区域保持稳定 |
| Toggle | 拇指使用可继承速度的几何弹簧，填色保持有界语义动画；Checkbox 的勾选进度保持有界 |
| 其他按钮与行样式 | Segment、Tab、侧栏、表格行 / 表头、命令面板行、建议行、单选、步进、日历、链接、手风琴标题、代码行号栏按钮和工作区面板标签，都在 hover / 按下 / 选中 / 焦点变化时以 `.fast` 过渡 |
| Popover / ContextMenu | `theme.motion.surface` 的进入 / 退出时长与 revealScale；默认 200ms / 90ms / 0.94，配合 6pt 位移与淡入淡出 |
| Spinner / Progress / Skeleton / loading Button | 节点拥有的通用 repeat 控制器，停止和卸载立即清理 |
| Gallery Progress | NumericText 百分比过渡 |
| Gallery 主题切换 | 从主题按钮中心向外扩散的 GPU 圆形揭示，默认 1s |
| Gallery Animation | 曲线、双向尺寸、关键帧、普通域相位、循环、共享几何、带速度拖拽和完成回调 |

主题还提供 `.semantic(.fast/.medium/.slow/.snappy/.bouncy/.smooth/.entering/.exiting, in: theme)`。没有样式配置可读主题的普通视图用 `.animation(motion: .fast, value:)`，在触发时按节点所在主题解析时长与曲线。fast / medium / slow 默认 80 / 180 / 320ms，entering 与 exiting 使用 decelerate / accelerate 曲线。Popover 按 leading / trailing 选择左上 / 右上锚点，右键菜单以指针处左上为锚点；靠窗口边缘仍由 Portal 限位，子菜单保持即时展开。

事件驱动宿主在提交或布局创建首个动画后立即进入下一轮，开启原生刷新或帧率回退，不先等待 250ms 空闲超时。毛玻璃合成透明度与表面、父节点和 subtreeOpacity 一起相乘，包含缓存与自定义缩放绘制；全透明时跳过模糊采样，避免“先出现空毛玻璃板，再突然出现文字”的开合表现。

## 生命周期与验收

Animation、时间轴、SpringSolution 与主题 token 是 authored 值；控制器、进度、速度、捕获和几何交接属于节点会话，不进入工程序列化，也没有随机种子。卸载取消有限和无限播放，释放捕获、完成组与缓存引用。减少动画时，未触发的序列保持初态，循环关键帧显示起点、相位循环显示第一相位，运行中或新触发的单次序列吸附终态；恢复动画不会重播已完成的单次序列。

- Portable `Animation/PlaybackTests.swift`：完整往返计数、延迟 / 丢帧 / 大时间、非法时长、轨道边界与平台、解析导数、双分量速度继承、收敛平衡点、完成判定、卸载取消无限播放和完成组立即释放。
- Compose `Animation/InteractionTests.swift`：真实鼠标拖动、释放速度、重新抓取、禁用 / 减少动画释放捕获、按压缩放与稳定点击区。
- `SequenceLifecycleTests`：未触发初态、减少动画切换、完成后不重播与空闲状态。
- `WithAnimationCompletionTests`、`AnimationValueModifierTests`、`AnimationIntegrationTests`：完成 / 中断 / 合并、运行中减少动画、显式 nil、属性与布局量。
- `TransitionScaleTests`、`SurfaceRevealTests` 与 Runtime `Transforms`：锚点、反转、阴影、内容 / overlay、命中、缓存与菜单关闭清理。
- `MultiWindowSmokeTests.newAnimationStartsWithoutIdleWait`：提交准备 / 绘制时创建首个动画，在原生刷新与回退帧率下不进入空闲等待；`BackdropOpacityTests`、`NativeUIBackdropTests.frostCompositeOpacity`：嵌套 / 缓存 / 缩放透明度和 GPU 像素淡入，全透明毛玻璃不改变背景。
- Gallery `AnimationSystemTests`：390 / 720 / 1280pt × light / dark 的轨道与相位，几何尺寸反转、数值辅助功能、循环销毁、减少动画静止、原生帧顺序的几何完成回调。
- `AppearanceRevealTests`、`RevealRequestTests`：Button / Switch 圆心、键盘反向切换、程序窗口中心、减少动画、卸载与缓存请求清理；`CircularRevealPixelTests`：1× / 2× GPU 首帧、圆内外像素、混合画面反向、无上一帧回退与完成清理。

上述自动化在 macOS 宿主运行。原生设备视觉与系统触摸派发仍按 [跨平台控件规范](adaptive-spec.md) 的矩阵取样；本轮不把宿主节点 / DrawList 回归视为手机真机截图验收。

全量验证入口：`swift test --package-path GuavaUI`、`swift test --package-path GuavaUI/Portable`、`swift test --package-path GuavaUI/Examples`。macOS Gallery 已实际展开 / 关闭 Dashboard 的 Size 下拉菜单及切换主题，原生帧日志记录到菜单入场与 1s 圆形揭示中的连续更新；Windows、Android 与 iOS 设备表现仍待取样。
