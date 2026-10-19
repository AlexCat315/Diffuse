# Chart

`Chart` 是唯一的图表组件：折线、面积、柱状（分组/堆叠）、散点与饼图/环形图，内置可切换图例与数据点选择。原 `MonitorChart`、`BarChart`、`SparklineChart`、`ChartLegend` 已合并进它。

```swift
@State private var point: ChartPoint?
@State private var hidden: Set<String> = []

Chart([.area(revenue, title: "Revenue"), .line(signups, color: .success, title: "Signups")],
      thresholds: [ChartThreshold(value: 30)]) {
    $0.label = "Monthly revenue and signups"
    $0.selection.point = $point          // 启用选择
    $0.legend.placement = .bottom        // 底部图例，点击切换系列
    $0.legend.hiddenSeries = $hidden     // 可选；不传时由图表自持
}
.frame(height: 200)

Chart([.bar(online, title: "Online"), .bar(retail, color: .info, title: "Retail")],
      style: ChartStyle(stacking: .stacked))

Chart([.points(x: latency, y: errors, color: .error, title: "Error rate")])

Chart(slices: [ChartSlice("Desktop", value: 58), ChartSlice("Mobile", value: 31)]) {
    $0.legend.placement = .bottom
}

Chart([.area(history)], style: .sparkline).frame(width: 160, height: 40)
```

## 数据与外观

| 类型 | 说明 |
| --- | --- |
| `ChartSeries` | `values`、可选 `xValues`（散点）、`color`、`mark`、`title`；`.line/.area/.bar/.points(x:y:)` 便捷构造 |
| `ChartMark` | `.line`（2pt，圆角连接）、`.area`（20% 填充 + 折线）、`.bar`（远离基线一端 3pt 圆角）、`.point`（3.5pt 圆点） |
| `ChartStyle` | 值域、网格线数、线宽、柱间距、内边距、背景、网格色、`stacking`（`.none/.stacked`）、`innerRadiusRatio`（环形孔径，0 为实心饼） |
| `ChartSlice` | 饼图切片；未指定颜色时按类别色板（accent/success/warning/accentSecondary/error/info）依次取色，默认主题中前五色互不相近 |
| `ChartThreshold` / `ChartMarker` | 水平阈值线 / 竖直标记线 |

- 混合图：只要存在柱状序列，所有标记都对齐到柱槽中心；多个柱状序列默认分组并排，`stacking: .stacked` 时柱与面积按索引累加。
- 值域：未指定时取可见数据、阈值与（存在柱/面积时的）0；隐藏序列不参与值域与布局。
- 环形图：从 12 点方向顺时针，切片间 1.5pt 表面色间隙；选中切片外扩 4pt，其余切片降至 55% 不透明度。
- 颜色均为 `SemanticColorRef`，随明暗主题解析；宽度随父容器，绘图区取图例之外的剩余高度（未约束时 64pt）。

## 交互

只有提供 `selection.point` 时图表才可交互（可聚焦、命中）：

- 指针：悬停预览最近的值；点击固定（再次点击同一点取消），离开后固定值保留。
- 触摸：按下或拖动按最近值擦洗，抬起后固定；饼图按角度与环宽命中，中心孔不命中。
- 键盘：Left/Right 在值之间移动，Up/Down 在可见序列之间移动，Home/End 跳到首尾，Escape 清除；连续按键在同一帧内也按最新选择累积。
- 选中值显示悬浮标注（系列名 + 格式化值，饼图附百分比），在绘图区内夹紧，上方空间不足时翻到点下方；标注不接收命中、不进入语义树。
- 辅助功能：图表为 image 角色，名称为 `label`，值为选中描述（如 "Revenue, point 2: 4"）或各序列范围摘要；increment/decrement 移动选中值。
- 图例：每项是 44pt 触摸友好的 ghost 按钮（toggle 语义，值为 Shown/Hidden）；隐藏项保留位置、空心色块并降低对比度；整项换行，RTL 从 trailing 开始。

## 验收与边界

`ChartTests` 覆盖被动图表、折线/面积几何、分组与堆叠柱、混合标记对齐、散点最近点、环形图角度与孔命中、阈值/标记与选中绘制；`ChartInteractionTests` 通过真实分发器覆盖点击固定与标注位置、键盘/辅助功能步进、图例切换与隐藏序列跳过、窄宽换行及触摸饼图命中。Gallery `chart` 页提供面积+折线（阈值、选择、图例）、分组/堆叠柱、散点、环形图与 sparkline。

当前不提供坐标轴刻度标签、时间轴、缩放平移与动画过渡；超大数据集请先降采样。
