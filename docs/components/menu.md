# Menu / ContextMenu / Select

菜单现在由独立的描述模型、导航会话、行宿主和 Portal 放置组成；不再把菜单渲染和 Select 的键盘状态混在一个文件里。

```swift
Popover(isPresented: $open, width: 240, surface: .content, overflow: .flip) {
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

同层 ID 必须唯一且稳定。省略 `MenuItem.id` 时以 title 为 ID；重复标题、可变标题或动态列表应显式传 ID。分隔线和分组同样使用稳定 ID。长标题在可用宽度内自然换行，行高随文字测量增长，快捷键和子菜单箭头保留独立列。`maxVisibleRows` 按当前正文行高控制视口高度上限，多行标题可能使可见条目数减少；真实视口还受窗口尺寸限制。当前菜单创建所有行，100 行示例不代表虚拟化大列表性能。

Up/Down 循环跳过禁用和非命令条目，Home/End 选择边界，键盘导航移动实际焦点并显露目标行。文字输入提供忽略大小写和重音的前缀查找；重复单字母循环，800ms 后重置。Right 打开子菜单；Left 或 Escape 返回父层；根层 Escape 与 Tab 请求关闭。Enter/Space 激活叶子并关闭整组弹出菜单。自动重复的激活键不会再次执行命令。Select 复用这些行为，从当前选中项开始，键盘不再能选中禁用项。

触摸面没有 hover：点击父行会直接 activate 子菜单；`MenuHierarchyTests.touchSubmenu` 在 390pt 触摸面覆盖该路径。指针停留 180ms 后打开或切换分支，离开待打开行时取消。已经打开的分支在进入子菜单时保持。子菜单在独立 Portal 中绘制，超出右侧时翻到左侧，垂直夹紧到窗口；它不会被父菜单滚动区域裁剪。父行完全滚出视口、禁用、移除或父 Portal 关闭时子层立即清理。Portal 按打开顺序叠放，最深层在最上方。关闭子层恢复对应父行焦点，关闭整组恢复触发按钮。

导航、高亮、滚动、前缀查找和 hover 计时是瞬态会话。子浮层持有共享会话，避免父视图值替换后回调修改已经失效的 `@State` 存储。行的标题、启用、选中和展开状态进入辅助功能树；macOS 静态文字通过 AXValue 暴露。

Popover 与右键菜单的入场组合透明度、4pt 位移和 `0.96 → 1` 缩放，按逻辑对齐选择触发侧锚点。入场期间阴影偏移与模糊保持尺寸，常驻缩放则同步缩放两层阴影；进入中的菜单在当前显示区域接受点击，退出立即禁用输入。减少动画时直接到终态。具体策略与宿主回归见 [生命周期缩放与阴影](animation.md)。

自动化覆盖多级键盘和实际焦点、分隔线/禁用项、100 行滚动、前缀查找、hover 取消、叶子点击、窗口翻转、锚点滚出、禁用和父层销毁。画廊 Menu 页展示四级菜单、内联菜单及 100 条目滚动菜单；ContextMenu 页展示嵌套右键命令。

## 富内容、图标与链接

```swift
.item(MenuItem(id: "docs", title: "Documentation",
               content: MenuItemContent(icon: UIIcons.Action.externalLink,
                                        richTitle: [RichTextRun("Read the "), RichTextRun("guide", traits: .bold)],
                                        detail: "Opens in the browser",
                                        link: "https://example.com/docs")) { open(docs) })
```

- **图标槽**：同一层任一行（含 `MenuSubmenu.icon`）带图标时，整层保留一条小图标列，标题左缘对齐。
- **富内容**：`richTitle` 用 RichText 绘制，只作展示——不进入文本选区、不抢焦点，整行仍是唯一目标；run 上的 link 会被去掉。`title` 始终是辅助功能名称与前缀查找键，所以富内容不影响查找与朗读。`detail` 为第二行说明，读屏作为值。
- **链接语义**：设置 `link` 的行以 link 角色暴露，帮助文本为目标地址，行尾显示外链图标；激活仍执行 action（由调用方打开目标）。
- **子菜单指针意图**：菜单层记录指针轨迹，子菜单层回报自己的面板矩形。指针从当前行斜向移向已打开的子菜单、途经兄弟行时，若当前位置落在“上一采样点 → 子菜单近侧边”的三角区内，切换延迟由 180ms 延长到 450ms，避免斜移时子菜单被换掉；离开三角区仍按短延迟切换。
- `MenuContentTests` 覆盖图标列对齐、富标题不抢焦点、link 角色与激活、前缀查找、三角区判定（含左翻）和子菜单图标。

原生画廊已验证四层 Workspace → Settings → Appearance → Accent color 菜单，文字、选择列、快捷键、分隔线和箭头对齐；选择 Green 后所有浮层关闭且示例反馈更新。标题采用换行布局；尚未提供省略号或根据全部标题自动选择菜单宽度。

## 响应式与输入密度

命令与子菜单行在 touch surface 上至少 44pt，pointer 保留 32pt 下限；长标题与文本缩放仍可使行自然增长。`maxVisibleRows` 的高度预算同样使用触摸下限，避免增大行高后仍按桌面密度裁剪菜单。Portal 继承触发节点的 surface 环境，嵌入表面与子浮层也能保持同一输入密度；输入切换保留已打开分支与行节点。Select 弹层复用同一套约束：宽度不小于触发器并由 Portal 的 12pt viewportMargin 夹紧到窗口内；390pt Gallery `select` 实测触发器 286pt、弹层 346pt（x=32，右边界 378），长选项换行后行高自然增长。

`RowDensityTests.menuRows` 验证来源表面与 PortalHost 环境不同的场景、禁用行、子菜单、视口高度、行底部点击展开、键盘关闭和 pointer 密度恢复；`scaledRows` 覆盖 100%/200% 文本缩放与 light/dark。手机系统触摸派发与窄宽视觉取样仍需真机验收。
