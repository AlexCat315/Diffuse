# 生命周期缩放与阴影

`AnimatedVisibility` 在进入和退出时保留子树，通过 `Transition` 组合透明度、位移、缩放和高度折叠。缩放改变绘制与命中几何，不改变 authored 布局尺寸。

```swift
AnimatedVisibility(
    isVisible: shown,
    transition: .opacity.combined(with: .scale(from: 0.96, anchor: CGPoint(x: 1, y: 0))),
    animation: Animation(duration: 0.16, curve: .easeOut)
) {
    panel
}
```

锚点是节点自身 frame 内的归一化坐标：`(0, 0)` 左上，`(0.5, 0.5)` 中心，`(1, 1)` 右下。过渡到单位缩放时保持原锚点，完成后恢复 identity；中途反转从当前显示值继续。相同锚点的缩放可以组合，倍率相乘；不同锚点需要嵌套 `AnimatedVisibility`。非有限倍率回退到 1，负倍率夹到 0，非有限锚点分量回退到 0。

## 阴影策略

| 使用方式 | 表面、内容、圆角、描边 | ambient / key 阴影的 offsetX、offsetY、blur |
| --- | --- | --- |
| `Transition.scale(from:anchor:)` | 跟随过渡倍率 | 保留 authored 长度，使浮层在入场期间保持相同高度感 |
| 普通 `Node.transform` 缩放，如常驻按下反馈 | 跟随缩放倍率 | 同步缩放 |

普通变换默认 `NodeTransform.scalesShadow = true`；生命周期过渡内部使用 `false`。嵌套时独立累积绘制倍率与阴影倍率，因此外层常驻缩放仍影响内层浮层的阴影，入场倍率不会再乘一次。颜色和透明度不因这一策略改变；渲染只解析长度，不回写节点上的 `SurfaceShadow`。

直接渲染和缓存渲染采用相同策略，缓存比较包含阴影倍率。自定义内容绘制（包括文字、图像）与 overlay 的顶点、局部裁剪也跟随几何缩放，避免表面缩小但内容尺寸保持不变。阴影没有额外的全局开关或持久化字段。

## 菜单与输入

Popover 和右键菜单采用 `0.96 → 1` 的缩放，组合现有的透明度与 4pt 位移，进入 160ms、退出 90ms。Popover 的 leading / trailing 对齐分别使用左上 / 右上锚点；右键菜单使用指针处的左上锚点。此处描述逻辑对齐锚点；靠窗口边缘的最终位置仍由 Portal 限位。子菜单保持现有即时展开行为。

绘制、`absoluteFrame`、窗口到局部坐标转换和命中测试共用节点变换。进入中的菜单在当前显示区域可点击；退出立即禁用输入，保留绘制直到完成后移除。零倍率节点不接受命中。`reducedMotion` 下直接到终态，运行中启用也立即完成并清理调度。

## 验证

- `TransitionScaleTests`：非零锚点、组合与插值端点、动画反转、退出清理、非法输入、运行中减少动画。
- `SurfaceRevealTests`：leading / trailing 菜单在入场中接受实际鼠标点击，减少动画下直接展示，关闭后清理 Portal 和 scheduler。
- `ScaledHitTesterTests` / `NodeTransformRenderTests`：锚点、嵌套、滚动、零倍率与缓存几何。
- `ShadowTests`：两层阴影、普通 / 过渡缩放、嵌套倍率、仅阴影策略变化时的缓存更新及 authored 值保持。
- `PaintTests`：带偏移的嵌套节点、自定义绘制与 overlay、局部裁剪、直接与缓存渲染一致。

上述为 macOS 宿主的节点、DrawList 和输入回归。真机入场观感仍按 [跨平台控件规范](adaptive-spec.md) 的视觉矩阵取样。

本轮 `swift test --package-path GuavaUI`、`swift test --package-path GuavaUI/Portable` 与 `swift test --package-path GuavaUI/Examples` 均通过；主包包含 307 项 Runtime、689 项 Compose 测试，Gallery 12 项测试通过。
