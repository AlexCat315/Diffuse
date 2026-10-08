# Sheet

Sheet 是贴窗口边缘的模态内容，支持 `.leading`、`.trailing`、`.top`、`.bottom`。左右抽屉填满高度，`extent` 控制宽度；上下抽屉填满宽度，`extent` 控制高度。尺寸夹紧到窗口，配置中的无效 extent 恢复默认 400pt。

```swift
Sheet(isPresented: $showSettings, configure: {
    $0.edge = .trailing
    $0.extent = 320
    $0.dismissal.closesOnBackdrop = true
    $0.dismissal.closesOnEscape = true
}) {
    SettingsForm()
}
```

Sheet 复用 Modal 的 Portal、背景阻挡和 FocusScope。打开时焦点进入内容，Tab 限制在模态范围；关闭后恢复原来的有效焦点。背景右键不关闭，Escape 和背景左键分别遵循 dismissal 配置。

进入与退出都沿所选边缘移动一个实际面板尺寸，背景单独淡入淡出；屏幕外的动画内容被裁剪。关闭立即停止内容交互，退出完成后卸载 Portal。动画由主题 medium motion 控制，复用 AnimatedVisibility 的状态保留和中途反转机制。

画廊 Sheet 页提供四个方向的打开按钮和可编辑开关，Disabled 开关阻止打开，操作按钮保留自然尺寸。四方向自动化通过实际布局和事件分发验证初始位置、最终大小、退出方向、输入停止、Escape、Portal 清理与焦点恢复；顶部和右侧在原生窗口检查过。
