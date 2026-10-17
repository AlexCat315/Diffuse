# 组件覆盖与缺失清单

本文与[跨平台控件规范](adaptive-spec.md)互补：规范管**已有**容器的空间不足阶梯、控件重排与输入/动效契约；本文管**还缺什么**——完整缺失的组件、既有组件的功能缺口，以及优先级与验收口径。

- 数据来源：`GuavaUI/Sources/GuavaUICompose/Primitives`、Gallery 75 页（`GalleryCatalog.swift`）、各组件文档与逐项代码复核。
- 范围：脱离 Guava 编辑器语境仍成立的通用 UI 能力。场景层级、Inspector 字段面板、Material Graph、媒体时间线等领域组件留在应用层，不进本清单。
- 状态：`[未实现]` 完全缺失；`[部分]` 已有基础实现或可用组合替代；`[已实现]` 仅作对照。优先级 P0（手机/平板可用性阻塞）> P1（常用能力）> P2（长尾/体验）> P3（按需）。
- 自适应工作统一由规范第 5 节跟踪待办和完成记录（Toolbar、Sidebar、Form、数据列、Tab、截断、缩放、触摸行高、滚动、浮层、焦点与 Gallery 等）；本文仅保留交叉引用，避免双份维护。

## 1. 覆盖总览

| 家族 | 已有 | 缺失 |
| --- | --- | --- |
| 布局与容器 | Box/Row/Column/Spacer/Divider、ZStack/Overlay、ScrollView/BoundedScrollView、Panel、SplitView（compact 单面板）、Grid（含命名字段列显隐）/LazyGrid、SafeArea、ViewThatFits/LayoutThatFits/ContainerSizeReader/WidthClassReader、VirtualStack/VariableVirtualStack、Workspace、Form/PropertyGrid | Masonry P2、Grid/LazyGrid span P2、程序滚动无时长动画（scrollview.md） |
| 命令与选择 | Button/IconButton、ButtonGroup、SplitButton（主/备）、MenuButton、Toggle/Checkbox（含 mixed）/RadioGroup、Slider、RangeSlider（active thumb）、Rating、Stepper（流程）、ToolbarToggle、Toolbar 命令优先级与溢出 | SplitButton 单一 Tab/共享 chrome P2、RangeSlider 独立 Tab/双 slider 语义 P2、FAB P2、布尔控件 label 槽 P2 |
| 文本与数值输入 | TextField/TextArea/CodeEditor、SearchField、NumberField（带步进）、Vec3Field、Select/Combobox、ColorField、AssetRefField、JsonField、Label/Link/KeyCap | OTP/PIN P3、masked input P3、locale 小数 P2、数值拖拽 scrub P2 |
| 日期时间 | Calendar、DatePicker、DateRangePicker、TimeField（文本 HH:MM） | TimePicker/滚轮 P2、周/月/年选择 P2、12/24 小时与时区 P2、区间预设 P2 |
| 集合与数据 | List（单选/虚拟化/键盘）、MultiSelectList（Shift/Cmd/键盘多选）、SectionedList（区段/sticky 标题）、ReorderableList（拖拽重排）、SwipeList（触摸滑动/操作按钮/上下文菜单）、Tree（多选/搜索/DnD/键盘/同步延迟子节点）、Table、DataTable（200K/冻结列/编辑）、VirtualList/Stack、Chart（line/bar/sparkline）、Timeline、Tag | 列表下拉刷新 P1、TreeTable P2、DataTable 高级能力 P2、Chart 更多图形 P2 |
| 导航与外壳 | TabView（adaptive/closable、溢出菜单与标题省略）、Sidebar / AdaptiveSidebar、NavigationDrawer、NavigationRail、Breadcrumb、Pagination、Accordion/DisclosureGroup、Toolbar、AppBar、StatusBar、Workspace（compact）、Carousel、CommandPalette | NavigationStack 核心已实现（平台返回/标题焦点待补）P1、BottomNavigationBar P3（TabView 底部栏已可覆盖） |
| 浮层 | Modal/Dialog/AlertDialog、Sheet（四边）、BottomSheet（detent/拖拽/自适应）、Menu/ContextMenu、Popover/HoverCard/Tooltip、Toast/Notification（队列/时长/暂停/替换/操作/位置） | ActionSheet/Popconfirm P2、菜单富内容 P2 |
| 反馈与状态 | Alert、Badge、Progress/ProgressCircle、Spinner、Skeleton、EmptyState、Toast、StatusTone | 基本完整；Banner 由 Alert 覆盖 |
| 展示与媒体 | Text/Typography、Icon、Image/AsyncImage/Thumbnail、Avatar/AvatarGroup、Badge/Tag/KeyCap/Label、ViewportHost、ScriptCanvasView | RichText/Markdown P2、视频播放组件（应用层按需）、GIF/WebP、EXIF/渐进、缓存淘汰 P2 |
| 拖放与交互 | AssetDropTarget、Tree DnD、Workspace 拖拽、PointerCapture | 通用 drag & drop 协议（任意 payload/列表重排）P1 |

