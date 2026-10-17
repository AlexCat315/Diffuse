# Viewport Traits

`UIEnvironment.Viewport` 从 surface 尺寸派生 width class、height class 与 orientation。读取器与 `WidthClassReader` 同构，只用于壳层/页面级收敛，不用于卡片内部布局。

```swift
HeightClassReader { height in
    OrientationReader { orientation in
        if height == .compact || orientation == .portrait {
            CompactShell()
        } else {
            ExpandedShell()
        }
    }
}
```

## 阈值

| Trait | 取值 | 规则 |
| --- | --- | --- |
| `widthClass` | `.compact` / `.medium` / `.expanded` | `< 600` / `600–999` / `≥ 1000` |
| `heightClass` | `.compact` / `.medium` / `.expanded` | `< 600` / `600–999` / `≥ 1000` |
| `orientation` | `.portrait` / `.landscape` | `width < height` 为 portrait；宽度相等归 landscape |

阈值常量位于 `UIEnvironment.Viewport`：`compactMaximumWidth`、`expandedMinimumWidth`、`compactMaximumHeight`、`expandedMinimumHeight`。

## API

| 类型 | 说明 |
| --- | --- |
| `UIEnvironment.Viewport.heightClass` | 从当前 `height` 派生 |
| `UIEnvironment.Viewport.orientation` | 从当前宽高派生 |
| `HeightClassReader` | 将 height class 传入内容 |
| `OrientationReader` | 将 orientation 传入内容 |

Reader 是 `_PrimitiveView`，从 `SurfaceEnvironment` composition local 读取，不额外测量内容；viewport 变化会重建其子树，但节点身份与 `@State` 由内容保留。

## 边界

- 这些是 **surface/window** 级 trait；卡片内部宽度请用 `ContainerSizeReader` / `ContainerQuery`。
- 旋转时调用方负责把新 viewport 写入 surface environment；reader 不会自行从 Yoga 节点反推。
- 方形视口按 landscape 处理，避免桌面近方形窗口在两个方向间抖动。
- `ViewThatFits` 的内在内容拟合尚未实现；当前 `ViewThatFits` 仍按显式阈值选择分支。本页记录的 height/orientation 读取不改变该行为。

## 验证

- `ViewportTraitsTests.thresholds`：599/600/999/1000 的 width/height class 与方形/横竖屏边界。
- `ViewportTraitsTests.readers`：测试默认 1280×720 为 expanded/medium/landscape；切到 390×500 为 compact/compact/portrait，再切到 1200×1100 为 expanded/expanded/landscape。
- Gallery `viewportTraits` 页与 README 入口；DevTools 720×820 实测 `medium`/`medium`/`portrait`，390×820 实测 `compact`/`medium`/`portrait`，1200×842 实测 `expanded`/`medium`/`landscape`。

## File map

- 环境与派生：[Environment.swift](../../GuavaUI/Portable/Sources/GuavaUICore/Adaptive/Environment.swift)
- Reader：[ViewportTraits.swift](../../GuavaUI/Portable/Sources/GuavaUIComposeCore/Adaptive/ViewportTraits.swift)
- 测试：[ViewportTraitsTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/ViewportTraitsTests.swift)
