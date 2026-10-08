# Menu / ContextMenu / Select

菜单现在由独立的描述模型、导航会话、行宿主和 Portal 放置组成；不再把菜单渲染和 Select 的键盘状态混在一个文件里。

```swift
Popover(isPresented: $open, width: 240) {
    Text("Workspace commands")
} content: {
    Menu([
        .item(MenuItem(id: "copy", title: "Copy",
                       shortcut: KeyboardShortcut.primary("C").displayString) { copy() }),
        .separator("settings"),
        .submenu(MenuSubmenu(id: "appearance", title: "Appearance", entries: [
            .item(MenuItem(id: "dark", title: "Dark theme") { changeTheme() })
        ]))
    ], width: 240, onItemActivated: { open = false })
}
```

条目支持命令、选中勾、禁用、危险状态、分组文字、分隔线和任意层级的子菜单。子菜单没有伪命令：它持有子条目、独立宽度和启用状态。`MenuDescriptor` 也支持分组和嵌套，直接转换这棵树。

同层 ID 必须唯一且稳定。省略 `MenuItem.id` 时以 title 为 ID；重复标题、可变标题或动态列表应显式传 ID。分隔线和分组同样使用稳定 ID。`maxVisibleRows` 控制高度上限，真实视口还受窗口尺寸限制；当前菜单创建所有行，100 行示例不代表虚拟化大列表性能。

Up/Down 循环跳过禁用和非命令条目，Home/End 选择边界，键盘导航移动实际焦点并显露目标行。文字输入提供忽略大小写和重音的前缀查找；重复单字母循环，800ms 后重置。Right 打开子菜单；Left 或 Escape 返回父层；根层 Escape 与 Tab 请求关闭。Enter/Space 激活叶子并关闭整组弹出菜单。自动重复的激活键不会再次执行命令。Select 复用这些行为，从当前选中项开始，键盘不再能选中禁用项。

指针停留 180ms 后打开或切换分支，离开待打开行时取消。已经打开的分支在进入子菜单时保持。子菜单在独立 Portal 中绘制，超出右侧时翻到左侧，垂直夹紧到窗口；它不会被父菜单滚动区域裁剪。父行完全滚出视口、禁用、移除或父 Portal 关闭时子层立即清理。Portal 按打开顺序叠放，最深层在最上方。关闭子层恢复对应父行焦点，关闭整组恢复触发按钮。

导航、高亮、滚动、前缀查找和 hover 计时是瞬态会话。子浮层持有共享会话，避免父视图值替换后回调修改已经失效的 `@State` 存储。行的标题、启用、选中和展开状态进入辅助功能树；macOS 静态文字通过 AXValue 暴露。

自动化覆盖多级键盘和实际焦点、分隔线/禁用项、100 行滚动、前缀查找、hover 取消、叶子点击、窗口翻转、锚点滚出、禁用和父层销毁。画廊 Menu 页展示四级菜单、内联菜单及 100 条目滚动菜单；ContextMenu 页展示嵌套右键命令。

仍缺自定义富内容行、命令图标槽、链接语义，以及基于指针运动三角区域的更精细 submenu intent。当前短延迟是稳定切换基础，不声称与 GPUI 所有行为等价。

原生画廊已验证四层 Workspace → Settings → Appearance → Accent color 菜单，文字、选择列、快捷键、分隔线和箭头对齐；选择 Green 后所有浮层关闭且示例反馈更新。超长标签目前裁切，尚未提供省略号或自动宽度测量。
