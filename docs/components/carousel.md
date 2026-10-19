# Carousel

`Carousel` 一次显示一页：两侧箭头、下方位置指示器、左右/Home/End 键盘导航，以及与原生滑动一致的阈值水平拖动（滑动会取消页内按钮的按压）。选择可以由调用方 binding 持有，也可以留在组件内部。

```swift
Carousel(pages: pages, selection: $page) {
    $0.autoplay = CarouselAutoplay(interval: 4)
    $0.indicator = .automatic
    $0.height = 176
}
```

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `showsArrows` | true | 两侧上一页/下一页按钮 |
| `indicator` | `.automatic` | `.dots`、`.fraction`（“3 / 12”）、`.hidden`；automatic 在 8 页以内用圆点，更多时用计数；单页不显示 |
| `autoplay` | nil | `CarouselAutoplay(interval:)`，间隔夹到 2–60 秒 |
| `allowsWrap` | true | 关闭后首尾为边界，自动轮播停在最后一页 |
| `height` | nil | 视口高度；视口始终占满轮播宽度，页面宽度变化不会移动箭头 |

## 自动轮播

自动轮播遵循 WCAG 2.2.2：只要配置了 autoplay，指示器旁就有播放/暂停按钮（“Pause automatic rotation” / “Start automatic rotation”）。以下情况暂停计时：指针悬停在轮播上、键盘焦点在轮播内、组件禁用、观看者按下暂停。系统开启“减少动态效果”时默认暂停，观看者可以手动开始。任何来源的翻页（箭头、圆点、键盘、滑动、绑定写入）都会重新开始计时；时钟每帧读取实际页码，不依赖重新组合。播放时当前圆点随间隔填充，暂停时为实心。计时由 `AnimatorScheduler` 驱动，暂停、禁用或卸载时注销。

## 验收

`CarouselTests` 覆盖按间隔前进与手动翻页重新计时、悬停/焦点/暂停按钮/不循环时的停止、减少动态效果默认暂停与间隔夹紧、automatic 指示器的圆点与计数切换、页面宽度变化时视口不变，以及原有的键盘、滑动和边界行为。DevTools 在 1280 Gallery `--component carousel` 中观察到：指针移开后约 4 秒从第 1 页前进到第 2 页，当前圆点随间隔填充；点击暂停后 4.5 秒内停在原页，按钮变为播放；12 页示例显示 “1 / 12”；镜像确认不同页面的视口与箭头位置一致。
