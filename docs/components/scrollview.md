# ScrollView

可滚动视图。支持 `.vertical` / `.horizontal` / `.both`，根据内容尺寸自动决定是否绘制滚动条。

## Anatomy

```
┌────────────────────────────────┐
│                              ▲ │
│                              █ │ ← vertical thumb (仅 contentH > viewH 时绘制)
│         content              ░ │
│                              ░ │
│                              ▼ │
└────────────────────────────────┘
   ◀ ░░░░██████░░░ ▶                ← horizontal thumb (同条件)
```

## API

```swift
ScrollView {                  // 默认 .vertical
    Box(.column, .stretch, spacing: 8) { … }
}

ScrollView(.horizontal) { Row { … } }
ScrollView(.both) { … }
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `axes` | `.vertical` | `.vertical` / `.horizontal` / `.both` |
| `content` | 必填 | 子视图，按指定 axes 自由溢出 |

## Tokens

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| track | `theme.colors.surfaceVariant` | theme |
| thumb | `theme.colors.onSurfaceMuted` | theme |

## Behavior

- **wheel**：`SDL_MOUSEWHEEL` 路由到 hit 命中的 ScrollView，按轴位移
- **clipping**：`clipsToBounds = true`，超出视口的内容被裁剪
- **scrollbar**：仅在 `contentSize > viewSize` 时绘制（内容能完全显示则不显示条）
- **拖动 thumb**：未实现，仅滚轮可滚

## Known issues / TODO

- 不可拖动 thumb
- 没有 momentum / inertia
- 没有"是否显示滚动条"开关 —— 目前完全自动

## Authoring rules

✅ 应当：
- 把 ScrollView 作为 Tree / List / 长内容的外层
- 给 ScrollView `.flex()` 让它撑满父容器
- 内容用 `Box(.column, .stretch)` 而不是 `Column(.leading)`（后者不撑宽）

❌ 不应：
- 嵌套 ScrollView（同轴）
- 给 ScrollView 加 `.frame(height: 内容高度)` —— 那就不需要 ScrollView 了

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| SwiftUI | `ScrollView(_:)` API 形态 |
| macOS | overlay scrollbar (Lion+) |
| Web overflow | `overflow: auto` 的"按需显示"语义 |

## File map

- 主体: [GuavaUICompose/Primitives/ScrollView.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/ScrollView.swift)
