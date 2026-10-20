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
- **自动隐藏**（hover 能力面，与 ScrollView 内建 chrome 同一契约）：静止隐藏；指针悬停条区域、键盘/读屏聚焦、拖拽中任一持有即淡入，全部释放后淡出。滚动 offset 变化时短暂闪现——立即出现，静止 0.7s 后 0.3s 淡出，与触摸指示条同组数字；闪现期间任一持有态介入会截停淡出。减少动画时过渡即时吸附，闪现保持可见而不做淡出动画。
- **触摸面**（无 hover 可揭示）保持常显；配对 ScrollView 自己的 3pt 细指示条已承担"滚动时显示"。
- 隐藏时保留 slider 语义（聚焦即揭示，是读屏入口）与 hit-testable（hover enter 依赖它）；opacity 0 时不绘制。

## 边界

- 这是 **companion**：`ScrollView` 不会自动叠加它。调用方需要放置并绑定 offset；这也允许不使用 ScrollView 的自定义滚动区域复用 thumb。
- 触摸命中宽度等于轨道厚度（默认 12pt）；需要更大触摸目标时由调用方包一层 44pt 容器或使用应用自己的轨道。
- 只支持单轴；滚动内容尺寸变化时调用方负责更新 `contentExtent`。
- 无惯性。指针面没有"常显"开关——需要常显的调用方出现时按需加参。

## 验证

- `ScrollbarTests.keyboard`：role slider、0%、PageDown/Home、increment 与 `setValue("50%")`。
- `ScrollbarTests.drag`：拖动到底产生 >500 的 offset。
- `ScrollbarTests.geometry`：12×240 的请求几何。
- 自动隐藏：`autoHideFollowsHover`（静止隐藏、hover 淡入/离开淡出）、`scrollFlash`（offset 变化闪现、0.7s+0.3s 后隐藏）、`focusHoldsVisible`（聚焦持有、hover 抖动不隐藏、失焦隐藏）、`dragHoldsVisible`（拖拽持有、释放后因聚焦保持）、`reducedMotionSnaps`（即时吸附、无在飞动画）、`touchSurfaceKeepsVisible`（触摸面常显）、`hoverMotionDoesNotScrub`（未按下的指针移动不 scrub）。
- Gallery `scrollbar` 页绑定 480/260 的 ScrollView；DevTools 720×820 查询到 `Scrollbar value=0%`，拖到底后 `value=100%`、`Offset: 220`，PageUp 回到 `0%`。
- 自动隐藏 DevTools 闭环（2026-10-20）：720×820 指针面静止镜像无滚动条；`pointerMove` 到条区域后 track/thumb 出现且 offset 保持 0（验收中发现并修复 motion 处理器未按 capture 门控、悬停即 scrub 的既有缺陷）；内容区滚轮滚动 offset 0→220，companion 立即闪现；移开静止 1.5s 后隐藏。390×820 触摸面静止常显。

## File map

- 主体：[Scrollbar.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Interaction/Scrollbar.swift)
- 测试：[ScrollbarTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/ScrollbarTests.swift)
