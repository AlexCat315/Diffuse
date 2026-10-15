# SplitView

横向或纵向双面板容器。`Float` 比例生成静态分隔线；`Binding<Float>` 生成可拖动、可键盘操作的分隔柄。

```swift
SplitView(.horizontal, fraction: $sidebarFraction,
          constraints: .init(fraction: 0.2...0.8,
                             minimumFirst: 150,
                             minimumSecond: 220)) {
    sidebar
} second: {
    content
}
```

`SplitConstraints` 同时表达推荐比例范围和两侧的逻辑点最小尺寸。计算先扣除分隔柄与两处 spacing，按照实际 pane 可用长度求比例；拖动的位移分母使用同一长度。空间足够时优先满足面板最小尺寸；比例范围与像素最小尺寸冲突时优先面板最小尺寸。空间不足时按两个最小尺寸的比例共享空间，不让面板把容器撑破。

测量通过布局观察更新，初次安装及尺寸变化后的重组收敛到约束结果；容器始终裁剪内容。窗口缩小只改变显示比例，保留软件持有的请求比例，窗口恢复时可恢复原分配。拖动/键盘/辅助功能操作才将约束后的值写回 binding。初始化与交互处理非有限比例，避免 Yoga 收到 NaN。

可调分隔柄在指针表面最少 7pt，包含触摸输入时最少 44pt，视觉分隔线始终为 1pt；静态分隔线使用 `dividerThickness`。输入集合实时变化时同步调整命中区和比例计算。横向响应 Left/Right，纵向响应 Up/Down，每次调整 2%；辅助功能 increment/decrement 走同一约束。PointerCapture 保持拖出分隔线后的拖动，松手释放。`spacing` 是两个 pane 与分隔柄之间的各一处额外间距。

## 响应式与输入密度

通过 `compact` 显式启用单面板模式。它按 SplitView 容器自身分配的轴向长度判断：横向 split 比较宽度，纵向 split 比较高度，不依赖窗口 width class。默认阈值为 600pt，小于阈值显示顶部两个页签和所选面板；等于或大于阈值恢复双栏。阈值非有限时使用默认值，负数视为零。纵向判断使用包含页签的外层高度，避免页签自身占位导致阈值来回切换。

```swift
@State private var pane: SplitPane = .second

SplitView(.horizontal, fraction: $sidebarFraction,
          constraints: .init(minimumFirst: 150, minimumSecond: 220),
          compact: .init(firstTitle: "导航", secondTitle: "内容") {
              $0.threshold = 600
              $0.selection = $pane
          }) {
    sidebar
} second: {
    content
}
```

两个标题由调用者提供，支持本地化；标题换行并随文字缩放增长，触摸页签命中区 ≥ 44pt。页签共享一个 Tab 停靠点，箭头、Home、End 切换，语义角色为 `tab`，包含完整标题与选中态。省略 `selection` 时组件保留内部选择，初始为 `.first`，整个组件卸载后重置；外部 binding 的生命周期由应用管理。

隐藏面板与分隔柄保留节点和本地 `@State`，不占布局、不绘制、不接收输入、不出现在辅助功能树中。面板内草稿与滚动位置保留，重新显示时滚动范围按新尺寸正常夹紧；ScrollView 不把隐藏子树的零布局作为新的滚动范围发布。折叠不会写回比例 binding，恢复双栏后重新使用原请求比例和约束。隐藏区域持有的指针捕获立即取消；焦点交给当前页签，恢复双栏时若焦点来自页签，则转到所选面板的首个可聚焦控件。仍可见面板内的焦点保持原节点。

未传 `compact` 时保持双面板呈现。现阶段没有通用 N 面板联动、邻接推挤、拖拽吸附点、RTL 分隔柄方向或面板最小尺寸的自动文字缩放策略。文档工作区的标签拖拽与持久化由 [Workspace](workspace.md) 负责。

`SplitPresentationTests` 覆盖 390/720/1280pt 容器、100%/200% 文字、light/dark、指针/触摸/混合输入、横纵阈值、草稿/滚动/节点保留、键盘/触摸操作和拖拽中折叠；同时通过 DevTools AI `query_ui_nodes` 校验隐藏控件不可见且不可输入，诊断结果不读取私有草稿。Gallery SplitView 包含宽窄与触摸预览，`SplitTests` 验证实际示例编辑和面板切换；macOS 原生 DevTools mirror 已取样普通双栏和 390pt 页签呈现。原生触摸及读屏仍按[跨平台规范](adaptive-spec.md)第 4 节设备矩阵取样。

实现：[SplitView](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/SplitView.swift)、[Constraints](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Split/Constraints.swift)、[Compact](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Split/Compact.swift)。
