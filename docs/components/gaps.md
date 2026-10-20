# 组件覆盖与缺失清单

本文与[跨平台控件规范](adaptive-spec.md)互补：规范管**已有**容器的空间不足阶梯、控件重排与输入/动效契约；本文管**还缺什么**——完整缺失的组件、既有组件的功能缺口，以及优先级与验收口径。

- 数据来源：`GuavaUI/Sources/GuavaUICompose/Primitives`、Gallery 98 页（`GalleryCatalog.swift`，页面数随目录更新）、各组件文档与逐项代码复核。
- 范围：脱离 Guava 编辑器语境仍成立的通用 UI 能力。场景层级、Inspector 字段面板、Material Graph、媒体时间线等领域组件留在应用层，不进本清单。
- 状态：`[未实现]` 完全缺失；`[部分]` 已有基础实现或可用组合替代；`[已实现]` 仅作对照。优先级 P0（手机/平板可用性阻塞）> P1（常用能力）> P2（长尾/体验）> P3（按需）。
- 自适应工作由规范第 1、3 节的状态与第 5 节完成记录跟踪（Toolbar、Sidebar、Form、数据列、Tab、截断、缩放、触摸行高、滚动、浮层、焦点与 Gallery 等）；本文仅保留交叉引用，避免双份维护。

## 1. 覆盖总览

| 家族 | 已有 | 缺失 |
| --- | --- | --- |
| 布局与容器 | Box/Row/Column/Spacer/Divider、ZStack/Overlay、ScrollView/BoundedScrollView、Panel、SplitView（compact 单面板）、Grid（含命名字段列显隐）/LazyGrid、Masonry、SafeArea、ViewThatFits/LayoutThatFits/ContainerSizeReader/WidthClassReader/HeightClassReader/OrientationReader、VirtualStack（固定/闭包/估计行高）、Workspace、Form/PropertyGrid | 显式 intrinsic 轨道、LazyGrid 跨行 span P2（Grid 跨行/跨列、LazyGrid 跨列与二维窗口化、VirtualStack 未知行高估测已实现） |
| 命令与选择 | Button/IconButton、ButtonGroup、SplitButton（主/备）、MenuButton、Toggle/Checkbox（含 mixed、label 槽）/RadioGroup、Slider（刻度/Page）、RangeSlider（双 thumb）、Rating、Stepper（流程）、ToolbarToggle、Toolbar 命令优先级与溢出 | 无通用缺失；FAB 按规范视觉基线不纳入 |
| 文本与数值输入 | TextField（含 Text Editor / 代码编辑）、TextArea、SearchField、NumberField（步进/locale）、Vec3Field（locale/缩放）、Select/Combobox、ColorField、AssetRefField、JsonField、FieldLabel/Link/KeyCap | OTP/PIN P3、masked input P3 |
| 日期时间 | Calendar、DatePicker、DateRangePicker、TimeField（文本 HH:MM）、WheelPicker（五行滚轮）、TimePicker（内联时/分/秒/AM-PM） | 时区选择入口 P2（DateRangePicker 区间预设与最大长度已实现） |
| 集合与数据 | List（单选/多选按 binding 类型、虚拟化/键盘）、SectionedList（区段/sticky 标题）、ReorderableList（拖拽重排）、SwipeList（触摸滑动/操作按钮/上下文菜单）、Tree（多选/搜索/DnD/键盘/同步延迟子节点）、Table、DataTable（200K/冻结列/编辑）、VirtualStack（固定/可变行高）、Chart（line/area/分组或堆叠 bar/scatter/pie·donut、可切换图例、数据点选择）、Timeline、Tag | DataTable 其余高级能力（分组表头、分页、区间选择、CSV、表级撤销）按需、Chart 轴标签/缩放 P3（TreeTable、DataTable 列重排与可变行高、ReorderableList 虚拟化、Timeline 分组/折叠/缩放已实现） |
| 导航与外壳 | TabView（adaptive/closable、溢出菜单与标题省略）、Sidebar / AdaptiveSidebar、NavigationDrawer、NavigationRail、NavigationStack（平台返回由宿主）、Breadcrumb、Pagination、Accordion/DisclosureGroup、Toolbar、AppBar、StatusBar、Workspace（compact）、Carousel、CommandPalette | Workspace 其余深化按需（见第 3 节）、BottomNavigationBar P3（TabView 底部栏已可覆盖）；Sidebar 行内 View 插槽、垂直 Toolbar 与 Workspace 标签条 a11y/RTL 已实现 |
| 浮层 | Modal/Dialog/AlertDialog、Sheet（四边）、BottomSheet（detent/拖拽/自适应）、Menu/ContextMenu、Popover/HoverCard/Tooltip、Popconfirm、ActionSheet、Toast/Notification（队列/时长/暂停/替换/操作/位置） | 按标题自动定宽或省略 P2（Menu 富内容行、图标槽、链接语义与 submenu 指针三角区意图已实现） |
| 反馈与状态 | Alert、Badge、Progress/ProgressCircle、Spinner、Skeleton、EmptyState、Toast、StatusTone | 基本完整；Alert 窄宽操作堆叠、关闭与大字号、Badge 长文本已补齐，Banner 由 Alert 覆盖 |
| 展示与媒体 | Text/Typography、RichText/Markdown（行内样式、链接、代码块、列表、表格、跨块选择复制）、Icon、Image/AsyncImage/Thumbnail、Avatar/AvatarGroup、Badge/Tag/KeyCap/FieldLabel、ViewportHost、ScriptCanvasView、WebView（宿主注入，macOS 已接入） | Wasm RGBA 字形与 PNG 位图彩色字体、非 Apple 平台渐进解码、其他平台 WebView 后端、视频播放组件（应用层按需）；Image 缓存淘汰/在途合并/GIF·WebP 动画/EXIF/macOS 渐进解码、Avatar 状态角标与成员弹层、Linux/Windows COLR 彩色字形与 RTL 双向段落已实现 |
| 拖放与交互 | AssetDropTarget、Tree DnD、Workspace 拖拽、PointerCapture、DragScope/Draggable/DropTarget | 通用 payload 协议已实现；`Draggable` 无自动滚动与键盘等价路径（集合重排用 ReorderableList，已具备二者） |

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
- 外观：按实际窗口拟合宽度 `min(320, 窗口 − 56)`；中性主题 `overlay` 遮罩；顶部标题与同一侧栏折叠图标；行高 ≥ 44。`[已实现]`
- 手机：按钮打开；焦点进入并循环、Escape 关闭、关闭后还原；选中项显露；左滑关闭并取消子按钮按下。可选边缘唤出由 AdaptiveSidebar 提供（仅紧凑触摸容器前导 24pt 起始的右滑）。`[已实现]`（独立按钮入口与壳层手势入口）
- 平板/桌面：可显式打开 Drawer，常驻形态使用 Sidebar，轨道使用 NavigationRail；AdaptiveSidebar 按容器宽度自动切换。`[已实现]`
- 交互与验收：展开与选择由应用 session binding 持有，窗口变化保留；辅助功能为带完整名称的 dialog。`NavigationDrawerTests` 覆盖宽度/字号/主题/输入、展开/关闭/焦点/手势/生命周期和 AI 查询；Gallery `DrawerTests` 覆盖独立页与 Sidebar 共享选择。

