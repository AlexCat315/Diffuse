# 组件覆盖与缺失清单

本文与[跨平台控件规范](adaptive-spec.md)互补：规范管**已有**容器的空间不足阶梯、控件重排与输入/动效契约；本文管**还缺什么**——完整缺失的组件、既有组件的功能缺口，以及优先级与验收口径。

- 数据来源：`GuavaUI/Sources/GuavaUICompose/Primitives`、Gallery 72 页（`GalleryCatalog.swift`）、各组件文档与逐项代码复核。
- 范围：脱离 Guava 编辑器语境仍成立的通用 UI 能力。场景层级、Inspector 字段面板、Material Graph、媒体时间线等领域组件留在应用层，不进本清单。
- 状态：`[未实现]` 完全缺失；`[部分]` 已有基础实现或可用组合替代；`[已实现]` 仅作对照。优先级 P0（手机/平板可用性阻塞）> P1（常用能力）> P2（长尾/体验）> P3（按需）。
- 已列入规范第 5 节的缺口（Toolbar 溢出、Sidebar 收敛、Form 标签、DataTable 列优先级、TabView 溢出菜单、截断、文本缩放、触摸行高、ScrollView 输入、浮层自适应、Stepper/ButtonGroup 重排、Vec3Field 重排、焦点环、辅助功能、高度类、Gallery 自适应、动画 17–21）**不在此重复**，避免双份维护。

## 1. 覆盖总览

| 家族 | 已有 | 缺失 |
| --- | --- | --- |
| 布局与容器 | Box/Row/Column/Spacer/Divider、ScrollView/BoundedScrollView、Panel、SplitView、Grid/LazyGrid、SafeArea、ViewThatFits/LayoutThatFits/ContainerSizeReader/WidthClassReader、VirtualStack/VariableVirtualStack、Workspace、Form/PropertyGrid | ZStack/Overlay 公共层叠容器 P1、Masonry P2、LazyGrid span P2、SplitView 单栏（规范 5-2）、程序滚动无时长动画（scrollview.md） |
| 命令与选择 | Button/IconButton、ButtonGroup、Toggle/Checkbox/RadioGroup、Slider、Rating、Stepper（流程）、ToolbarToggle | SplitButton/MenuButton P1、RangeSlider P1、FAB P2、Checkbox/Toggle 三态 P2 |
| 文本与数值输入 | TextField/TextArea/CodeEditor、NumberField（带步进）、Vec3Field、Select/Combobox、ColorField、AssetRefField、JsonField、Label/Link/KeyCap | SearchField P1、OTP/PIN P3、masked input P3、locale 小数 P2、数值拖拽 scrub P2 |
| 日期时间 | Calendar、DatePicker、TimeField（文本 HH:MM） | DateRangePicker P1、TimePicker/滚轮 P2、周/月/年选择 P2、12/24 小时与时区 P2 |
| 集合与数据 | List（单选/虚拟化/键盘）、Tree（多选/搜索/DnD/键盘）、Table、DataTable（200K/冻结列/编辑）、VirtualList/Stack、Chart（line/bar/sparkline）、Timeline、Tag | List 多选/区段/重排/swipe P1、下拉刷新 P1、Tree lazy children P1、TreeTable P2、DataTable 高级能力 P2、Chart 更多图形 P2 |
| 导航与外壳 | TabView（adaptive/closable）、Sidebar、Breadcrumb、Pagination、Accordion/DisclosureGroup、Toolbar、StatusBar、Workspace（compact）、Carousel、CommandPalette | AppBar/NavigationBar P0、NavigationDrawer P0（规范 5-2）、NavigationRail P1、NavigationStack/路由 P1、BottomNavigationBar P3（TabView 底部栏已可覆盖） |
| 浮层 | Modal/Dialog/AlertDialog、Sheet（四边）、Menu/ContextMenu、Popover/HoverCard/Tooltip、Toast/Notification（队列/时长/暂停/替换） | BottomSheet 拖拽与自适应 P0、Toast 操作按钮与位置 P1、ActionSheet/Popconfirm P2、菜单富内容 P2 |
| 反馈与状态 | Alert、Badge、Progress/ProgressCircle、Spinner、Skeleton、EmptyState、Toast、StatusTone | 基本完整；Banner 由 Alert 覆盖 |
| 展示与媒体 | Text/Typography、Icon、Image/AsyncImage/Thumbnail、Avatar/AvatarGroup、Badge/Tag/KeyCap/Label、ViewportHost、ScriptCanvasView | RichText/Markdown P2、视频播放组件（应用层按需）、GIF/WebP、EXIF/渐进、缓存淘汰 P2 |
| 拖放与交互 | AssetDropTarget、Tree DnD、Workspace 拖拽、PointerCapture | 通用 drag & drop 协议（任意 payload/列表重排）P1 |

