# SplitView

可调比例的双面板分割。横向或纵向。

## Anatomy (horizontal)

```
┌──────────┬──────────────────────────────┐
│          │                              │
│  first   │  second                      │
│  (frac)  │  (1 - frac)                  │
│          │                              │
└──────────┴──────────────────────────────┘
           ↑ divider (1px, theme.colors.divider)
```

## API

```swift
SplitView(.horizontal, fraction: 0.3) {
    sidebar
} second: {
    workspace
}

// 嵌套：左 sidebar + 中间内容 + 右 inspector
SplitView(.horizontal, fraction: 0.18) {
    sidebar
} second: {
    SplitView(.horizontal, fraction: 0.74) {
        workspace
    } second: {
        inspector
    }
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `axis` | `.horizontal` | `.horizontal` 左右分；`.vertical` 上下分 |
| `fraction` | 0.5 | first 占比，自动 clamp 到 `[0.05, 0.95]` |
| `spacing` | 0 | 两 pane 之间的额外间距（除 divider 外） |
| `dividerThickness` | 1 | divider 像素厚度 |
| `dividerColor` | nil → `theme.colors.divider` | 显式传入会覆盖 token |

## Behavior

- 两个 pane 都按 `flex(fraction, shrink:1, basis:0)` 拿空间
- divider 是 `Divider` 原语，目前**不可拖动调整比例**（v1 限制）
- 跨轴方向上 `Box(alignItems: .stretch)` 让两 pane 各自撑满

## Known issues / TODO

- 不可拖动 divider 调整 fraction
- 不可保存 / 恢复 fraction（调用方需用 `@State` 自己存）
- 不可隐藏 / 折叠某一侧

## Authoring rules

✅ 应当：
- 把 SplitView 当作 IDE 三栏布局的核心
- 给 SplitView `.flex()` 让它撑满外层 Box
- 嵌套时外层 fraction 控制 sidebar 宽度，内层 fraction 控制 workspace/inspector 比例

❌ 不应：
- 给 SplitView 加 `.padding(...)` —— pane 应该贴到 divider
- 显式传 `dividerColor` —— 让它走 theme，方便切主题

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| VS Code | 三栏 + 嵌套 SplitView 的 IDE chrome 模式 |
| react-resizable-panels | API 形态（pane + handle） |
| AppKit `NSSplitView` | divider 厚度 + fraction |

## File map

- 主体: [GuavaUICompose/Primitives/SplitView.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/SplitView.swift)
