# Tooltip

短说明浮层通过 `LayerRoot` 的 Portal 层显示，脱离目标的内容裁剪。按钮的 `tooltip` 参数与通用组件共用同一套会话、主题和生命周期，不再额外维护即时绘制注册表。

```swift
LayerRoot {
    Button(icon: .resource(UICommonIcons.close), tooltip: "Close panel") { close() }
    Text("Status").tooltip("The current background task status.") {
        $0.delay = 0.45
        $0.maxWidth = 280
    }
}
```

默认停留 450ms 后出现。可见键盘焦点同样触发说明；鼠标点击造成的焦点不持续触发。指针离开且无键盘焦点时关闭。点击、键盘激活、Escape、禁用或卸载关闭浮层并取消待显示状态；Escape 保留目标焦点，直到离开/失焦后才允许再次触发。

说明使用自然宽度，超过 `maxWidth` 时换行；默认最大 320pt。Portal 在窗口内夹紧，底部不足时翻到锚点上方。提示继承目标主题，不接收指针或键盘输入；交互内容应使用 Popover 或独立的 HoverCard。

自定义内容使用 `Tooltip(target:content:)`。异步生产者（例如 LSP）已经控制请求节奏，可用 `Tooltip(anchor:isPresented:configure:content:)`：坐标以窗口为单位，point/range 锚点的显隐直接跟随生产者，`delay` 不再应用第二次。

`TooltipOptions` 独立校验 `delay`、`maxWidth`、`gap` 和 `isEnabled`。Button 保留其原有 hit-test、布局和焦点节点，只挂载需要的 Tooltip/Portal resource；没有为每个按钮增加包装视图。按钮说明同时暴露为辅助功能 help，显示的文本可进入可访问性树。

自动化覆盖延迟、键盘焦点、窗口底部翻转、自然宽度、可访问性文本、Escape、激活、禁用和卸载。画廊 Button 与 Tooltip 页展示两种公开入口。