## 2. 缺失组件规范

写法与规范第 3 节一致：外观 → 手机 → 平板/桌面 → 交互与验收。标注为当前状态。

### 2.1 AppBar / NavigationBar（P0）

- 用途：手机与平板的顶部应用栏：返回、标题、副标题、主操作、溢出。
- 外观：触摸高度 ≥ 44，桌面 48；标题 `bodyStrong` 单行截断并保留完整语义；返回为 ghost IconButton；操作最多平铺 3 个，其余进 overflow 菜单。`[未实现]`
- 手机：返回 + 标题 + 1 个主操作 + overflow；标题过长时截断并提供 tooltip/辅助功能全文；顶部安全区由宿主应用，AppBar 不重复。`[未实现]`
- 平板/桌面：标题前导 + 操作平铺 + 可选副标题；hover 反馈。`[未实现]`
- 交互与验收：键盘 Tab 顺序为 返回 → 操作 → overflow；辅助功能暴露标题 heading、返回名称、overflow 展开态；overflow 复用 Menu 契约（≥44 行高）。验收：390/720/1280 三档 + 安全区 + 播放安全区截图；新测试套件。参考：SwiftUI `toolbar`/`NavigationStack` 标题栏；Flutter `AppBar`。

### 2.2 NavigationDrawer（P0，Sidebar 的抽屉形态）

- 用途：compact/medium 宽度下 Sidebar 的覆盖层形态；见规范 5-2 的验收归属。
- 外观：宽度 `min(320, 窗口 − 56)`；遮罩 `stateLayerSelected` 强度；顶部保留标题与关闭；行高 ≥ 44。`[未实现]`
- 手机：边缘滑出（可选边缘手势，触摸 ≥ 24pt 起滑区）或按钮打开；打开时焦点进入并循环、Escape 关闭、关闭后焦点还原；选中项自动显露。`[未实现]`
- 平板/桌面：medium 可常驻或收为 rail（见 2.3）；expanded 常驻。`[未实现]`
- 交互与验收：抽屉状态属 session，旋转/宽度类切换保留；辅助功能把抽屉暴露为 dialog/组并读名称。验收：展开/关闭/焦点还原/滑动手势。

### 2.3 NavigationRail（P1）

- 用途：medium 宽度的图标导航轨（桌面可显式启用）。
- 外观：宽 72（图标 + 标签）或 56（纯图标）；选中指示条 2px accent；顶部/底部开放槽。`[未实现]`
- 手机：不出现；compact 仍用抽屉。平板：竖屏 rail + 内容；横屏可转常驻 Sidebar。`[未实现]`
- 交互与验收：键盘上下移动、Home/End；辅助功能选中态与标签；触摸目标 ≥ 44。参考：Flutter `NavigationRail`；SwiftUI `NavigationSplitView` 折叠态。

### 2.4 NavigationStack / 路由（P1）

- 用途：页面栈、返回、深链与状态保留；当前应用自行管理根视图切换。
- 外观：push/pop 使用 move + opacity；reducedMotion 时立即切换；返回手势沿用平台（Android 系统返回键、iOS 边缘手势）。`[未实现]`
- 行为：栈与路径属 session；旋转与宽度类切换保留栈与页面内状态；深链在根视图安装前解析。`[未实现]`
- 交互与验收：返回动画期间不重复入栈；辅助功能焦点落在新页标题；Escape 不用于返回（浮层优先）。参考：SwiftUI `NavigationStack`；Flutter `Navigator`。