## 2. 缺失组件规范

写法与规范第 3 节一致：外观 → 手机 → 平板/桌面 → 交互与验收。标注为当前状态。

### 2.1 AppBar / NavigationBar（P0）

- 用途：手机与平板的顶部应用栏：返回、标题、副标题、主操作、溢出。
- 外观：`AppBar` 已实现，48pt 基线随内容增长，触摸目标 ≥44；标题 `bodyStrong` 单行省略并保留全文；ghost 返回；最多平铺 3 个操作，其余复用 Toolbar overflow。`[已实现]`
- 手机：实际容器 <600pt 时保留返回、标题、最多 1 个主操作和 overflow；标题与文字主操作省略且保留全文 tooltip / 语义；顶部安全区由宿主消费一次。`[已实现]`
- 平板/桌面：标题前导、可选副标题、按优先级平铺最多 3 个操作；hover / press / 键盘焦点反馈与 Toolbar 一致。`[已实现]`
- 交互与验收：Tab 返回 → 操作 → overflow；heading / 返回全文名称 / 展开态；菜单行 ≥44，状态和禁用来自同一 MenuItem。`AppBarTests` 覆盖 390/720/1280 × 字号/输入/主题、安全区、RTL、键盘、焦点及真实 AI 查询；Gallery 新增可交互页与三预览。平台 heading 边界和设备取样见 [AppBar](appbar.md)。`[已实现]`

### 2.2 NavigationDrawer（P0，Sidebar 的抽屉形态）

