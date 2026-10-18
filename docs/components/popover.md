# Popover

`Popover` 与 `Popconfirm` 共用窗口 Portal、卡片和箭头绘制、尺寸约束、焦点与关闭机制。默认 `surface: .bubble` 已经提供不透明 `surfaceFloating`、主题圆角、1pt 描边、low 阴影、内容内边距和指向触发器的箭头，调用方直接提供内容即可。

```swift
Popover(isPresented: $open, width: 300, placement: .top,
        label: { Text("Project settings") }) {
    Text("Project name").font(.bodyStrong)
    TextField("Name", text: $name)
    Button("Done") { open = false }
}
```

## 方位与空间不足

`PopoverPlacement` 同时用于 Popover 与 Popconfirm，共有 12 个方向：topLeading/top/topTrailing、bottomLeading/bottom/bottomTrailing、leadingTop/leading/leadingBottom、trailingTop/trailing/trailingBottom。前导/尾随遵循触发器布局方向。

默认 `overflow: .constrain` 保持指定方向：top 在上方、bottom 在下方，侧向同理；横向或纵向空间不足时缩小该侧的可用视口并允许内部滚动，不会暗中换边。指定侧完全没有可用空间时无法呈现可操作内容，调用方应选择有空间的方位，或明确采用下面的自适应策略。

菜单、选择器等需要自动避让边缘时显式使用 `overflow: .flip`；仅当首选侧放不下且相对侧能够容纳面板时才换边，两侧均放不下则夹紧窗口并滚动。最终几何由这一套定位器决定，Portal 不再二次翻转它。

## 已有表面的内容

Menu、日期/颜色选择器等自身已经绘制了表面，使用 `surface: .content`，避免重复卡片和内边距。所有第一方调用已显式迁移；旧的 start/end 方位改为 bottomLeading/bottomTrailing。

```swift
Popover(isPresented: $open, width: 240,
        placement: .bottomTrailing, surface: .content, overflow: .flip,
        label: { Text("Commands") }) {
    Menu(entries, width: 240)
}
```

## 输入与验收

打开后焦点进入内容，Tab 限制在浮层内；Escape、外部点击或再次点击触发器关闭，并还原触发器焦点。禁用和卸载清理 Portal。减少动画、主题、字号、输入环境与局部 RTL 沿用触发器。

`PopoverTests`、`SurfaceRevealTests` 验证原有菜单、过渡、点击、重开与关闭；`PopconfirmTests.sharedCard` 验证普通 Popover 无需自画卡片，`namedSides` 验证 12 向与 RTL 的真实 Portal 坐标。三档宽度、主题、字体与输入矩阵见 [Popconfirm](popconfirm.md)。Gallery 的 Popover 页使用默认共享卡片，Popconfirm 页提供紧凑定位面板和窄屏单锚点预览。

普通 Button 不再默认把标题重复显示为 tooltip；额外说明通过 `tooltip:` 显式提供，见 [Button](button.md)。