### 2.5 SplitButton / MenuButton（P1）

- 用途：主操作 + 下拉备选（保存/另存为、运行/调试）。
- 外观：左侧主按钮 + 1px 分隔 + 右侧箭头区；两区各自命中 ≥ 44（触摸）；菜单复用 Menu 契约。`[未实现]`
- 手机：整体可占满一行；下拉从锚点下方展开，底部不足上翻。平板/桌面：紧凑并排。`[未实现]`
- 交互与验收：Tab 一次进入整体，左右键在主区/箭头区间移动，Enter 激活主区、Down 打开菜单；辅助功能暴露两个动作。参考：Fluent SplitButton；Material `SplitButton`。

### 2.6 RangeSlider（P1）

- 用途：区间选择（曝光区间、帧范围、价格/尺寸过滤）。
- 外观：双 thumb，各自 18pt 视觉；两端值标签可选；最小间距由调用方声明；轨道与 Slider 共用样式 token。`[未实现]`
- 手机：命中区 ≥ 44、thumb 不重叠（近距时推挤或合并显示）；平板/桌面：hover 高亮活动 thumb。`[未实现]`
- 交互与验收：拖动、方向键移动活动 thumb、Home/End、Tab 在两个 thumb 间切换；辅助功能暴露"起点/终点"两个 slider 值；非法输入（start > end − minGap）夹紧。参考：Flutter `RangeSlider`。

### 2.7 SearchField（P1）

- 用途：统一的搜索输入（放大镜、清除、空态、结果联想）。
- 外观：复用 TextField chrome + 前导图标 + 清除按钮；`[未实现]`（当前用 TextField 自行拼装）
- 手机：触摸 ≥ 44、聚焦后宿主滚动显露、软键盘出现不遮挡结果；平板/桌面：可配全局快捷键（Cmd/Ctrl+F 由应用绑定）。`[未实现]`
- 交互与验收：Escape 清空或取消（调用方选择）、Enter 提交、方向键在联想列表移动；辅助功能 role=textField + label"Search"；截断与完整值规则同规范第 1 节。参考：Flutter `SearchBar`/`SearchAnchor`；SwiftUI `.searchable`。

### 2.8 DateRangePicker（P1）

- 用途：日期区间（起点/终点）选择。
- 外观：复用 Calendar 月视图；起点/终点填充、区间段高亮、hover 预览；弹层宽度夹紧窗口。`[未实现]`
- 手机：单月一屏、日期格 ≥ 44；平板/桌面：可双月并排。`[未实现]`
- 交互与验收：第一次点击设起点、第二次设终点，Escape 取消草稿，区间非法自动交换并提示；辅助功能读"开始日期/结束日期"；键盘方向键移动、Home/End（月内）与 PageUp/Down（月份）复用规范 3.2 已实现的 Calendar 导航契约。参考：Flutter `DateRangePicker`；Material 3 date range picker。

### 2.9 列表能力包（P1）

按同一行契约（触摸 ≥ 44、单行截断、完整值可达）补齐：

- **多选与区间选择**：Checkbox 列或 Cmd/Shift 点选；Shift 区间以锚点延伸；辅助功能 selected 态。List 当前仅单选。`[未实现]`
- **区段（sections）**：区段头/尾、可选 sticky；DataTable 之外的表状列表先支持平面区段。`[未实现]`
- **重排（reorder）**：拖拽把手 ≥ 44 或长按起拖；放置指示线；Esc 取消；辅助功能提供"上移/下移"操作（键盘与读屏可达）。`[未实现]`
- **滑动操作（swipe actions）**：仅触摸面；滑动露出 1–2 个操作，操作按钮 ≥ 44；键盘通过上下文菜单提供等效入口；不把滑动作为唯一路径。`[未实现]`
- **下拉刷新**：阈值与阻尼、指示器、完成后回弹；reducedMotion 时指示器静止；键盘/命令提供等效刷新入口。`[未实现]`
- 验收：以上各能力分别提供触摸/键盘/辅助功能断言与 390/720 取样；重排与滑动的状态属 session。参考：SwiftUI `List(selection:)`/`onMove`/`swipeActions`/`refreshable`；Flutter `RefreshIndicator`/`ReorderableListView`/`Dismissible`。