### 2.3 NavigationRail（P1）

- 用途：medium 宽度的图标导航轨（桌面可显式启用）；[NavigationRail](navigation-rail.md) 复用 Sidebar 数据和目的地节点。
- 外观：宽 72（图标 + 换行标签）或 56（纯图标）；纯图标形态为居中 40×40 圆角选择块，hover 叠中性 state layer 并提亮图标；顶部/底部开放槽。图标受轨道宽度约束，徽标用圆点并保留完整值。`[已实现]`
- 手机/平板：壳层应在 compact 使用抽屉、medium 使用 rail、expanded 使用 Sidebar；AdaptiveSidebar 已统一自动切换，并保留同一目的地、页面、焦点和会话。`[已实现]`
- 交互与验收：Up/Down、Home/End 循环并跳过禁用项，单一 Tab 停靠；完整名称/选中态/徽标值、tooltip、目标 ≥44pt；`SidebarPresentation` 切换保留节点/焦点/槽位状态。`NavigationRailTests` 覆盖输入矩阵、模式切换、滚动、AI 发现；Gallery `RailTests` 验证实际示例。参考：Flutter `NavigationRail`；SwiftUI `NavigationSplitView` 折叠态。

### 2.4 NavigationStack / 路由（P1）

- 用途：页面栈、返回、深链与状态保留；当前应用自行管理根视图切换。
- 外观：`NavigationStack` 以 caller-owned `[Route]` 为栈，root 与路径页在栈内保持挂载；push 时新页从 trailing 滑入并淡入、旧页向 leading 滑出，pop 时新顶页以反向 move+opacity 显露（被移除页立即卸载）；reducedMotion 由 `AnimatedVisibility` 直接吸附。`[已实现]`
- 行为：栈与路径属 session；旋转与宽度类切换保留栈与页面内状态（页在栈内保持挂载）；非空初始 path 在首帧恢复深链。平台返回键/边缘手势由宿主删除最后一个 route；组件不消费 Escape。`[已实现]`（平台返回由宿主）
- 交互与验收：组件在过渡 settle 前拒绝第二次 path 变化并写回上一次接受的栈；页面标题使用 `.navigationTitle`，新顶页布局后自动聚焦 heading 且不显示键盘环；平台返回由宿主删除最后一个 route。参考：SwiftUI `NavigationStack`；Flutter `Navigator`。`[已实现]`，API 与边界见 [NavigationStack](navigationstack.md)。

### 2.5 SplitButton / MenuButton（P1）

