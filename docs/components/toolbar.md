# Toolbar

Toolbar 统一工具栏的密度、表面、分隔与横向键盘导航。命令型工具栏根据实测内容宽度，把低优先级命令移到“更多”菜单；自定义内容仍可用内容闭包组合。

## 命令与布局

```swift
Toolbar(items: [
    ToolbarItem(MenuItem(id: "save", title: "Save") { save() }, placement: .always),
    ToolbarItem(MenuItem(id: "export", title: "Export selection") { export() },
                placement: .automatic(priority: 10)),
    ToolbarItem(MenuItem(id: "settings", title: "Settings") { settings() },
                placement: .overflow)
]) {
    $0.label = "Project commands"
    $0.isEnabled = isEnabled
}
```

每个 ToolbarItem 直接持有 MenuItem，工具栏与菜单复用同一份名称、动作、禁用、选中及危险角色。ID 必须唯一且稳定。调用方不需要测量文字、判断设备、注册命令或同步两份动作。

| placement | 行为 |
| --- | --- |
| `.always` | 始终留在工具栏，适合主操作和关闭 |
| `.automatic(priority: 0)` | 空间不足时从低优先级开始移入菜单；同优先级后声明的先收起 |
| `.overflow` | 始终放在更多菜单 |

提供 `icon:` 的命令在工具栏中使用图标，完整名称作为 tooltip 和辅助功能名称；菜单始终显示完整标题。未提供图标的命令按自然文字宽度测量，不缩字号或把标题裁掉来塞入。没有溢出项时“更多”入口不占布局、绘制、输入或辅助功能位置。主操作总宽度超过容器时保留自然尺寸并横向滚动。

布局读取工具栏自身的内容盒宽度，不依赖窗口断点。测量使用实际按钮树，自动包含字体、TextScaler、controlSize、样式和触摸下限；每次先为更多入口预留空间，再选择可见命令。保留的节点在尺寸变化和溢出切换中不重建。隐藏项不参与焦点和辅助功能，命令的业务状态由调用方持有。

## 垂直工具栏

`ToolbarOptions.axis = .vertical` 让同一 Toolbar 竖向排列：Up/Down 与 Home/End 移动焦点（Left/Right 不再导航），`ToolbarGroup` 与 `ToolbarSeparator` 随轴向改为竖排和横线，`divider` 可取 `.leading`/`.trailing` 贴在内容一侧。`Toolbar(items:)` 竖向时按高度测量并溢出，“更多”使用竖向省略图标，菜单在工具栏侧边（trailingBottom）打开。辅助功能仍为 toolbar 角色，节点带 `toolbar.axis` 附件供查询。`VerticalToolbarTests` 覆盖竖排几何、方向键与按高度溢出；Gallery `toolbar` 页提供竖向工具栏与竖向命令溢出示例。

## 自定义内容

```swift
Toolbar(configure: { $0.label = "Search tools" }) {
    ToolbarGroup(label: "Playback") { playbackButtons }
    ToolbarSeparator()
    TextField("Find", text: $query)
}
```

内容闭包适合输入框、分组及应用布局；它不把任意子视图自动转换成菜单项。需要自动溢出的命令使用 `items:`，混合内容由调用方显式选择换行、滚动或替代呈现。ToolbarGroup 提供分组语义和可选边框；ToolbarSeparator 是装饰，不暴露辅助功能操作。

## 响应式与输入密度

默认高度是 `controlSize.buttonHeight + 8`，水平 padding 取 `theme.spacing.sm`、命令间距取 `theme.spacing.xs`，背景为 `surface`，按钮默认 ghost。高度是下限，允许大字号自然增高。触摸命令及更多入口至少 44×44pt，菜单行复用 Menu 的触摸密度；混合输入保留 44pt 和 hover，切回指针恢复 authored 尺寸。

- Left / Right / Home / End 在可用命令与更多入口间移动，自动显露横向滚动中的目标。子输入框先处理自己的光标键。
- Space / Return 激活按钮；更多菜单复用 Menu 的上下键、Home / End、类型查找、Escape 与激活行为。
- 命令移入菜单时，键盘焦点交给更多入口；最后一个溢出项回到工具栏时关闭菜单并把焦点还给工具栏。
- 整条禁用时阻断输入、清除焦点与捕获并关闭菜单；再次启用不会自动重开。卸载清理 Portal。
- 工具栏为 toolbar 语义，更多入口提供完整名称和 expanded，菜单保留 selected / disabled。隐藏的 inline 命令不重复出现在辅助功能树中。

## 验证与文件

`ToolbarOverflowTests` 在 macOS 宿主覆盖 390/720/1280pt、100%/200% 字号、touch-only / 混合 / 指针输入、真实键盘和指针菜单操作、节点保留、优先级、禁用项跳过、焦点交接、关闭与卸载。Gallery `--component toolbar` 提供可交互命令栏及窄/宽/触摸预览；宿主测试不替代 Android / iOS 的原生触摸与读屏验收。

- [Toolbar.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Toolbar.swift)：容器、分组、键盘导航。
- [Toolbar/Commands.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Toolbar/Commands.swift)：命令入口与菜单。
- [Toolbar/OverflowLayout.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Toolbar/OverflowLayout.swift)：实测布局与优先级。
- [Toolbar/RetainedCommand.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Toolbar/RetainedCommand.swift)：节点保留及输入、语义和焦点交接。

通用截断、壳层收敛和其他控件缺口继续按 [跨平台规范](adaptive-spec.md) 与 [缺失清单](gaps.md) 验收。