### 2.10 ZStack / Overlay（P1）

- 用途：公共层叠容器（徽标叠加、加载遮罩、底层布局已用 `absolutePosition`/`zIndex`/Portal 组合）。
- 外观：子视图按自然尺寸层叠；后声明的在上；不自动裁剪。`[未实现]`
- 手机/平板：无差异；遮罩层点击穿透策略由调用方声明，a11y 只读可见层。`[未实现]`
- 交互与验收：命中测试从上到下；隐藏层不参与输入与辅助功能；与 Portal 的分工：ZStack 属内容层叠，Portal 属跨裁剪浮层。参考：SwiftUI `ZStack`；Flutter `Stack`。

### 2.11 BottomSheet 增强（P0）

- 用途：手机底部抽屉；当前 Sheet 已有 bottom 边，但无拖拽关闭与手机自适应（规范 5-10 已列浮层自适应）。
- 外观：顶部拖拽把手 ≥ 44 命中；全宽；高度档位（中/大）或内容自适应；桌面可退化为 Dialog。`[未实现]`
- 手机：下滑关闭（阻尼 + 速度阈值）、上滑展开档位；Escape/背景关闭保留；打开时焦点进入并循环。`[未实现]`
- 交互与验收：拖拽中内容不接输入；关闭后焦点还原；reducedMotion 下省略拖拽惯性。参考：SwiftUI `.presentationDetents`/`sheet`；Material 3 bottom sheet。

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
| Toast 操作与位置 | P1 | 卡片内最多 1–2 个操作（撤销/重试）；位置可配（默认右上，手机默认底部） | 手机底部避开 home 指示条 | 操作键盘可达、悬停暂停、退出动画 | Material Snackbar action；SwiftUI 自定义 |
| Menu 富内容 | P2 | 图标槽、任意行内容、链接语义 | 触摸行 ≥ 44 | 与现有键盘导航共用；富内容不破坏前缀查找 | Radix DropdownMenu；Fluent Menu |

## 3. 既有组件功能缺口（不含规范第 5 节条目）

