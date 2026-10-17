# Scrollbar

`Scrollbar` 是可聚焦的滚动条 companion。把它与 `ScrollView` 绑定到同一个 offset，就能获得可拖拽、可键盘操作、可被读屏识别的 thumb；`ScrollView` 自身仍只绘制轻量 chrome。

```swift
@State private var offset: CGFloat = 0

Row {
    ScrollView(.vertical, scrollOffset: Binding(
        get: { CGPoint(x: 0, y: offset) },
        set: { offset = $0.y })) {
        rows
    }.frame(width: 300, height: 260)

    Scrollbar(offset: $offset, contentExtent: 480, viewportExtent: 260)
        .frame(width: 12, height: 260)
}
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `axis` | `.vertical` | 垂直或水平 |
| `offset` | 必填 | 与 ScrollView 共享的 offset |
| `contentExtent` / `viewportExtent` | 必填 | 计算比例、thumb 长度与最大值 |
| `thickness` | 12 | 轨道厚度，最小 8 |
| `minimumThumbExtent` | 32 | thumb 最小长度 |
| `label` | `"Scrollbar"` | 辅助功能名称 |

## 行为

- 轨道与 thumb 用 `DrawList` 绘制；thumb 长度 `max(minimum, track × viewport / content)`。
- 指针按下即聚焦并捕获；拖动按 thumb 中心映射到 `0…maxOffset`。释放不产生惯性。
- 键盘 Up/Left、Down/Right 每次 `max(20, viewport × 0.1)`，PageUp/PageDown 为 `viewport × 0.9`，Home/End 到两端。
- 辅助功能 role `.slider`，value 为百分比，increment/decrement 按页，`setValue("50%")` 也可用；help 提供键盘提示。
- 键盘焦点可见时在 thumb 外绘制 2pt focus ring（先画环、再画 thumb，避免覆盖）。

## 边界

- 这是 **companion**：`ScrollView` 不会自动叠加它。调用方需要放置并绑定 offset；这也允许不使用 ScrollView 的自定义滚动区域复用 thumb。
- 触摸命中宽度等于轨道厚度（默认 12pt）；需要更大触摸目标时由调用方包一层 44pt 容器或使用应用自己的轨道。
- 只支持单轴；滚动内容尺寸变化时调用方负责更新 `contentExtent`。
- 无惯性、无自动隐藏/hover 淡出；视觉策略由调用方或主题决定。

## 验证

- `ScrollbarTests.keyboard`：role slider、0%、PageDown/Home、increment 与 `setValue("50%")`。
- `ScrollbarTests.drag`：拖动到底产生 >500 的 offset。
- `ScrollbarTests.geometry`：12×240 的请求几何。
- Gallery `scrollbar` 页绑定 480/260 的 ScrollView；DevTools 720×820 查询到 `Scrollbar value=0%`，拖到底后 `value=100%`、`Offset: 220`，PageUp 回到 `0%`。

## File map

- 主体：[Scrollbar.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Interaction/Scrollbar.swift)
- 测试：[ScrollbarTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/ScrollbarTests.swift)
