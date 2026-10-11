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

可调分隔柄最少 7pt，视觉分隔线 1pt；静态分隔线使用 `dividerThickness`。横向响应 Left/Right，纵向响应 Up/Down，每次调整 2%；辅助功能 increment/decrement 走同一约束。PointerCapture 保持拖出分隔线后的拖动，松手释放。`spacing` 是两个 pane 与分隔柄之间的各一处额外间距。

现阶段仍是双面板模型。可通过嵌套组合，但没有通用 N 面板联动、邻接推挤、折叠阈值/吸附点、RTL 方向或面板最小尺寸的自动文字缩放策略。文档工作区的标签拖拽与持久化由 [Workspace](workspace.md) 负责。

实现：[SplitView](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/SplitView.swift)、[Constraints](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Split/Constraints.swift)。