- **MenuButton**：常规按钮触发器 + Popover + Menu；保留 hover/press/focus/disabled、expanded 语义、Escape/外部点击关闭与菜单键盘导航。`[已实现]`，见 [MenuButton](menubutton.md)。
- **SplitButton**：主操作 + 下拉备选；左侧主按钮 + 右侧 MenuButton 箭头；两区各自命中 ≥ 44（触摸）且禁用同步；两区共享 1px `.border` 分隔线；菜单复用 Menu 契约。`[已实现]`，见 [SplitButton](splitbutton.md)
- SplitButton 手机/桌面：主按钮填充剩余宽度，箭头自然宽度；下拉从锚点下方展开，底部不足上翻。`[已实现]`
- SplitButton 交互与验收：单一 Tab 停靠进入整体，左右方向键在主/箭头两区之间移动并同步 roving Tab stop；两区各自 Enter/Space 激活，菜单复用 Menu；两段仍各自保留 secondary 圆角 chrome，1px 分隔线位于两段之间。`SplitButtonTests` 覆盖主/备动作、禁用与 roving 焦点；Gallery `splitButton` 页提供真实操作。参考：Fluent SplitButton；Apple `Menu` + `Button` 组合。

### 2.6 RangeSlider（P1）

- 用途：区间选择（曝光区间、帧范围、价格/尺寸过滤）。
- 实现：双 thumb 共用 SliderStyle 轨道；指针按距离选择 active thumb；`minimumSpan` 夹紧；每个 thumb 暴露独立 slider 语义（"Range start"/"Range end"），父节点为 group。`[已实现]`
- 手机/平板：触摸命中由 `applyTouchControlExtent` 提升到 44；指针 hover/focus 沿用 SliderStyle；thumb 近距时仍各自命中，不合并。
- 交互与验收：两个 thumb 各自是独立 Tab 停靠；聚焦哪个 thumb，方向键/Home/End 就移动哪个；指针按下就近 thumb 并把焦点切到对应 thumb。`RangeSliderTests` 5/5 覆盖指针、minSpan、键盘、双 Tab 与 focused-thumb ring；Gallery `rangeSlider` 页提供真实拖动；DevTools 在 720×820 查询到每个实例的两条 `slider` 语义。细节见 [RangeSlider](rangeslider.md)。

### 2.7 SearchField（P1，已实现）

- 用途：统一的搜索输入（放大镜、清除、空态、结果联想）。
- 实现：复用 TextField chrome + `decoration.leadingIcon` 前导图标 + clear action；联想列表内联在字段下方，按输入过滤，支持方向键、Return、Escape。`[已实现]`
- 手机/平板：字段沿用 TextField 的 44pt 触摸命中；联想行由 Button 保证触摸命中；窄宽随父容器收缩。全局快捷键（Cmd/Ctrl+F）由应用绑定，组件不注册全局键盘。
- 交互与验收：Escape 清空或取消、Enter 提交、方向键移动高亮；辅助功能 role=textField + label"Search"；`SearchFieldTests` 覆盖清空、候选选择与提交，Gallery `searchField` 页提供真实输入/联想。细节见 [SearchField](searchfield.md)。

### 2.8 DateRangePicker（P1）

- 用途：日期区间（起点/终点）选择。
- 实现：复用 Calendar 月视图/导航/可用日期；起点/终点 accent 填充、区间段 `stateLayerSelected`；触发器显示两端日期与 clear。`[已实现]`
- 手机/平板：日期格沿用 Calendar 的 44pt 触摸下限；单月一屏，宽屏可配 `numberOfMonths=2`；弹层宽度由 Popover 夹紧。
- 交互与验收：第一次点击设起点、第二次设终点，反向点击自动交换；Escape/外部点击关闭；键盘方向键、Home/End、PageUp/Down 复用 Calendar；a11y 触发器读完整区间。`DateRangePickerTests` 覆盖两击与交换；Gallery `dateRangePicker` 页提供真实日历与高亮。`rules.presets`（今天、昨天、最近 N 天、本月、上月或自定义解析器）在日历上方成排显示，超长或含不可用端点的预设禁用；`rules.maximumDays` 按含两端的天数限制区间，选定起点后超出范围的日期禁用且不能完成区间。`DateRangeRulesTests` 覆盖预设解析、长度计数与真实点击。细节见 [DateRangePicker](daterangepicker.md)。

### 2.9 列表能力包（P1）

按同一行契约（触摸 ≥ 44、单行截断、完整值可达）补齐：

