# Sheet

Sheet 是从窗口边缘进入的模态面板，支持 `.leading`、`.trailing`、`.top`、`.bottom`。默认距窗口四边 12pt、圆角 14pt，像 iOS 的浮动 sheet 而不是贴边方形抽屉；左右面板的高度为窗口减去上下 inset，`extent` 控制宽度；上下面板宽度为窗口减去左右 inset，`extent` 控制高度。尺寸夹紧到窗口；无效 extent 恢复 400pt，`inset`/`cornerRadius` 会夹到非负值。

```swift
Sheet(isPresented: $showSettings, configure: {
    $0.edge = .trailing
    $0.extent = 320
    $0.inset = 12
    $0.cornerRadius = 14
    $0.dismissal.closesOnBackdrop = true
    $0.dismissal.closesOnEscape = true
}) {
    SettingsForm()
}
```

Sheet 复用 Modal 的 Portal、背景阻挡和 FocusScope。打开时焦点进入内容，Tab 限制在模态范围；关闭后恢复原来的有效焦点。背景右键不关闭，Escape 和背景左键分别遵循 dismissal 配置。

进入与退出都沿所选边缘移动一个实际面板尺寸，背景单独淡入淡出；屏幕外的动画内容被裁剪。关闭立即停止内容交互，退出完成后卸载 Portal。动画由主题 medium motion 控制，复用 AnimatedVisibility 的状态保留和中途反转机制。浮动 inset 让面板四周的圆角与背景遮罩始终可见。

画廊 Sheet 页提供四个方向的打开按钮和可编辑开关，Disabled 开关阻止打开，操作按钮保留自然尺寸。四方向自动化通过实际布局和事件分发验证初始位置、最终大小、退出方向、输入停止、Escape、Portal 清理与焦点恢复；800×600 下 leading/trailing 为 200×576 @ (12,12)/(588,12)，top/bottom 为 776×200 @ (12,12)/(12,388)。顶部和右侧在原生窗口检查过。
