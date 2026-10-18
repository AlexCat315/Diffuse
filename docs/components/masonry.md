# Masonry

平衡瀑布流布局。子视图按声明顺序放入当前最矮的列，列数由可用宽度与最小列宽决定，适合高度不一的卡片墙、作品集和仪表盘。

```swift
Masonry(minimumColumnWidth: 220, maximumColumns: 2,
        columnSpacing: 14, itemSpacing: 14) {
    for card in cards {
        CardView(card)
    }
}
```

## 列与间距

- 有限宽度下，列数为 `floor((width + columnSpacing) / (minimumColumnWidth + columnSpacing))`，夹在 1…`maximumColumns` 之间；默认最多 2 列。窄宽自动退化为单列，不会压缩到小于 `minimumColumnWidth` 的列。
- 列宽均分可用宽度；`columnSpacing` 只出现在列之间，`itemSpacing` 只出现在同列卡片之间。
- 列数或宽度变化时重新测量子视图，保留节点身份与子视图 `@State`。默认 `minimumColumnWidth = 160`、`maximumColumns = 2`、两个间距都是 12pt；`maximumColumns` 上限为 8。
- `alignment` 只控制卡片在列内的水平对齐；每列从顶部连续排列，没有额外垂直对齐空间。

## 测量与输入

- 子视图以列宽作为宽度 proposal 测量；高度由子视图自然决定。文本缩放、动态字体和卡片内部的重排由子视图自己处理，Masonry 不再二次缩放。
- RTL 下第 0 列位于 trailing 边，列顺序与源顺序保持不变。
- 未给出有限宽度时，以 `maximumColumns` 列按内容固有宽度测量，便于嵌入 `ViewThatFits`/自定义测量；正常页面应提供有界宽度。
- Masonry 只负责布局，不虚拟化、排序或管理卡片数据。大集合使用 `LazyGrid`（固定/已知行高）或 `VirtualStack`；需要二维轨道与显式列策略使用 `Grid`。

## 验收与边界

`MasonryTests` 覆盖最短列放置、column/item spacing、单列退化、列数上限与 RTL 镜像；Gallery `--component masonry` 提供真实卡片墙、Add card/Reset 与 390/720/1280 预览。DevTools 用 `query_ui_nodes` 读取卡片 frame 验证列数，用 `input-ui` 点击 Add card 验证重新平衡，用 `capture-ui` 截图确认视觉间距。

当前不提供跨列 span、行优先填充、列内独立滚动或窗口化；需要这些能力时组合 `Grid`/`LazyGrid` 或应用层虚拟化。
