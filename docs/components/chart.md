# Chart / ChartLegend

`MonitorChart` 绘制多序列折线/柱状图，`BarChart` / `SparklineChart` 是紧凑封装。`ChartLegend` 负责把带标题的序列呈现为可折行的图例。

```swift
let series = [
    ChartSeries.line(revenue, color: .accent, title: "Revenue"),
    ChartSeries.line(signups, color: .success, title: "Signups"),
    ChartSeries.line(conversion, color: .warning, title: "Conversion")
]

MonitorChart(series: series, thresholds: [ChartThreshold(value: 30)])
    .frame(height: 140)
ChartLegend(series: series)
```

## 数据与外观

- `ChartSeries.title` 是图例名称；留空表示该序列只绘制、不进入图例。`ChartLegend(series:)` 自动过滤空标题，`ChartLegend(items:)` 可传任意 `ChartLegendItem(title:color:)`。
- 序列颜色来自 `SemanticColorRef`，随明暗主题解析；色块是装饰，完整标题保留为每个图例项的辅助功能名称，并单行显示。
- `ChartLegend` 使用 wrap 行布局：宽容器内保持一行，窄容器整项换行，不会拆开色块与标题。图例不改变图表几何，也不自行选择颜色。
- 图表宽度跟随父容器、字号不缩放；数据点辅助功能值、threshold/marker 与网格由 `MonitorChart` 负责。图例是展示层，不提供系列开关或数据点选择；需要交互开关时由调用方维护 `series` 数组。

## 验收与边界

`ChartLegendTests` 覆盖窄/宽容器的整项折行、标题投影、空标题过滤、辅助功能名称与 RTL trailing 起始；Gallery `chart` 页新增多序列图、宽/窄图例与 “Show signups” 开关。DevTools 在 720×820 下实测宽图例四项同一行（y=612），220pt 窄容器折为两行（Revenue/Signups 第一行，Conversion/Latency 第二行）；`input-ui` 点击 “Show signups” 后宽图例从 4 项变为 3 项，`capture-ui` 截图复核色块、间距与文字。

当前不提供 legend 选择/隐藏联动、pie/area/scatter/stacked、数据点选择或图例图标；这些仍是 [gaps](gaps.md) 中 Chart 的 P2 缺口。多序列数据与交互状态由调用方持有。