| 组件 | 缺口 | 优先级 |
| --- | --- | --- |
| Toggle / Checkbox | indeterminate 三态、label 槽位 | P2 |
| Slider | 垂直方向、刻度标记、Page 键、区间（见 2.6） | P2 |
| Rating | RTL、自定义图形/半星以上精度 | P2 |
| NumberField / Vec3Field | locale 小数分隔、拖拽 scrub、单轴重置与向量复制/粘贴 | P2 |
| Select / Combobox | 远程/异步结果（按需）、触发器宽度联动 | P2 |
| DatePicker / TimeField | 12/24 小时与时区、滚轮（见 2.12）；DatePicker 键盘月份跳转已有 | P2 |
| Calendar | 区间选择（见 2.8）；Home/End/PageUp/Down 已实现，见 [日历导航](calendar.md) | P1 |
| List | 多选/区段/重排/swipe/下拉刷新（见 2.9） | P1 |
| Tree | 懒加载子节点、全部展开/折叠快捷；多选、搜索与触摸行高已有 | P1/P2 |
| Table / DataTable | 列重排、分组表头、分页/远端加载、单元格/矩形区间、可变行高、CSV 导出、表级撤销；列优先级见规范 5-4，文本缩放行高已有 | P2 |
| Chart | pie/area/scatter/stacked、图例交互、数据点选择 | P2 |
| Timeline | 分组/折叠、缩放 | P2 |
| Menu / ContextMenu | 富内容（见 2.12）、图标槽、链接语义；触摸展开验收见规范 5-10，触摸行高与水平翻转已有 | P2 |
| CommandPalette | 几何高固定 440；结果列表全量创建（未虚拟化）；无最近使用记录与自定义页脚；模糊匹配与分组已有 | P1/P2 |
| Sheet / Modal | 拖拽关闭与自适应（见 2.11）；其余契约完整 | P1 |
| Sidebar | 抽屉/rail（规范 5-2）、可调整宽度、嵌套子菜单、项级操作/上下文菜单 | P1 |
| Toolbar | 溢出（规范 5-1 已列）、垂直工具栏 | P1 |
| Workspace | N 面板联动、折叠阈值/吸附、pin 专属视觉、浮动为应用内层、文档解码校验与可版本化格式、a11y/RTL、chrome 硬编码清理（见 [workspace.md](workspace.md)） | P2 |
| ScrollView | 触摸拖动/惯性、键盘滚动、滚动条 a11y、横向 gutter、边界渐变、锚定滚动、带时长程序滚动、残余增量交接（规范 5-9 + [scrollview.md](scrollview.md)） | P1 |
| Form / PropertyGrid | 宽度标签切换（规范 5-3）、`minValueWidth` 语义统一、标签换行、校验摘要（按需） | P1/P2 |
| Carousel | 自动轮播、复杂指示器（按需）；滑动/键盘已有 | P2 |
| StatusBar / Panel | 状态格与标题截断策略（规范 1.1 已标部分） | P2 |
| CodeEditor / TextField | snippet tab-stop、超长单行分段布局（[textfield.md](textfield.md) 边界） | P2 |
| Image / AsyncImage | 缓存淘汰、在途合并、GIF/WebP 动画、EXIF、渐进解码（[image.md](image.md) 边界） | P2 |
| Avatar | 状态角标、可交互成员弹层（[avatar.md](avatar.md) 边界） | P2 |
| Icon / Typography | 彩色字形仅 macOS；RTL 双向段落完整语义 | P2 |
| Link | 访问态、外链确认（按需） | P3 |
| 拖放 | 通用 payload 协议与列表重排（见 2.9/2.10） | P1 |
| Toast / Notification | 操作按钮、位置配置、进出动画（见 2.12） | P1 |

## 4. 优先级与建议顺序

**P0（手机/平板可用性阻塞）**：AppBar/NavigationBar、NavigationDrawer（Sidebar 收敛）、BottomSheet 拖拽与自适应；再加规范第 5 节的 Toolbar 溢出、Form 标签、DataTable 列优先级、SplitView 单栏。

**P1（常用能力）**：NavigationRail、NavigationStack、SplitButton/MenuButton、RangeSlider、DateRangePicker、列表多选/区段/重排/swipe/下拉刷新、SearchField、ZStack、Tree lazy、Toast 操作与位置、CommandPalette 虚拟化、ScrollView 输入补齐（规范 5-9）、通用拖放。

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
| SplitButton | `Menu` + `Button` 组合 | `SplitButton`、`MenuAnchor` |
| RangeSlider | 无内置（双 Slider 组合） | `RangeSlider` |
| SearchField | `.searchable` | `SearchBar`、`SearchAnchor` |
| DateRangePicker | 无内置（双 DatePicker 组合） | `showDateRangePicker` |
| WheelPicker | `Picker` + `.pickerStyle(.wheel)` | `CupertinoPicker`、`ListWheelScrollView` |
| 多选/区段/重排/swipe/下拉刷新 | `List(selection:)`、`Section`、`onMove`、`swipeActions`、`refreshable` | `CheckboxListTile`、`ReorderableListView`、`Dismissible`、`RefreshIndicator` |
| ZStack | `ZStack` | `Stack` |
| BottomSheet | `.sheet` + `presentationDetents` | `showModalBottomSheet` |
| RichText / Markdown | `Text(markdown:)`、`AttributedString` | `flutter_markdown`（三方） |
| TreeTable | `Table` + `OutlineGroup` 组合 | `TreeView` 套件（三方） |
| Toast 操作 | 无内置 | `SnackBar` + `SnackBarAction` |