- **通用行标题与尾槽**：`ListRow` 为 List/SectionedList 提供可组合 leading/title/trailing；标题单行省略，徽标/状态保持自然宽度，极窄时横滚，完整值保留语义与 tooltip。条件空槽、RTL、字号切换与窗口化已覆盖，Gallery 通过选中状态文本提供无 hover 全文入口。`[已实现]`，见 [ListRow](list.md#listrow标题与前后槽位)。
- **多选与区间选择**：Checkbox 列或 Cmd/Shift 点选；Shift 区间以锚点延伸；辅助功能 selected 态。`List(selection: Set)` 已实现 Cmd/Ctrl 切换、Shift 区间、Shift+Arrow、Cmd/Ctrl+A；Checkbox 列仍由调用方组合。`[已实现]`，见 [List](list.md#多选)。
- **区段（sections）**：区段头/尾、可选 sticky；DataTable 之外的表状列表先支持平面区段。`SectionedList` 已实现平面 header/footer、sticky 固定标题（下一标题上推）与跨区段键盘选择；`stickyHeaders` 默认关闭，固定副本不进入焦点/命中/语义。`[已实现]`，见 [List](list.md#sectionedlist)。
- **重排（reorder）**：`ReorderableList` 已实现 44pt 拖拽把手、2pt 放置线、Escape 取消、Up/Down 与辅助功能 increment/decrement；行身份与焦点跟随原行；拖到视口边缘自动滚动，放置线随内容移动（见 [List](list.md#reorderablelist)）。当前为非虚拟列表。`[已实现]`
- **滑动操作（swipe actions）**：`SwipeList` 仅在触摸面启用向 leading 滑动（LTR 左滑 / RTL 右滑），露出最多两个 74pt 宽、行高 ≥44 的 trailing 操作；指针、键盘与读屏通过行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口，滑动不是唯一路径。全量挂载。`[已实现]`
- **下拉刷新**：`List`/`VirtualStack` 接受 `RefreshOptions`；触摸下拉越过 64pt 阈值（可配置）触发一次，指示器在 `isRefreshing` 清除前保持，完成后回弹；`Spinner` 在 reducedMotion 下冻结。Cmd+R/Ctrl+R 为键盘/命令入口，调用方也可提供显式按钮。`[已实现]`，API 见 [RefreshableList](refresh.md)。
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
| TreeTable | 已实现 | 树缩进在首列 + 可调列（复用 DataTable 列宽、优先级、重排与虚拟化） | 触摸行 ≥ 44；窄宽隐藏低优先列 | 首列聚焦时 Right 展开/进入子项、Left 折叠/回到父项；披露按钮暴露展开态；不提供排序与单元格编辑（兄弟项保持原序） | SwiftUI `Table` + OutlineGroup；Fluent TreeGrid |
| OTP / PIN | P3 | N 个方格、自动前进 | 数字键盘、粘贴分发 | Backspace 退格、粘贴全填、a11y 整值读写 | 移动生态惯例 |
| Menu 富内容 | 已实现 | `MenuItemContent`：图标槽（同级共享一条图标列）、RichText 标题（仅展示，不抢焦点/选区）、副标题与链接语义 | 触摸行 ≥ 44 | 与现有键盘导航共用；前缀查找仍按纯文本标题；链接行为 link 角色并带外链图标；指针朝已开子菜单移动时三角区内延长切换延迟 | Radix DropdownMenu；Fluent Menu |

**RichText / Markdown 已实现（P2）**：`RichText` 把多样式 run（粗体、斜体、行内代码、删除线、链接）排成一个段落，按空格、表意文字（含禁则）与 URL 的 `/`、`-` 断行；`MarkdownView` 用 swift-markdown（`private import Markdown`，AST 不进入公开 API）解析 CommonMark + GFM，原生渲染标题、引用、嵌套/有序/任务列表、可复制且横向滚动的代码块、按内容定列宽并可横向滚动的表格与分隔线。手机端正文随容器换行，代码块与宽表格横向滚动；链接为可 Tab 聚焦的 link 元素，Return 与辅助功能激活；文档共享选区，支持拖动跨块、双击/三击、⌘/Ctrl+C/A、右键 Copy / Select All 与触摸长按。图片显示为链接的替代文字，HTML 原样显示为代码；每个段落按首个强方向字符决定方向，RTL 段落行尾对齐并按部分 UAX #9 行级规则重排（见 [Typography](typography.md#双向段落)）。`RichTextTests`、`RichTextLinkTests`、`TextSelectionTests`、`MarkdownParsingTests`、`MarkdownRenderingTests` 与 Gallery `richText` / `markdown` 页及三预览覆盖，DevTools 验收记录见 [RichText](richtext.md) 与 [Markdown](markdown.md)。

**Popconfirm 已实现（P2）**：复用 Popover 的卡片、箭头与十二向定位；指定方位保持不变，空间不足时限制该侧视口并滚动。触发器为 secondary（危险操作使用红色文字），只有确认按钮使用危险色实底；Cancel/Confirm 为真实 Button，不默认显示重复 tooltip。Escape/外部点击/再次点击关闭，确认回调仅执行一次。`PopconfirmTests` 覆盖布局/输入/主题/RTL 矩阵；Gallery 提供紧凑定位面板与窄屏单锚点预览。细节见 [Popconfirm](popconfirm.md) 与 [Popover](popover.md)。

**ActionSheet 已实现（P2）**：所有宽度使用底部抽屉；compact 全宽贴底并带顶部拖拽区，支持下拉超过 80pt 或高速释放关闭、短拖回弹与外部点击关闭，不显示关闭图标；medium/expanded 为最大 560pt 的居中抽屉，右上提供 44pt 关闭图标。调用方提供打开 binding、稳定 ID 的操作数组与必填 `closeLabel`，组件不硬编码 Cancel/Close 文案；wide 关闭图标使用该名称作为辅助功能 label 与 tooltip。操作行 ≥44pt，行间使用 1pt 分隔线，hover/键盘焦点只叠中性 state layer；支持图标/危险/禁用；Up/Down/Home/End 跳过禁用并显露目标，wide 抽屉 Tab 从操作组移动到关闭图标。长列表独立滚动，头部固定；宽度变化只保留一个有效 Portal。`ActionSheetTests` 与 Gallery 三档预览覆盖布局/主题/字号/输入/RTL、拖拽、compact 无关闭图标、生命周期与 AI 查询。细节见 [ActionSheet](action-sheet.md)。

**Masonry 已实现（P2）**：最短列放置、按宽度自动 1–2 列、列/项间距、RTL 与最大列数；卡片高度由子视图自然测量，不二次缩放字号。`MasonryTests` 覆盖最短列、列数上限、单列退化、间距与 RTL；Gallery `masonry` 提供 Add card/Reset 和 390/720/1280 预览，DevTools 实测 720pt 两列、390pt 单列，点击 Add card 后计数从 8 变 9 并重新平衡。当前不做跨列 span、行优先填充或窗口化；大集合使用 `LazyGrid`/`VirtualStack`。细节见 [Masonry](masonry.md)。

**Toast 操作、位置与过渡已补齐**：最多两个内联操作、真实按钮键盘可达、`ToastPosition` 四角定位与 `.automatic`（所有宽度右上，iOS 通知横幅形态），并计入宿主安全区。主题时长的位移/淡入淡出/收拢、退出即禁用、同 ID 反转去重、有界退出树与减少动画清理均已实现，见 [Toast](toast.md)。

**WheelPicker 与 TimePicker 已实现（P2）**：WheelPicker 提供五行视口、中央 band、拖拽/滚轮/点击/方向键、disabled 跳过与 slider a11y；TimePicker 在其上组合时/分/可选秒/AM-PM、12/24 小时与 min/max 夹紧。两者均有 390/720/1280 Gallery 预览、自动化测试与 DevTools 验收。细节见 [WheelPicker](wheelpicker.md) 与 [TimePicker](timepicker.md)。

## 3. 既有组件功能缺口与完成边界

| 组件 | 缺口 | 优先级 |
| --- | --- | --- |
| Toggle / Checkbox | label 槽位已实现；Checkbox 的 `CheckboxState.off/on/mixed` 也已实现，Toggle 仍采用 Bool 开关语义 | 已完成 |
| Slider | 水平/垂直、RTL 映射、拖动/键盘/辅助功能已完成，见 [Slider](slider.md) | 已完成 |
| Rating | RTL 映射/填充/方向键、多星示例滚动、窄宽评分说明重排、自定义图形（`RatingSymbol`）与 1–20 等分精度已实现，见 [Rating](rating.md) | 完成 |
| NumberField / Vec3Field | locale 小数、触摸/大字号轴单元；`NumberField(prefix:resetValue:)` 前缀芯片拖拽 scrub（每 4pt 一步，Shift ×10 / Option ×0.1）、双击单轴重置，Vec3Field 复用同一芯片并提供复制/粘贴/重置向量菜单（`Vec3FieldTests`，DevTools 720 拖拽 X 1→2、右键菜单） | 已完成 |
| Select / Combobox | 触发器宽度下限与窗口夹紧已实现；Combobox 远程结果契约（`ComboboxSearch`：防抖、取消、加载/失败/重试/最小长度状态）已实现，见 [Combobox](combobox.md) | 完成 |
| DatePicker / TimeField | Calendar 配置可指定 timeZone，时区选择入口仍缺；TimeOfDay 是不含时区的墙钟值，转换由调用方负责；TimeField 继续作为文本入口，12/24 小时与滚轮由 TimePicker 提供；DatePicker 键盘月份跳转已有 | P2 |
| Calendar | 区间选择、Home/End/PageUp/Down、整板窄宽滚动、触摸弹层预算，以及日/周/月/年粒度与标题上钻的月份/年份网格已完成，见 [日历导航](calendar.md) | 完成 |
| List | 多选、平面区段、sticky 区段、重排、SwipeList、下拉刷新及 ListRow 标题/尾槽已实现（见 2.9）；重排边缘自动滚动已实现（见 [List](list.md#reorderablelist)） | 已完成；ReorderableList 已按视口窗口化，拖拽/键盘目标保留挂载 |
| Tree | 同步延迟子节点、全部展开/折叠快捷、多选、搜索、禁用与触摸行高已完成；异步请求与加载状态由调用方数据层管理，见 [tree.md](tree.md) | 已完成 |
| Table / DataTable | 仍缺：分组表头、分页/远端加载、列/矩形单元格选择、CSV 导出、表级撤销（按需）。已实现：200K 行后台排序、冻结列、编辑、列优先级、显隐菜单、文本缩放行高、列拖拽/键盘重排（`columnOrder`）、按记录可变行高（`rowHeight`）与 TreeTable，见 [数据表](data-table.md) | 按需 |
| Chart | pie/donut、area、scatter、分组与堆叠 bar、图例切换与数据点选择（指针/触摸/键盘/辅助功能）已在单一 `Chart` 中实现，见 [Chart](chart.md)；坐标轴刻度标签、时间轴、缩放平移与动画过渡仍缺 | 轴标签/时间轴/缩放 P3 |
| Timeline | 分组/折叠（`TimelineGroup`）、按时间比例间距（`TimelineSpacing.proportional`）与缩放（`TimelineZoom`）、容器窄宽重排、完整时间语义与 200% 字号已完成，见 [Timeline](timeline.md) | 已完成 |
| Menu / ContextMenu | 富内容、图标槽、链接语义与 submenu 指针三角区意图已实现（见 2.12）；仍缺按标题自动定宽或省略；触摸展开验收见规范 5-10，触摸行高与水平翻转已有（[Menu](menu.md)） | 自动定宽 P2 |
| CommandPalette | 结果列表已虚拟化（视口 + overscan）；compact 几何、触摸行高、模糊匹配、分组、session 级最近使用与自定义 footer 已完成 | 已完成 |
| Accordion / DisclosureGroup | 字符串标题单行省略、全文 tooltip/语义、触摸与缩放行高、键盘展开和退出生命周期已完成，见 [Disclosure](disclosure.md) | 已完成 |
| Sheet / Modal / Dialog | BottomSheet 拖拽与自适应（见 2.11）、居中模态 compact 宽度、Dialog 操作堆叠与 AlertDialog 字号高度已完成，见 [Dialog](dialog.md) | 已完成 |
| Sidebar | 嵌套导航、项级操作/上下文菜单、展开会话、键盘/辅助功能、可调整栏宽与行内 View 插槽（`slots.leading`/`trailing` 装饰、`accessory` 可交互）已实现，见 [Sidebar](sidebar.md#项级操作) | 已完成 |
| Toolbar | 垂直工具栏（`axis = .vertical`：Up/Down 导航、侧边分隔线、按高度溢出并在侧边打开菜单）、命令优先级、更多菜单、图标名称与焦点交接已实现，见 [toolbar.md](toolbar.md) | 已完成 |
| Workspace | 标签条 tabList/tab/tabPanel 语义、RTL 方向键与 macOS 容器角色映射已实现；仍需平台读屏取样、系统尺寸偏好、N 面板联动、折叠阈值/吸附、pin 专属视觉与关闭其他/右侧可见操作、浮动仅为应用内层、文档不可信解码校验与可版本化格式、chrome/图标/高度硬编码清理、大文件按 shell/tabs/drag/floating 拆分（见 [workspace.md](workspace.md#仍需完善)） | 标签条 a11y/RTL 已完成（tabList/tab/tabPanel 语义、位置与固定状态、RTL 方向键镜像）；其余按需 |
| ScrollView | 触摸拖动/惯性、键盘滚动、滚动条 a11y、横向 gutter、边界渐变、带时长程序滚动（`ScrollRequest`）、`.scrollAnchor()` 锚定、残余增量交接（规范 5-9 + [scrollview.md](scrollview.md)） | 已实现 |
| Form / PropertyGrid | 自适应标签、共享值槽阈值、列数重排、标签关联与 Form 校验摘要已实现，见 [form.md](form.md)；PropertyGrid 跨字段业务校验由应用管理 | 已实现 |
| Carousel | 自动轮播（悬停/聚焦暂停、播放/暂停、减少动态效果）、圆点/计数指示器与进度、全宽视口已实现，见 [Carousel](carousel.md) | 完成 |
| StatusBar / Panel | 状态格单行截断、完整 a11y 值、多个前后状态格的有限几何与 `DefaultPanelStyle` 标题截断已实现，见 [Panel](panel.md)；等宽策略仍由调用方声明 | 已完成 |
| TextField（Text Editor） | 平面编辑样式、稳定行号留白、中性当前行及共用 resize grip 已完善；断点/行级图标/折叠、44pt 触摸菜单、文档会话和 AST/LSP 集成已补齐，见 [gutter](editor-gutter.md) 与 [视觉验收](textfield.md#编辑器视觉与交互验收)。脚本调试运行时后端由应用提供；snippet tab-stop（LSP 片段语法、Tab/Shift+Tab 访问、编辑随 tab stop 平移）与超长单行分段塑形/水平裁剪已补齐 | 已完成 |
| Image / AsyncImage | CPU 缓存 LRU 字节/数量淘汰、同键在途合并、GIF/WebP 动画播放（减少动态效果停在首帧）、JPEG EXIF 方向、macOS/iOS 有界渐进预览与远程 SVG 按 MIME 识别已实现；仍缺：非 Apple 渐进解码（[image.md](image.md) 边界） | P2 |
| Avatar | 状态角标（四态独立形状、读屏值、RTL 镜像）与可交互成员弹层（`AvatarMemberList`）已实现，见 [avatar.md](avatar.md) | 已完成 |
| Icon / Typography | Linux/Windows 经 FreeType 渲染 COLRv0 与未压缩 BGRA 位图彩色字形；Text/RichText/Markdown 按段落实现部分 UAX #9 显示规则的双向排版（行级 RTL 对齐、显式方向塑形、L1/L2 视觉重排）已实现；仍缺：显式嵌入/隔离方向控制、PNG 压缩位图字体（需带 libpng 的 FreeType）、Wasm RGBA 字形、RTL 编辑语义（光标/选区）、字体图集自动淘汰（[typography.md](typography.md#边界)） | P2 |
| Link | 访问态、外链确认（按需） | P3 |
| 拖放 | 通用 payload 协议已实现，见 [Drag & Drop](drag-and-drop.md)；列表重排见 ReorderableList | 已实现 |
| Toast / Notification | 操作、位置、主题进出动画、减少动画与退出生命周期已完成，见 [Toast](toast.md) | 已完成 |

## 4. 优先级与建议顺序

**P0（手机/平板可用性阻塞）**：本清单的组件级项目已实现；宿主 IME 联动已改为由宿主增加 `safeArea.bottom`，`SafeArea` 与消费该 inset 的容器/控件在同一帧重排，`CommandPalette` 面板高度与结果区随 inset 收缩，`TextField` 获得焦点时宿主滚动显露光标且组件内 caret 跟随滚动；真实设备/读屏验收仍按规范第 3、4 节跟踪。BottomSheet 拖拽与自适应已实现，见 [BottomSheet](bottom-sheet.md)。Grid / DataTable / Table 列优先级、显隐菜单与 minimum 横向滚动兜底、AppBar、Toolbar 命令溢出、Form 标签重排、SplitView 单面板、NavigationDrawer 覆盖层与 AdaptiveSidebar 统一壳层已实现，验收与边界见 [layout.md](layout.md#grid-字段列)、[data-table.md](data-table.md)、[appbar.md](appbar.md)、[toolbar.md](toolbar.md)、[form.md](form.md)、[splitview.md](splitview.md)、[navigation-drawer.md](navigation-drawer.md)。

**P1（常用能力）**：全部已实现；Sidebar 嵌套/项级操作、ScrollView 带时长程序滚动与滚动锚定均已补齐。通用拖放（`DragScope`/`Draggable`/`DropTarget`）、NavigationRail、AdaptiveSidebar 统一壳层、Toast 操作/位置、ZStack、SearchField、MenuButton、RangeSlider（双 thumb 独立 Tab/语义）、SplitButton（单一 Tab + 左右分区 + 1px 分隔）、DateRangePicker、ScrollView 输入（触摸拖动/键盘）、CommandPalette 虚拟化与 compact 几何、列表多选、平面区段、sticky 区段、ReorderableList 重排、SwipeList 滑动操作、列表下拉刷新与 NavigationStack（标题焦点/过渡去重；平台返回由宿主）均已实现，边界及验收见 [Sidebar](sidebar.md#自适应壳层)、[Toast](toast.md)、[ZStack](zstack.md)、[SearchField](searchfield.md)、[MenuButton](menubutton.md)、[RangeSlider](rangeslider.md)、[SplitButton](splitbutton.md)、[DateRangePicker](daterangepicker.md)、[ScrollView](scrollview.md)、[CommandPalette](commandpalette.md) 、[List 多选](list.md#多选) 、[SectionedList](list.md#sectionedlist) 、[SwipeList](swipelist.md) 、[RefreshableList](refresh.md) 、[NavigationStack](navigationstack.md) 与 [Drag & Drop](drag-and-drop.md)。

**P2（长尾/体验，保留未完成项）**：时区选择入口、Workspace 其余深化、DataTable 其余能力（分组表头、分页/远端、区间选择、CSV、表级撤销）、Grid 显式 intrinsic 轨道与 LazyGrid 跨行 span、Menu 按标题自动定宽/省略、PNG 压缩位图彩色字体与 Wasm RGBA、非 Apple 渐进解码、完整双向方向控制/编辑语义、字体图集自动淘汰。Workspace 与 DataTable 的后续功能按产品需求启动。

**P3（按需）**：Chart 轴标签/时间轴/缩放、OTP/PIN、masked input、BottomNavigationBar、Link 访问态/外链确认。

### 4.1 本轮批次记录（2026-10-20）

下表记录本轮代码与自动化覆盖；“实现”不等同于所有平台已完成原生视觉/读屏验收。既有组件文档中的历史截图记录也不替代本轮新增行为的验收。

| 批次 | 实现与文档 | 新增/更新测试 | 剩余边界 |
| --- | --- | --- | --- |
| 1：小而独立 | [Avatar 状态/成员弹层](avatar.md#状态角标与成员列表)、[日期预设/最大长度](daterangepicker.md)、[Sidebar 行内槽](sidebar.md)、[垂直 Toolbar](toolbar.md#垂直工具栏)、[Workspace 标签语义/RTL](workspace.md) | AvatarPresenceTests、DateRangeRulesTests、SidebarSlotTests、VerticalToolbarTests、WorkspaceViewTests | Workspace 其余深化与实际读屏取样仍保留 |
| 2：共享底座 | [Menu 富内容/图标/链接/指针意图](menu.md#富内容图标与链接)、[RichText/Markdown 行级双向显示](typography.md#双向段落)、[Linux/Windows FreeType 彩色来源](typography.md#linux-与-windows-彩色字形) | MenuContentTests、BidiTests、ColorGlyphResampleTests | 显式嵌入/隔离控制、RTL 光标/选区、PNG 位图字体与 Wasm RGBA；Linux/Windows 字体原生验证尚待补齐 |
| 3：数据密度 | [Grid span/LazyGrid 二维窗口](layout.md#grid-跨列跨行)、[VirtualStack 估测/ReorderableList 窗口化](list.md)、[DataTable 列重排/可变行高/TreeTable](data-table.md)、[Timeline 分组/折叠/缩放](timeline.md#分组折叠与缩放) | GridSpanTests、VirtualizationEstimateTests、DataTableLayoutTests、TimelineGroupTests | LazyGrid 仅跨列；TreeTable 保持兄弟原序，不提供排序/编辑；ReorderableList 仍为固定行高 |
| 4：媒体与编辑器 | [图片 LRU/合并/GIF/WebP/EXIF/macOS 渐进预览](image.md)、[snippet tab-stop/超长单行分段](textfield.md) | ImagePipelineTests、AsyncImageTests、SnippetTests | 渐进预览仅 macOS；WebP 动画合成/渐进预览需独立像素验收；snippet 同号占位无镜像同步；超长行仍需首次塑形整行各段 |

### 4.2 后续按需队列

1. **产品入口**：时区选择器；Chart 轴标签/时间轴/缩放（P3）；OTP/PIN、masked input、BottomNavigationBar、Link 访问态/外链确认（P3）。
2. **数据与工作区**：按调用方需求选择 DataTable 分组表头/分页/区间选择/CSV/撤销；Workspace 的 N 面板联动、折叠吸附、pin 视觉、浮动层、解码校验、chrome 清理与文件拆分。
3. **现有实现深化**：按上表保留跨平台渲染、完整双向语义、LazyGrid 跨行、intrinsic 轨道与 Menu 自动宽度等缺口；不因本轮主体代码合入而关闭这些边界。

### 4.3 图片加载后续补齐（2026-10-20）

远程下载已将 MIME 与最终 URL 格式信息交给生产解码服务，无扩展名 SVG、误导扩展名、通用 MIME 与重定向均有真实 HTTP 回归。macOS/iOS 共用 ImageIO 渐进缩略图路径，预览遵守源像素预算、目标上限与 EXIF 方向；`ProgressiveImageTests` 验证不完整 JPEG 的实际预览像素。代码、测试与平台边界见 [Image](image.md)。非 Apple 渐进解码、交错 PNG/iOS 设备取样及 WebP 动画像素验收继续保留。

FAB 不作为待补组件：按[视觉基线](adaptive-spec.md#2-视觉与密度基线)，主操作使用 Button/AppBar/Toolbar。P2/P3 表仍是未完成功能清单，不能由 P0/P1 的完成推断全部组件已完成。

排序依据：先补"壳层与触摸集合"（手机整屏可用性），再补"数据密度与常用输入"，最后补长尾与性能深化。领域组件（场景/资产/材质/时间线业务）不进入 GuavaUI。

AssetRefField 的窄宽与触摸契约已补齐：名称/副标题省略保留全文，清空/选择有独立 44pt 目标，字段按字号自然增高；菜单与拖放使用同一 kind 过滤。24 组合矩阵及禁用/投递回归、三档 DevTools 选择与清空和视觉检查通过。详见 [资源引用](assetref.md)。JsonField 也已补齐 compact 全高展开、独立编辑区、长标题、全宽触摸操作和一次安全区消费；三档 DevTools 提交/无效草稿/取消及镜像视觉检查见 [JSON 编辑器](jsonfield.md#acceptance)。

## 5. 验收门槛

新组件与功能补齐共用[规范第 4.3 节](adaptive-spec.md#43-自动化)的门槛，另加三条：

生产宿主也参与验收：Editor 的条件诊断面板已暴露并修复 ScrollView 缺失 `@ViewBuilder` 的编译问题，`contentBuilder` 回归覆盖条件空态与内容，`EditorApp` 构建通过。

1. 每个新组件必须给出 390（触摸）/ 720（混合）/ 1280（指针）三档验收记录，并进入 `GalleryCatalog` 与 `AdaptiveControlExamples.supports`（或提供等价预览）；
2. 列表类能力必须包含触摸（滑动/长按/拖动）与键盘/辅助功能等效入口的成对断言；不允许存在只能触摸完成的动作。
3. 每项经 [DevTools AI 闭环](adaptive-spec.md#devtools-ai-闭环无需-computer-use)执行真实输入、查询结果（延迟输入值用指定 node_id + include_value 显式读取）、状态变化后的真实控件角色，并查看镜像画面，记录命令/测试名、实际尺寸和视觉结论；测试入口缺失或不好用时先完善再验收。原生镜像支持与窗口一致的 backdrop 模糊，并有 Metal 像素及 resize 回归。键盘代码会在 CLI 投递前校验；动画后截图使用有界 `--settle-ms` 取样并查询目标状态，避免把动画首帧当作完成画面。完成代码、Gallery、测试与文档后单独提交 Git。

## 6. 参考对照（缺失组件）

| 缺失组件 | SwiftUI / Apple HIG | Flutter（仅行为对照） |
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
| 多选/区段/重排/swipe/下拉刷新（已实现） | `List(selection:)`、`Section`、`onMove`、`swipeActions`、`refreshable` | `CheckboxListTile`、`ReorderableListView`、`Dismissible`、`RefreshIndicator` |
| ZStack | `ZStack`（已实现） | `Stack` |
| BottomSheet | `.sheet` + `presentationDetents`（已实现） | `showModalBottomSheet` |
| RichText / Markdown（已实现） | `Text(markdown:)`、`AttributedString` | `flutter_markdown`（三方） |
| TreeTable | `Table` + `OutlineGroup` 组合 | `TreeView` 套件（三方） |
| Toast 操作 | 无系统等价（已实现） | 仅作行为对照，不采用 Snackbar 视觉 |