- 用途：compact/medium 宽度下 Sidebar 的覆盖层形态；[NavigationDrawer](navigation-drawer.md) 已实现，[AdaptiveSidebar](sidebar.md#自适应壳层) 已按宽度统一三种形态。
- 外观：按实际窗口拟合宽度 `min(320, 窗口 − 56)`；遮罩 `stateLayerSelected` 强度；顶部标题与关闭；行高 ≥ 44。`[已实现]`
- 手机：按钮打开；焦点进入并循环、Escape 关闭、关闭后还原；选中项显露；左滑关闭并取消子按钮按下。可选边缘唤出由 AdaptiveSidebar 提供（仅紧凑触摸容器前导 24pt 起始的右滑）。`[已实现]`（独立按钮入口与壳层手势入口）
- 平板/桌面：可显式打开 Drawer，常驻形态使用 Sidebar，轨道使用 NavigationRail；AdaptiveSidebar 按容器宽度自动切换。`[已实现]`
- 交互与验收：展开与选择由应用 session binding 持有，窗口变化保留；辅助功能为带完整名称的 dialog。`NavigationDrawerTests` 覆盖宽度/字号/主题/输入、展开/关闭/焦点/手势/生命周期和 AI 查询；Gallery `DrawerTests` 覆盖独立页与 Sidebar 共享选择。

### 2.3 NavigationRail（P1）

- 用途：medium 宽度的图标导航轨（桌面可显式启用）；[NavigationRail](navigation-rail.md) 复用 Sidebar 数据和目的地节点。
- 外观：宽 72（图标 + 换行标签）或 56（纯图标）；2pt accent 指示条；顶部/底部开放槽。图标受轨道宽度约束，徽标用圆点并保留完整值。`[已实现]`
- 手机/平板：壳层应在 compact 使用抽屉、medium 使用 rail、expanded 使用 Sidebar；AdaptiveSidebar 已统一自动切换，并保留同一目的地、页面、焦点和会话。`[已实现]`
- 交互与验收：Up/Down、Home/End 循环并跳过禁用项，单一 Tab 停靠；完整名称/选中态/徽标值、tooltip、目标 ≥44pt；`SidebarPresentation` 切换保留节点/焦点/槽位状态。`NavigationRailTests` 覆盖输入矩阵、模式切换、滚动、AI 发现；Gallery `RailTests` 验证实际示例。参考：Flutter `NavigationRail`；SwiftUI `NavigationSplitView` 折叠态。

### 2.4 NavigationStack / 路由（P1）

- 用途：页面栈、返回、深链与状态保留；当前应用自行管理根视图切换。
- 外观：`NavigationStack` 以 caller-owned `[Route]` 为栈，root 与路径页在栈内保持挂载；push 时新页从 trailing 滑入并淡入、旧页向 leading 滑出，pop 时新顶页以反向 move+opacity 显露（被移除页立即卸载）；reducedMotion 由 `AnimatedVisibility` 直接吸附。`[部分]`
- 行为：栈与路径属 session；旋转与宽度类切换保留栈与页面内状态（页在栈内保持挂载）；非空初始 path 在首帧恢复深链。平台返回键/边缘手势由宿主删除最后一个 route；组件不消费 Escape。`[部分]`
- 交互与验收：返回动画期间不重复入栈由持有 path 的调用方/宿主去重；辅助功能焦点落在新页标题尚未内置，页面应自行设置焦点。参考：SwiftUI `NavigationStack`；Flutter `Navigator`。`[部分]`，API 与边界见 [NavigationStack](navigationstack.md)。

### 2.5 SplitButton / MenuButton（P1）

- **MenuButton**：常规按钮触发器 + Popover + Menu；保留 hover/press/focus/disabled、expanded 语义、Escape/外部点击关闭与菜单键盘导航。`[已实现]`，见 [MenuButton](menubutton.md)。
- **SplitButton**：主操作 + 下拉备选；左侧主按钮 + 右侧 MenuButton 箭头；两区各自命中 ≥ 44（触摸）且禁用同步；菜单复用 Menu 契约。`[部分]`，见 [SplitButton](splitbutton.md)
- SplitButton 手机/桌面：主按钮填充剩余宽度，箭头自然宽度；下拉从锚点下方展开，底部不足上翻。`[已实现]`
- SplitButton 交互与验收：主/箭头各自独立命中与键盘激活，菜单复用 Menu；当前是两个 Tab 停靠、两个相邻 secondary 按钮，尚未实现单一 Tab + 左右分区的共享 chrome 模型。`SplitButtonTests` 覆盖主/备动作与禁用；Gallery `splitButton` 页提供真实操作。参考：Fluent SplitButton；Material `SplitButton`。

### 2.6 RangeSlider（P1）

- 用途：区间选择（曝光区间、帧范围、价格/尺寸过滤）。
- 实现：双 thumb 共用 SliderStyle 轨道；指针按距离选择 active thumb；`minimumSpan` 夹紧；a11y value 为 `"lower – upper"`，增减作用于 active thumb。`[部分]`
- 手机/平板：触摸命中由 `applyTouchControlExtent` 提升到 44；指针 hover/focus 沿用 SliderStyle；thumb 近距时仍各自命中，不合并。
- 交互与验收：拖动、方向键移动 active thumb、Home/End；Tab 仍走系统焦点遍历，两个 thumb 的独立 Tab 停靠与两个独立 slider 语义尚未实现。`RangeSliderTests` 覆盖指针、minSpan 与键盘；Gallery `rangeSlider` 页提供真实拖动。细节见 [RangeSlider](rangeslider.md)。

### 2.7 SearchField（P1，已实现）

- 用途：统一的搜索输入（放大镜、清除、空态、结果联想）。
- 实现：复用 TextField chrome + `decoration.leadingIcon` 前导图标 + clear action；联想列表内联在字段下方，按输入过滤，支持方向键、Return、Escape。`[已实现]`
- 手机/平板：字段沿用 TextField 的 44pt 触摸命中；联想行由 Button 保证触摸命中；窄宽随父容器收缩。全局快捷键（Cmd/Ctrl+F）由应用绑定，组件不注册全局键盘。
- 交互与验收：Escape 清空或取消、Enter 提交、方向键移动高亮；辅助功能 role=textField + label"Search"；`SearchFieldTests` 覆盖清空、候选选择与提交，Gallery `searchField` 页提供真实输入/联想。细节见 [SearchField](searchfield.md)。

### 2.8 DateRangePicker（P1）

- 用途：日期区间（起点/终点）选择。
- 实现：复用 Calendar 月视图/导航/可用日期；起点/终点 accent 填充、区间段 `stateLayerSelected`；触发器显示两端日期与 clear。`[已实现]`
- 手机/平板：日期格沿用 Calendar 的 44pt 触摸下限；单月一屏，宽屏可配 `numberOfMonths=2`；弹层宽度由 Popover 夹紧。
- 交互与验收：第一次点击设起点、第二次设终点，反向点击自动交换；Escape/外部点击关闭；键盘方向键、Home/End、PageUp/Down 复用 Calendar；a11y 触发器读完整区间。`DateRangePickerTests` 覆盖两击与交换；Gallery `dateRangePicker` 页提供真实日历与高亮。区间预设/最大长度仍由应用层负责。细节见 [DateRangePicker](daterangepicker.md)。

### 2.9 列表能力包（P1）

按同一行契约（触摸 ≥ 44、单行截断、完整值可达）补齐：

- **多选与区间选择**：Checkbox 列或 Cmd/Shift 点选；Shift 区间以锚点延伸；辅助功能 selected 态。`MultiSelectList` 已实现 Cmd/Ctrl 切换、Shift 区间、Shift+Arrow、Cmd/Ctrl+A；Checkbox 列仍由调用方组合。`[已实现]`，见 [List](list.md#multiselectlist)。
- **区段（sections）**：区段头/尾、可选 sticky；DataTable 之外的表状列表先支持平面区段。`SectionedList` 已实现平面 header/footer、sticky 固定标题（下一标题上推）与跨区段键盘选择；`stickyHeaders` 默认关闭，固定副本不进入焦点/命中/语义。`[已实现]`，见 [List](list.md#sectionedlist)。
- **重排（reorder）**：`ReorderableList` 已实现 44pt 拖拽把手、2pt 放置线、Escape 取消、Up/Down 与辅助功能 increment/decrement；行身份与焦点跟随原行。当前为非虚拟列表，视口边缘自动滚动未实现。`[已实现]`
- **滑动操作（swipe actions）**：`SwipeList` 仅在触摸面启用左滑，露出最多两个 74pt 宽、行高 ≥44 的 trailing 操作；指针、键盘与读屏通过行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口，滑动不是唯一路径。全量挂载。`[已实现]`
- **下拉刷新**：阈值与阻尼、指示器、完成后回弹；reducedMotion 时指示器静止；键盘/命令提供等效刷新入口。`[未实现]`
- 验收：以上各能力分别提供触摸/键盘/辅助功能断言与 390/720 取样；重排与滑动的状态属 session。参考：SwiftUI `List(selection:)`/`onMove`/`swipeActions`/`refreshable`；Flutter `RefreshIndicator`/`ReorderableListView`/`Dismissible`。

### 2.10 ZStack / Overlay（P1，已实现）

- 用途：公共层叠容器（徽标叠加、加载遮罩、内容层叠）；跨裁剪浮层仍用 Portal。
- 实现：`ZStack(alignment:)` / `ZStackLayout` 按声明顺序层叠，后声明的在上，测量到最大子视图且不自动裁剪；`View.overlay(alignment:)` / `OverlayLayout` 把内容附在单个 base 上，base 决定尺寸，overlay 不参与父级测量。
- 交互与验收：指针按后声明优先命中；条件分支卸载后不绘制/不接输入/不暴露语义；RTL 下 leading/trailing 按逻辑边解析。`ZStackTests` / `OverlayTests` 覆盖测量、对齐、RTL、重叠命中与 overlay 命中；Gallery `zStack` 页提供分层卡片、角标和显示/隐藏前层开关。细节见 [ZStack](zstack.md)。

### 2.11 BottomSheet 增强（P0）

- 用途：手机底部抽屉；复用 `Modal` 的焦点、Escape 和 backdrop，新增 detent 与拖拽。
- 实现：`BottomSheet` 提供全宽 44pt 拖拽柄、2–3 档高度、向上展开/向下收缩或关闭；compact/medium 贴底，expanded 退化为居中面板。`[已实现]`
- 交互与验收：下拉超过位移/速度阈值关闭，第一档之上先退档；拖拽中内容不接输入；关闭后焦点还原；释放无惯性尾段，reducedMotion 安全。`BottomSheetTests` 覆盖关闭、展开与宽屏退化；Gallery `bottomSheet` 页提供真实拖拽。细节见 [BottomSheet](bottom-sheet.md)。

### 2.12 其他缺失（P2/P3，压缩规范）

| 组件 | 级别 | 外观 | 手机/平板 | 交互与验收 | 参考 |
| --- | --- | --- | --- | --- | --- |
| TreeTable | P2 | 树缩进在首列 + 可调列 | 触摸行 ≥ 44；窄宽隐藏低优先列 | 键盘树导航 + 列头排序；展开态 a11y | SwiftUI `Table` + OutlineGroup；Fluent TreeGrid |
| RichText / Markdown | P2 | 行内样式、链接、代码块、列表 | 正文换行、代码块横向滚动 | 选择/复制、链接辅助功能与键盘激活 | SwiftUI `Text(markdown:)`；Flutter `flutter_markdown` |
| TimePicker / WheelPicker | P2 | 滚轮或列表选择，选中行 accent | 触摸行 ≥ 44、吸附；平板可两列（时/分） | 上下键、Page、Home/End；a11y 可增减 | Flutter `CupertinoPicker`；SwiftUI `Picker(.wheel)` |
| Masonry | P2 | 多列瀑布流、列平衡 | 1–2 列；窄宽单列 | 列数由宽度决定；滚动窗口化可选 | Flutter `MasonryGridView`（三方）；CSS columns |
| FAB | P2 | 圆形 56，主操作 | 仅触摸面出现/或桌面显式启用；避开底部安全区 | 滚动隐藏可选；a11y 名称必填 | Material FAB |
| OTP / PIN | P3 | N 个方格、自动前进 | 数字键盘、粘贴分发 | Backspace 退格、粘贴全填、a11y 整值读写 | 移动生态惯例 |
| ActionSheet / Popconfirm | P2 | 由 AlertDialog + Sheet + Popover 组合 | 窄宽用底部弹出 | 复用 Modal 焦点/关闭契约 | SwiftUI `confirmationDialog`；Flutter `showModalBottomSheet` |
| Menu 富内容 | P2 | 图标槽、任意行内容、链接语义 | 触摸行 ≥ 44 | 与现有键盘导航共用；富内容不破坏前缀查找 | Radix DropdownMenu；Fluent Menu |

Toast 操作与位置已补齐：最多两个内联操作、真实按钮键盘可达、`ToastPosition` 四角定位与 `.automatic`（compact 底部，medium/expanded 右上），并计入宿主安全区。细节见 [Toast](toast.md)；仅进出动画仍为 P2。

## 3. 既有组件功能缺口（不含规范第 5 节条目）

| 组件 | 缺口 | 优先级 |
| --- | --- | --- |
| Toggle / Checkbox | label 槽位；Checkbox 的 `CheckboxState.off/on/mixed` 已实现，Toggle 仍采用 Bool 开关语义 | P2 |
| Slider | 垂直方向、刻度标记、Page 键、区间（见 2.6） | P2 |
| Rating | RTL、自定义图形/半星以上精度 | P2 |
| NumberField / Vec3Field | locale 小数分隔、拖拽 scrub、单轴重置与向量复制/粘贴 | P2 |
| Select / Combobox | 远程/异步结果（按需）、触发器宽度联动 | P2 |
| DatePicker / TimeField | 12/24 小时与时区、滚轮（见 2.12）；DatePicker 键盘月份跳转已有 | P2 |
| Calendar | 区间选择（见 2.8）；Home/End/PageUp/Down 已实现，见 [日历导航](calendar.md) | P1 |
| List | 多选、平面区段、sticky 区段、重排与 SwipeList 已实现；下拉刷新仍缺（见 2.9） | P1（多选/区段/sticky/重排/swipe 已完成） |
| Tree | 同步延迟子节点、全部展开/折叠快捷、多选、搜索、禁用与触摸行高已完成；异步请求与加载状态由调用方数据层管理，见 [tree.md](tree.md) | 已完成 |
| Table / DataTable | 列重排、分组表头、分页/远端加载、单元格/矩形区间、可变行高、CSV 导出、表级撤销；列优先级、显隐菜单与文本缩放行高已实现，见 [数据表](data-table.md) | P2 |
| Chart | pie/area/scatter/stacked、图例交互、数据点选择 | P2 |
| Timeline | 分组/折叠、缩放 | P2 |
| Menu / ContextMenu | 富内容（见 2.12）、图标槽、链接语义；触摸展开验收见规范 5-10，触摸行高与水平翻转已有 | P2 |
| CommandPalette | 结果列表已虚拟化（视口 + overscan）；compact 几何与触摸行高已完成；无最近使用记录与自定义页脚；模糊匹配与分组已有 | P1/P2（虚拟化与移动端几何已完成；最近使用待补） |
| Sheet / Modal | 拖拽关闭与自适应（见 2.11）；其余契约完整 | P1 |
| Sidebar | 可调整宽度、嵌套子菜单、项级操作/上下文菜单 | P1 |
| Toolbar | 垂直工具栏；命令优先级、更多菜单、图标名称与焦点交接已实现，见 [toolbar.md](toolbar.md) | P2 |
| Workspace | N 面板联动、折叠阈值/吸附、pin 专属视觉、浮动为应用内层、文档解码校验与可版本化格式、a11y/RTL、chrome 硬编码清理（见 [workspace.md](workspace.md)） | P2 |
| ScrollView | 触摸拖动/惯性、键盘滚动、滚动条 a11y、横向 gutter、边界渐变、锚定滚动、带时长程序滚动、残余增量交接（规范 5-9 + [scrollview.md](scrollview.md)） | P1（触摸/键盘已完成；滚动条 a11y、锚定与带时长程序滚动待补） |
| Form / PropertyGrid | 自适应标签、共享值槽阈值、列数重排、标签关联与 Form 校验摘要已实现，见 [form.md](form.md)；PropertyGrid 跨字段业务校验由应用管理 | 已实现 |
| Carousel | 自动轮播、复杂指示器（按需）；滑动/键盘已有 | P2 |
| StatusBar / Panel | 状态格与标题截断策略（规范 1.1 已标部分） | P2 |
| CodeEditor / TextField | snippet tab-stop、超长单行分段布局（[textfield.md](textfield.md) 边界） | P2 |
| Image / AsyncImage | 缓存淘汰、在途合并、GIF/WebP 动画、EXIF、渐进解码（[image.md](image.md) 边界） | P2 |
| Avatar | 状态角标、可交互成员弹层（[avatar.md](avatar.md) 边界） | P2 |
| Icon / Typography | 彩色字形仅 macOS；RTL 双向段落完整语义 | P2 |
| Link | 访问态、外链确认（按需） | P3 |
| 拖放 | 通用 payload 协议与列表重排（见 2.9/2.10） | P1 |
| Toast / Notification | 进出动画；操作按钮与位置配置已完成，见 [Toast](toast.md) | P2 |

## 4. 优先级与建议顺序

**P0（手机/平板可用性阻塞）**：已清空；BottomSheet 拖拽与自适应已实现，见 [BottomSheet](bottom-sheet.md)。Grid / DataTable / Table 列优先级、显隐菜单与 minimum 横向滚动兜底、AppBar、Toolbar 命令溢出、Form 标签重排、SplitView 单面板、NavigationDrawer 覆盖层与 AdaptiveSidebar 统一壳层已实现，验收与边界见 [layout.md](layout.md#grid-字段列)、[data-table.md](data-table.md)、[appbar.md](appbar.md)、[toolbar.md](toolbar.md)、[form.md](form.md)、[splitview.md](splitview.md)、[navigation-drawer.md](navigation-drawer.md)。

**P1（常用能力）**：列表下拉刷新、通用拖放。NavigationRail、AdaptiveSidebar 统一壳层、Toast 操作/位置、ZStack、SearchField、MenuButton、RangeSlider（active thumb）、SplitButton（主/备动作）、DateRangePicker、ScrollView 输入（触摸拖动/键盘）、CommandPalette 虚拟化与 compact 几何、列表多选、平面区段、sticky 区段、ReorderableList 重排、SwipeList 滑动操作与 NavigationStack 核心已补齐，边界及验收见 [Sidebar](sidebar.md#自适应壳层)、[Toast](toast.md)、[ZStack](zstack.md)、[SearchField](searchfield.md)、[MenuButton](menubutton.md)、[RangeSlider](rangeslider.md)、[SplitButton](splitbutton.md)、[DateRangePicker](daterangepicker.md)、[ScrollView](scrollview.md)、[CommandPalette](commandpalette.md) 、[List 多选](list.md#multiselectlist) 、[SectionedList](list.md#sectionedlist) 与 [SwipeList](swipelist.md)。

**P2（长尾/体验）**：TimePicker/滚轮、TreeTable、RichText/Markdown、Masonry、FAB、Chart 扩展、DataTable 高级能力、CodeEditor snippets、图片缓存与解码能力、Workspace 深化。

**P3（按需）**：OTP/PIN、masked input、外链确认等。

排序依据：先补"壳层与触摸集合"（手机整屏可用性），再补"数据密度与常用输入"，最后补长尾与性能深化。领域组件（场景/资产/材质/时间线业务）不进入 GuavaUI。

## 5. 验收门槛

新组件与功能补齐共用[规范第 4.3 节](adaptive-spec.md#43-自动化)的门槛，另加两条：

1. 每个新组件必须给出 390（触摸）/ 720（混合）/ 1280（指针）三档验收记录，并进入 `GalleryCatalog` 与 `AdaptiveControlExamples.supports`（或提供等价预览）；
2. 列表类能力必须包含触摸（滑动/长按/拖动）与键盘/辅助功能等效入口的成对断言；不允许存在只能触摸完成的动作。

## 6. 参考对照（缺失组件）

| 缺失组件 | SwiftUI | Flutter / Material 3 |
| --- | --- | --- |
| AppBar / NavigationBar | `NavigationStack` + `toolbar` | `AppBar`、`SliverAppBar` |
| NavigationDrawer | `NavigationSplitView`、`sidebar` | `NavigationDrawer`、`Drawer` |
| NavigationRail | `NavigationSplitView` 折叠态 | `NavigationRail` |
| NavigationStack / 路由 | `NavigationStack`、`NavigationPath` | `Navigator`、`Router` API |
| SplitButton | `Menu` + `Button` 组合（已实现主/备动作） | `SplitButton`、`MenuAnchor` |
| MenuButton | `Menu`（已实现） | `MenuAnchor` / `PopupMenuButton` |
| RangeSlider | 无内置（双 Slider 组合；已实现 active thumb） | `RangeSlider` |
| SearchField | `.searchable`（已实现） | `SearchBar`、`SearchAnchor` |
| DateRangePicker | 无内置（双 DatePicker 组合；已实现真实日历） | `showDateRangePicker` |
| WheelPicker | `Picker` + `.pickerStyle(.wheel)` | `CupertinoPicker`、`ListWheelScrollView` |
| 多选/区段/重排/swipe（已实现）/下拉刷新 | `List(selection:)`、`Section`、`onMove`、`swipeActions`、`refreshable` | `CheckboxListTile`、`ReorderableListView`、`Dismissible`、`RefreshIndicator` |
| ZStack | `ZStack`（已实现） | `Stack` |
| BottomSheet | `.sheet` + `presentationDetents`（已实现） | `showModalBottomSheet` |
| RichText / Markdown | `Text(markdown:)`、`AttributedString` | `flutter_markdown`（三方） |
| TreeTable | `Table` + `OutlineGroup` 组合 | `TreeView` 套件（三方） |
| Toast 操作 | 无内置（已实现） | `SnackBar` + `SnackBarAction` |
