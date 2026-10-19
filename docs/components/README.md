| List / SectionedList / ReorderableList |# GuavaUI 组件设计参考

本目录收录组件设计契约。索引标记仅代表文档存在，不表示组件已达到完整或生产成熟状态。

跨设备抽象与组件交付要求见 [组件标准](standard.md)，空间不足阶梯、手机/平板重排、触摸/键盘/辅助功能与动效验收见[跨平台控件规范](adaptive-spec.md)，缺失组件与既有组件功能缺口见[组件覆盖与缺失清单](gaps.md)，实际示例见 `GuavaUI/Examples/Sources/GalleryContent/`。每篇覆盖：

1. **Anatomy** —— ASCII 框图 + 槽位命名
2. **Sizing** —— 高度 / padding / 最小命中区
3. **Tokens** —— 消费的 ColorScheme / Typography / Spacing / Radius / Motion 槽位
4. **States** —— rest / hover / press / focus / selected / disabled 矩阵
5. **Behavior** —— 键盘、指针、IME、辅助功能默认值
6. **Authoring rules** —— 调用方应做 / 不应做的事
7. **References** —— Apple HIG / SwiftUI 为主，Fluent / Radix 仅作交互对照

底层 token 体系见 [standard.md](standard.md)。

## 索引

| 组件 | 状态 | 文件 |
| ---- | ---- | ---- |
| 跨平台控件规范（手机 / 平板 / 桌面） | 空间阶梯、重排、动效与验收 | [adaptive-spec.md](adaptive-spec.md) |
| 组件覆盖与缺失清单 | 缺失组件规范、功能缺口、优先级 | [gaps.md](gaps.md) |
| Button | 文档已写 | [button.md](button.md) |
| IconButton | 文档已写 | [iconbutton.md](iconbutton.md) |
| Toolbar | 优先级溢出、保留节点与菜单焦点 | [toolbar.md](toolbar.md) |
| Form / PropertyGrid | 容器标签重排、值槽与状态保留 | [form.md](form.md) |
| Toggle | 文档已写 | [toggle.md](toggle.md) |
| Checkbox | 文档已写 | [checkbox.md](checkbox.md) |
| TextField | 文档已写 | [textfield.md](textfield.md) |
| ColorField | RGBA 通道、hex 与自适应弹层宽度 | [colorfield.md](colorfield.md) |
| SearchField | 搜索输入、联想与键盘选择 | [searchfield.md](searchfield.md) |
| Combobox | 可搜索单选、本地过滤与远程结果契约 | [combobox.md](combobox.md) |
| Text / Typography / Color glyphs | 实现与验证边界 | [typography.md](typography.md) |
| Viewport Traits | width/height class、orientation reader 与 600/1000 阈值 | [viewport-traits.md](viewport-traits.md) |
| Accessibility | 语义树、describedBy、scrollArea 与 comboBox | [accessibility.md](accessibility.md) |
| Scrollbar | 可聚焦 thumb、拖动/键盘/辅助功能与 ScrollView offset 绑定 | [scrollbar.md](scrollbar.md) |
| Chart | line/area/bar（分组、堆叠）/scatter/pie·donut、可切换图例与数据点选择 | [chart.md](chart.md) |
| NumberField | 文档已写 | [numberfield.md](numberfield.md) |
| Vec3Field | 文档已写 | [vec3field.md](vec3field.md) |
| AssetRefField / AssetDropTarget | 文档已写 | [assetref.md](assetref.md) |
| Modal / ContextMenu / TransitionView | 文档已写 | [interaction.md](interaction.md) |
| Dialog / AlertDialog | 自适应宽度、操作区、字号与确认状态 | [dialog.md](dialog.md) |
| Accordion / DisclosureGroup | 单行完整名称、展开语义、键盘与过渡生命周期 | [disclosure.md](disclosure.md) |
| 动画系统 | 属性 / 弹簧 / 轨道 / 相位 / 循环 / 共享几何 / 数值 / 生命周期 | [animation.md](animation.md) |
| Sheet | 实现与验证边界 | [sheet.md](sheet.md) |
| BottomSheet | detent、拖拽与宽屏退化 | [bottom-sheet.md](bottom-sheet.md) |
| Tooltip | 实现与验证边界 | [tooltip.md](tooltip.md) |
| Popover | 共享箭头卡片、12 向定位与显式避让策略 | [popover.md](popover.md) |
| Popconfirm | 复用 Popover 的锚定确认与显式确认按钮 | [popconfirm.md](popconfirm.md) |
| ActionSheet | 底部操作抽屉、拖拽/外部关闭与调用方本地化关闭名称 | [action-sheet.md](action-sheet.md) |
| Badge / Tag / KeyCap / FieldLabel | 长文本换行、移除、快捷键口述与输入关联 | [labels.md](labels.md) |
| Alert | iOS 中性内联状态卡、tone 图标与 variant | [alert.md](alert.md) |
| Toast / Notification | 队列、操作按钮、位置与安全区 | [toast.md](toast.md) |
| Menu / ContextMenu / Select | 实现与验证边界 | [menu.md](menu.md) |
| MenuButton | 按钮触发的菜单与 expanded 语义 | [menubutton.md](menubutton.md) |
| SplitButton | 主/备动作与双区命中 | [splitbutton.md](splitbutton.md) |
| CommandPalette | 命令搜索、键盘选择、结果虚拟化与自定义 footer | [commandpalette.md](commandpalette.md) |
| JsonField | 文档已写 | [jsonfield.md](jsonfield.md) |
| Slider | 文档已写 | [slider.md](slider.md) |
| RangeSlider | 双 thumb、active thumb 与 minSpan | [rangeslider.md](rangeslider.md) |
| Rating | 实现与验证边界 | [rating.md](rating.md) |
| Calendar / DatePicker | 月份键盘导航、日期限制与焦点 | [calendar.md](calendar.md) |
| DateRangePicker | 真实日历、两击区间与高亮 | [daterangepicker.md](daterangepicker.md) |
| TimePicker | 内联时/分/秒/AM-PM 滚轮与范围夹紧 | [timepicker.md](timepicker.md) |
| WheelPicker | 五行滚轮、拖拽/滚轮/键盘与 disabled 跳过 | [wheelpicker.md](wheelpicker.md) |
| List / SectionedList / ReorderableList | 单选、多选、区段/sticky、重排、虚拟化与行样式 | [list.md](list.md) |
| SwipeList | 触摸滑动操作、Actions 按钮、上下文菜单与键盘选择 | [swipelist.md](swipelist.md) |
| RefreshableList | 下拉刷新阈值、顶部 inset、Cmd+R 与 reducedMotion | [refresh.md](refresh.md) |
| Drag & Drop | 类型化 payload、Portal 预览、目标高亮与取消 | [drag-and-drop.md](drag-and-drop.md) |
| DataTable / DataTableModel | 实现与验证边界 | [data-table.md](data-table.md) |
| Avatar / AvatarGroup | 实现与验证边界 | [avatar.md](avatar.md) |
| Image / AsyncImage | 实现与验证边界 | [image.md](image.md) |
| WebView | 宿主注入的原生网页视图、裁剪与生命周期；macOS WKWebView | [webview.md](webview.md) |
| Tree / TreeRow | 文档已写 | [tree.md](tree.md) |
| Panel | 文档已写 | [panel.md](panel.md) |
| SplitView | 比例/最小尺寸、compact 单面板与交互 | [splitview.md](splitview.md) |
| Workspace（Docking） | 布局模型/拖拽/内部拆分与缺口 | [workspace.md](workspace.md) |
| ScrollView | 文档已写 | [scrollview.md](scrollview.md) |
| Tab | 文档已写 | [tab.md](tab.md) |
| AppBar / NavigationBar | 自适应标题、返回、主操作与更多菜单 | [appbar.md](appbar.md) |
| Sidebar / AdaptiveSidebar | 实现与验证边界 | [sidebar.md](sidebar.md) |
| NavigationDrawer | 模态导航、窗口拟合、关闭策略与手势 | [navigation-drawer.md](navigation-drawer.md) |
| NavigationRail | 72/56pt 导航轨、完整名称与呈现保留 | [navigation-rail.md](navigation-rail.md) |
| NavigationStack | 路径栈、页面保留、push/pop 过渡与深链 | [navigationstack.md](navigationstack.md) |
| Box / Row / Column | 文档已写 | [layout.md](layout.md) |
| Masonry | 1–2 列平衡瀑布流、最短列放置与 RTL | [masonry.md](masonry.md) |
| ViewThatFits | 阈值、intrinsic 宽高拟合与分支状态保留 | [layout.md](layout.md#自定义测量与放置2026-10-12) |
| ZStack / Overlay | 层叠、对齐、命中顺序与溢出边界 | [zstack.md](zstack.md) |

## 通用约定

- **所有可点击组件**在触摸输入下的命中区至少 44pt；桌面可使用显式工具栏密度，键盘焦点用 2px focusRing。
- **所有文本输入**默认垂直居中、左侧 inset = `theme.spacing.sm`、`clipsToBounds = true`。
- **状态层** (hover/press/selected/focused) 走 `Color.composited(over:)`，不要用 `.lighter()` / `.darker()`。
- **chrome 颜色** 通过 `node.theme.colors.*` 在 `_updateNode` 内每次重算，不要缓存到 attachments。
- **布局容器** (Box/Row/Column) `isHitTestable = false`，不参与命中测试。
