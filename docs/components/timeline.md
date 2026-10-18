# Timeline

垂直事件序列，适合构建日志、操作记录与活动列表。事件用 `TimelineEvent` 的稳定 `id` 标识，`title`、`detail`、`trailing` 分别提供标题、说明和时间等元信息；`tone` 与图标表达结果。

```swift
Timeline(events: [
    TimelineEvent("Build started", id: "started", trailing: "09:12", tone: .info),
    TimelineEvent("Shaders compiled", id: "compiled",
                  detail: "All target profiles are available.",
                  trailing: "09:14 · Shanghai", tone: .success)
])
```

最后一项默认不画延续线。设置 `showsTrailingConnector = true` 可保留；`isCompact` 或 `showsIcon = false` 使用圆点。Timeline 是只读内容，不增加键盘停靠或全局注册。

## 响应式与输入密度

- 使用自身实测内容宽度，独立卡片里的窄 Timeline 与窄窗口行为一致。
- 标题区域不足 600pt 时，元信息移到标题下方；宽屏也先测量两段文字的自然宽度，放不下时纵向排列。
- 标题、元信息、说明完整换行。`TextScaler` 只应用一次；行高随内容增长，连接线随行延伸。外层应用需要固定视口时使用 `ScrollView`，不固定事件行高。
- RTL 下对调轨道与文字的逻辑前导、尾随位置。布局变化复用同一文字节点；稳定事件 ID 使重排后的事件保留身份。
- 辅助功能提供 `list` / `listItem`：标题为名称、元信息为值、说明为 help，装饰图标不重复朗读。DevTools 可按完整名称、值或说明查询。

## 验收

- `TimelineTests.matrix`：1280pt 宿主内的 390/720/1280pt 容器，100%/200% 字号、明暗主题、触摸/混合/指针输入及 RTL；验证上下/并排几何、完整换行、主题颜色、事件节点和外部焦点保留。
- `TimelineTests.reorderAndDiagnostics`：事件重排、时间值实时更新、经校验的 AI 查询、清空卸载。
- `TimelineTests.metadataEdges`：没有时间时不占空行，极窄容器中的长时间信息换行。
- Gallery `timeline` 包含长标题、中英文说明与完整时间；三种自适应预览使用内部滚动视口容纳大字号内容。

2026-10-18 原生验收：macOS / Metal，390、720、1280 × light/dark × 100%/200%，通过 DevTools `query-ui`、`input-ui` 与 `capture-ui` 查询、切换和读取实际绘制画面。100% 下，主示例的短标题/长标题事件高度分别为 390pt 的 69/129pt、720pt 的 69/69pt、1280pt 的 48/48pt；1280pt 并排时间，大字号放不下时移到下一行。查询 `role=listItem, text="Build worker in Shanghai"` 能用时间值定位到唯一事件，`get_diagnostics.layoutIssues.total` 为 0。390pt 触摸嵌入预览在 200% 下保留独立 140pt 滚动视口；窗口宽度往返与物理输入形态的保留断言由上述组件测试覆盖。未使用操作系统自动化，原生截图不替代手机真机触摸验收。

```sh
swift test --package-path GuavaUI --no-parallel --filter 'TimelineTests|timelineContent'
swift test --package-path GuavaUI/Examples --no-parallel
```

分组、折叠和时间轴缩放仍由 [缺口清单](gaps.md) 跟踪。

## 文件

- `GuavaUI/Sources/GuavaUICompose/Primitives/Data/Timeline.swift`：事件模型、轨道和语义。
- `GuavaUI/Sources/GuavaUICompose/Primitives/Data/Timeline/HeadingLayout.swift`：同一标题与元信息节点的测量和重排。
- `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/TimelineTests.swift`：布局、状态和 AI 查询断言。
