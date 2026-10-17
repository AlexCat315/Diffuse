# GuavaUI 跨平台控件规范（手机 / 平板 / 桌面）

本文把 [组件标准](standard.md) 的交付要求展开为可实现、可验收的逐项规范：先定义布局容器在空间不足时的统一处理阶梯，再逐项规定控件的默认外观、手机与平板上的重排方式，以及触摸、键盘和辅助功能交互；随后给出动效与动画（曲线、弹簧、进入/退出）的选型与实现；最后给出与 Gallery、单元测试和真机对应的验收方法。

- 适用对象：`GuavaUI` 第一方容器与控件；应用自定义组件在其职责范围内复用同一套表面模型与阶梯。
- 设计参考：SwiftUI（size class、`ViewThatFits`、`Layout`、focus/keyboard 语义）与 Flutter（`MediaQuery`、`LayoutBuilder`、Material 3 adaptive 的 bar/rail/drawer 收敛、`FittedBox`/`TextOverflow`、`ActionChip`/overflow menu 模式）。命名与 API 不必对齐，行为契约对齐。
- 状态标注：第 1、3 节的关键行为在行尾带 `[已实现]`、`[部分]`、`[未实现]`，表示当前代码与本规范的差距；未实现项必须按第 5 节清单关闭，不能默认豁免。
- 数值均为逻辑点。DPI 只影响栅格密度；`TextScaler` 只缩放一次。宿主提供 viewport、safeArea、input、reducesMotion，组件不得直接读取平台 API。

## 0. 表面模型与设备类

一切自适应只依赖宿主的 `UIEnvironment`，不用平台判断：

| 字段 | 取值 | 来源 |
| --- | --- | --- |
| `viewport.widthClass` | `compact` < 600 ≤ `medium` < 1000 ≤ `expanded` | 宿主窗口/表面逻辑宽度 |
| `input` | 任意组合 `touch` / `pointer` / `keyboard` / `pen` | 宿主当前可用输入 |
| `safeArea` | 四条逻辑 inset | 宿主根应用一次 |
| `reducesMotion` | Bool | 系统偏好 |
| `minimumControlExtent` | touch 时 44，否则 28 | 派生 |
| `supportsHover` | `input ⊇ pointer` | 派生 |

设备类到表面条件的映射（用于验收取样，不是运行分支）：

| 设备类 | 典型宽度 | 典型输入 | hover | 安全区 | 验收取样 |
| --- | --- | --- | --- | --- | --- |
| 手机 | compact（< 600）；大屏手机横屏可能落 medium | touch-only 或 touch + keyboard | 无 | 顶部/底部非零，横屏侧边非零 | 390pt、触摸、无 hover |
| 平板 | 竖屏 medium（600–999）；横屏多为 expanded | touch；接键盘/触控板时 touch + pointer + keyboard | 有（触控板/鼠标） | 非零 | 720pt 触摸；720pt 触摸 + 指针；≥1000pt |
| 桌面 | expanded（≥ 1000） | pointer + keyboard | 有 | 通常为零 | 1280pt 指针 + 键盘 |

规则：

- **设备类不是平台。** 平板接键盘必须获得桌面级 hover/焦点行为，同时保留 44pt 触摸密度；桌面窗口缩到 390pt 必须进入 compact 重排。组件内部不得出现 `os(iOS)`、`isAndroid` 之类分支，平台差异只允许出现在宿主适配器。
- **宽度与输入独立判定。** 不允许用 "窄 ⇒ 触摸" 或 "宽 ⇒ 指针" 的隐含假设；两者分别读 `widthClass` 与 `input`。
- **安全区由宿主根应用一次**，独立嵌入表面（如游戏内面板、预览卡片）自行提供 `surfaceEnvironment`；`SafeArea` 只消费尚未使用的边。
- **旋转/尺寸变化保留状态。** 同一进程内，宽度类切换、横竖屏旋转不得重建应用根状态；保留节点身份、`@State`、焦点与滚动位置（TabView、ViewThatFits 分支已有此契约）。
- **减少动画**由 `reducesMotion` 提供，组件不得自行读系统设置。

## 1. 空间不足的统一处理阶梯

所有容器与控件在空间不足时按同一优先级退让。高优先级先执行；能靠前一级解决就不进入下一级。

| 级别 | 手段 | 典型入口 | 约束 |
| --- | --- | --- | --- |
| P0 | 保住核心内容与主操作 | 任何布局 | 触摸面上任何可交互目标 ≥ 44pt；主操作不得因缺空间被隐藏 |
| P1 | 收缩可收缩项 | `flex(shrink: basis:)`、`frame(maxWidth:)` | 不改变语义、不缩触摸目标、不禁用文本缩放 |
| P2 | 换行与重排 | `Box(wrap:)`、`ViewThatFits`、`LayoutThatFits`、TabView 换边、Sidebar/Workspace 收敛 | 重排后节点与状态保留 |
| P3 | 滚动 | `ScrollView`、`BoundedScrollView`、标签条横向滚动、菜单内部滚动 | 溢出轴给滚动，非溢出轴继续透传 |
| P4 | 单行截断 | 省略号 | 必须同时给出完整文本的 tooltip 与辅助功能值 |
| P5 | 折叠进溢出入口 | overflow 菜单、"更多" | 溢出入口自身 ≥ 44pt 且键盘可达 |
| P6 | 隐藏非必要装饰 | 次要元数据、装饰图标 | 不得隐藏状态语义；隐藏项不占布局与命中 |

**全局禁止**：

- 把触摸目标压到 44pt 以下，或靠缩小控件"塞下"内容。
- 内容被裁剪却没有滚动、溢出菜单或替代呈现（裁剪后不可达即违规）。
- 以 hover 作为唯一入口；触摸面必须能直接完成所有动作。
- 用固定高度硬顶大字号；控件必须允许按内容增长，显式 `.frame(height:)` 只作为应用约束注明。

**文本退让规则**（P4 的统一口径）：

| 内容类型 | 规则 |
| --- | --- |
| 单行标签、按钮标题、菜单项、tab 标题、表格单元格 | 单行截断；完整值进 tooltip 与辅助功能 |
| 正文、说明、设置项副标题 | 默认换行，行高随 `TextScaler` 增长 |
| 数字、版本号、计数 | 不截断有效位；必要时换行或给出完整值 |
| 路径、代码、URL | 尾部或中间省略；复制与完整值必须可达 |
| 图标 + 文本混合 | 图标不参与截断；文本截断后图标仍有独立语义槽 |

### 1.1 容器的空间不足契约

| 容器 | 空间不足时的行为 | 状态 |
| --- | --- | --- |
| `Box` / `Row` / `Column` / `Spacer` | 默认只收缩 `flex(shrink: >0)` 的子项；`Row` 不自动换行，需要换行的工具栏/标签排显式用 `Box(wrap: .wrap)` 或 `ViewThatFits`。`Column` 不拉伸子节点到父宽。`Spacer` 与 `.flex()` 兄弟争抢剩余空间，固定间距不要用 `Spacer` 冒充 | `[已实现]` |
| `ZStack` / `ZStackLayout` | 测量到最大子视图，子视图按 proposal 测量后按 `alignment` 层叠；后声明的在上并优先接收指针；不自动裁剪溢出，条件卸载的分支不绘制/不接输入/不暴露语义；RTL 下 leading/trailing 按逻辑边解析 | `[已实现]`，见 [ZStack](zstack.md) |
| `View.overlay(alignment:)` / `OverlayLayout` | base 决定测量尺寸；overlay 按 base bounds 对齐，不参与父级布局；overlay 后声明并优先接收指针；overlay 大于 base 时允许溢出 | `[已实现]`，见 [ZStack](zstack.md) |
| `ScrollView` / `BoundedScrollView` | 先按内容测量；`BoundedScrollView` 在 min/max 高度内先长大再滚动。溢出轴在边界处按 `.whenScrollable` 停留（顶部/底部继续吃滚动，不带动父级），非溢出轴允许事件透传；滚动条用 `.stable` gutter 预留 12pt 不压尾部控件 | `[已实现]`；键盘 Page/Home/End 与触摸拖动已实现，滚动条辅助功能 `[未实现]` |
| `SplitView` | 空间足够时优先满足两侧 minimum；比例范围与像素最小冲突时像素最小优先。未启用 compact 时，空间不足按两个最小尺寸的比例共享并裁剪。`compact` 按容器轴向长度（默认阈值 600pt）切换为单面板 + 页签，保留两个面板的节点、草稿、滚动与请求比例；恢复双栏时重新应用约束。拖拽/键盘/辅助功能才写回比例 binding；触摸分隔柄 ≥ 44pt | `[已实现]`；API 与边界见 [SplitView](splitview.md) |
| `Grid` / `LazyGrid` | `fixed` 保持 authored 宽，`flexible(minimum:)` 不跌破 minimum，`adaptive(minimum:)` 随宽度减少列数。Grid 在 minimum 超宽时横向滚动；命名字段列按优先级隐藏并提供 Columns 菜单。LazyGrid 使用有界视口与窗口化行高 | Grid 列策略、显隐与滚动兜底 `[已实现]`，见 [布局](layout.md#grid-字段列)；span/二维窗口化仍缺 |
| `ViewThatFits` / `LayoutThatFits` | 按容器实测宽（默认阈值 600）、intrinsic 自然尺寸或候选测量选择布局；两分支各自保留节点与 `@State`，隐藏分支不参与布局/绘制/输入/辅助功能并释放焦点与指针捕获；重任务由应用按当前形态控制 | `[已实现]` |
| `ContainerSizeReader` | 发布自身内容盒（扣 padding/border）实测尺寸；首次收到 `.zero`，变化 < 0.5pt 不发布；父级必须有界宽。卡片内部自适应用它，不用窗口宽度 | `[已实现]` |
| `WidthClassReader` | 读取 surface 级 width class（窗口级），用于壳层：导航收敛、栏位切换；不用于卡片内部 | `[已实现]` |
| `HeightClassReader` / `OrientationReader` | 读取 surface 级 height class（<600 / 600–999 / ≥1000）与横竖屏（方形归 landscape）；与宽度类一样只用于壳层，不用于卡片内部 | `[已实现]` |
| `SafeArea` | 只应用宿主提供的 logical insets，嵌套时只消费未使用边；桌面默认零；不推断刘海/软键盘/窗口 chrome。宿主要求：手机竖屏底部 inset 含 home indicator，横屏含侧边；IME 出现由宿主处理，组件不用占位 | `[已实现]`；IME 联动 `[部分]` |
| `Form` / `PropertyGrid` | 按字段实测宽度在 leading ↔ stacked 间切换；共享 `labelPlacement` 和 `minValueWidth` 语义。Form 最大列数随宽度减少，值槽保留节点与编辑状态；完整标签进 tooltip 与语义 | 重排 `[已实现]`；通用省略号见第 5-6 项，API 见 [Form](form.md) |
| `TabView` 标签条 | 标题内部单行省略，全文进 tooltip/语义；整项按 `overflow` 换行、横向滚动或折叠菜单，menu 保留所选项与可达入口；compact 时按 `TabStripPlacement.adaptive` 移到内容下方，节点与状态保留 | 换边、滚动、溢出菜单与标题截断 `[已实现]`，见 [TabView](tab.md) |
| `Toolbar` | `items:` 按命令自然宽度与优先级收进 overflow 菜单，`.always` 保留主操作；提供图标时使用图标与完整名称。触摸命中 ≥ 44pt，主命令自身超宽时保留尺寸并横向滚动；自定义内容闭包由应用安排重排 | 命令溢出 `[已实现]`，见 [Toolbar](toolbar.md) |
| `Sidebar` | expanded 常驻；compact/medium 按壳层选择折叠为抽屉/覆盖层或 rail；抽屉打开时焦点进入、Escape 关闭、关闭后焦点还原；项行高 ≥ 44pt（触摸） | 常驻列表、[NavigationDrawer](navigation-drawer.md)、[NavigationRail](navigation-rail.md) 及 [AdaptiveSidebar](sidebar.md#自适应壳层) 统一壳层 `[已实现]` |
| `Workspace` | widthClass != expanded 时自动进入紧凑呈现：单面板 + 面板选择器；expanded 恢复停靠树。折叠、比例、活动面板作为会话保留，不写入文档 | 紧凑切换 `[已实现]`；标签条键盘与完整语义 `[部分]` |
| `Panel` / `StatusBar` / `Carousel` 等边框容器 | 标题/状态格单行截断并保留完整语义；`Carousel` 一页一屏、不因窄而缩小内容，方向键/滑动/Home/End 导航；`StatusBar` 单元格等高等宽策略由调用方声明 | 结构 `[已实现]`；状态格截断策略 `[部分]` |

### 1.2 虚拟化与大数据

- 大集合（List/Tree/Table/DataTable/VirtualStack）必须使用窗口化协议，空间不足不改变虚拟化契约：List/Tree/Table/DataTable 先按 `TextScaler` 缩放 authored 行高，触摸面再应用 44pt 下限；窗口化 extent 与滚动范围使用同一高度，切回指针保留字号缩放并移除触摸下限。通用 VirtualStack 使用调用方传入的实际高度。
- 已知可变行高用 `VariableVirtualStack`；未知高度测量 `[未实现]`。普通 `ScrollView` 不自动窗口化，长列表必须显式选择容器。
- 数据表列在窄宽下：`TableColumn.visibility` 声明必要列或自动列优先级；Table / DataTable 按实际宽度隐藏低优先列，提供横向滚动、显隐菜单及可选用户选择 binding。冻结列和活动编辑不参与隐藏，规则与超宽冻结区兜底见 [数据表](data-table.md#列优先级与可见性)。`[已实现]`
- Grid 命名字段列使用同一 `ColumnVisibility`，隐藏后仍保留源行槽位与局部状态；内置显隐入口和 minimum 横向滚动，匿名 adaptive 卡片流保持原语义。`[已实现]`

## 2. 视觉与密度基线

所有控件默认外观由当前 `Theme` 的语义 token 决定，不允许在组件内写死颜色：

| 槽位 | 规则 |
| --- | --- |
| 颜色 | 只消费 `theme.colors.*`（accent/onAccent/surface/surfaceVariant/onSurface/onSurfaceMuted/border/stateLayer*/focusRing…）；状态层用 `Color.composited(over:)`，不用 `lighter()`/`darker()` |
| 字体 | 继承最近 Theme 的 body/语义角色；`TextScaler` 对字号、行高、字距只缩放一次；控件允许按内容增长 |
| 圆角 | `theme.radius.*` |
| 间距 | `theme.spacing.*`；容器 gap 用 `spacing:`，不手写空 `Spacer` |
| 动效 | `theme.motion.*`（fast 默认 80ms / standard 180ms / slow 320ms）；`reducesMotion` 时禁用框架运动，状态反馈仍在；曲线、弹簧选型与实现见第 6 节 |
| 焦点环 | 键盘焦点 2px `focusRing`；指针点击焦点不画环；disabled/loading 不参与焦点 |
| 命中区 | 触摸面 ≥ 44pt；指针面 authored 最小值 ≥ 28pt；命中区是完整 chrome，不只是文字/图标 |
| 状态 | 每个可交互控件必须定义 rest / hover（仅 pointer）/ press / focus / disabled；可选中控件另有 selected；loading 不得误触发动作 |

控件 authored 尺寸与触摸下限（验收对照）：

| 控件 | authored 高度/尺寸 | 触摸面 |
| --- | --- | --- |
| Button / IconButton | chrome 32（mini 可用于桌面工具栏） | ≥ 44pt |
| Toggle / Checkbox | 24 / 18pt box | ≥ 44pt |
| TextField（regular） | 28；其他密度按 size 递增 | ≥ 44pt |
| Slider | 24（thumb 18、track 4） | ≥ 44pt 命中区，轨道仍居中绘制 |
| Rating | 星 12/16/20/28（mini/small/regular/large），命中高 ≥ 32 | 每星 lane ≥ 44pt |
| Stepper / ButtonGroup / Segment | 以内容测高，触摸时平台下限 | ≥ 44pt |
| Tab 标签 / 关闭按钮 | 高度 max(40, touch 44) | ≥ 44pt |
| List / Tree 行 | 30（树 30 + 每级缩进 16） | `max(rowHeight, 44)` |
| Calendar 日期格 | 由 controlSize 决定 | 格宽高 ≥ 44pt |
| Sidebar 行 | ≥ 38 | ≥ 44pt |
| 菜单行 | 文本实测行高，快捷键列独立 | 行 ≥ 44pt（触摸） |
| 工具栏高度 | 桌面紧凑 | ≥ 44pt（触摸） |
| Sheet extent | 默认 400，夹紧窗口 | 拖拽把手 ≥ 44pt |
| SplitView 分隔柄 | 视觉线 1pt，命中 ≥ 7pt | ≥ 44pt（触摸） |
| Workspace 分隔 | 1px 线 + 6pt 命中槽 | ≥ 44pt（触摸） |

交互密度切换规则：输入集合变化时，已挂载节点必须在同一帧内更新下限与 hover 能力；切回指针恢复 authored minima。触摸-only 表面不得查询或展示 hover 状态，触摸 + 指针表面同时保留 44pt 密度与 hover。`[已实现]`

## 3. 逐控件规范

每个控件先给**外观**（尺寸与状态，完整 token 见对应组件文档），再给**手机**（compact）与**平板 / 桌面**（medium / expanded）的重排，最后给**交互与验收**（触摸 / 键盘 / 辅助功能）。`[已实现]`、`[部分]`、`[未实现]` 只描述当前代码；属于契约但未实现的条目在第 5 节汇总。

### 3.1 命令与布尔

**Button / IconButton**

- 外观：chrome 32pt，5 个变体（primary/secondary/ghost/destructive/plain）；键盘焦点 2pt `focusRing`；disabled 不接动作。`[已实现]`
- 手机：命中 ≥ 44pt，绘制可保持 32pt 高度但不能缩点击区；命令列保持主次顺序，primary 不被截断也不进溢出菜单。工具栏/对话框等单行上下文的长标题截断并保留完整 tooltip 与辅助功能名称；表单页按钮允许换行到两行。`[部分]`（换行已实现，单行截断未实现）
- 平板 / 桌面：命令并排、hover 反馈、mini 密度仅用于指针面；触控板用户同时得到 hover 与 44pt。`[已实现]`
- 交互与验收：触摸命中区等于完整 chrome；键盘 Space / Return / KP Enter（忽略重复）；辅助功能 role=button、activate action，icon-only 名称取 tooltip。`[已实现]`。验收：`TouchDensityTests`（button/segment 44pt、密度恢复）、Gallery `--component button` 的 narrow/wide/touch 三预览。

**Toggle / Checkbox / RadioGroup**

- 外观：开关 track 38×20、方框 18pt；状态层用 composited；选中/开启走 accent 语义色。`[已实现]`
- 手机：行内 label 与控件并排；label 换行时控件顶部对齐；触摸时绘制缩小到 authored 尺寸但命中 ≥ 44pt。`[已实现]`
- 平板 / 桌面：hover 状态只在 pointer 面出现；密度恢复 authored 24 / 18pt。`[已实现]`
- 交互与验收：键盘 Space / Return；RadioGroup 单一 Tab 停靠 + 方向键循环；辅助功能 role=checkbox / toggle / radio，暴露 value 与 selected。焦点环统一为仅键盘焦点可见：Toggle 的开关/复选框绘制与 Slider/RangeSlider 的 style 快照都使用 `focused && isFocusVisible`，指针点击只移动焦点目标、不画环。`[已实现]`。验收：`FocusRingTests`（Button、Toggle、Slider、RangeSlider 的 ring 顶点）、`TouchDensityTests`（checkbox/toggle）、Gallery `--component checkbox|toggle`。

### 3.2 连续与离散值

**Slider**

- 外观：高 24pt、thumb 18、track 4、填充 accent；disabled 全 surfaceVariant。`[已实现]`
- 手机：命中区 ≥ 44pt 且轨道居中；每行一个滑杆；数值标签同行放不下时移至下一行而不截断。`[已实现]`（44pt 命中）；标签重排由调用方布局。
- 平板 / 桌面：hover/press thumb 反馈；恢复 24pt 原生高度。`[已实现]`
- 交互与验收：指针拖动、方向键、Home/End、辅助功能 slider setValue / increment / decrement；Page 键与离散刻度视觉 `[未实现]`。验收：`TouchDensityTests` slider、Gallery `--component slider`。

**RangeSlider**

- 外观：双 thumb 共用 SliderStyle 轨道；active thumb 在键盘聚焦时绘制 focusRing；区间填充。`[部分]`
- 手机：触摸命中由 `applyTouchControlExtent` 提升到 44pt；窄宽随父容器收缩。`[已实现]`
- 平板 / 桌面：指针就近选择 active thumb；方向键/Home/End 移动 active；hover 沿用 SliderStyle。`[已实现]`
- 交互与验收：`minimumSpan` 夹紧；a11y value 为 `"lower – upper"`，增减作用于 active thumb；两个 thumb 的独立 Tab 停靠/双 slider 语义仍待补。`RangeSliderTests` 覆盖指针、minSpan 与键盘；Gallery `--component rangeSlider`。细节见 [RangeSlider](rangeslider.md)。

**Rating**

- 外观：星 12/16/20/28（mini/small/regular/large），可交互高度 ≥ 32；半星预览；只读用 image 语义。`[已实现]`
- 手机：每星命中 lane ≥ 44pt、组件高 ≥ 44pt；触摸面无被动 hover 预览，按下拖动仍预览；最大星数下放不下时整体裁剪绘制与命中，不允许负值布局。`[已实现]`
- 平板 / 桌面：hover 预览、键盘焦点环 2pt；恢复紧凑展示尺寸。`[已实现]`
- 交互与验收：方向键步进、Home/End、Delete 清空、Escape 取消；辅助功能 slider 语义 + setValue/increment/decrement。验收：Rating 测试族 + Gallery `--component rating` 的 narrow/wide/touch。

**Stepper**

- 外观：数字/完成/失败/忙碌图标 + 标题 + 说明；选中是导航、状态是业务值，互不写入。`[已实现]`
- 手机：容器宽度不足每个步骤的横向预算（默认每步 148pt + 24pt 连接段）时切换为纵向堆叠，方向键随实际轴；保留宽/窄两套分支，不压缩步骤、触摸目标或说明文本。`[已实现]`，`StepperOptions.minimumHorizontalStepWidth` 可调
- 平板 / 桌面：横向单行；200% 文本缩放可操作。`[已实现]`
- 交互与验收：单一 Tab 停靠、方向键（随实际轴）、Home/End、边界停止、禁用跳过；窄宽堆叠后 Left/Right 不再导航、Up/Down 生效；辅助功能暴露序号与结果。验收：`NarrowReflowTests.stepperReflow`、`ProductInteractionRegressionTests.stepperNavigation`、`--component stepper`。

**ButtonGroup / Segment**

- 外观：分段单选，选中填充 accent；roving focus 单停靠点。`[已实现]`
- 手机：段数多时不缩文字；超出宽度时按段换行，段宽与触摸高度保持，roving focus 仍只占一个 Tab 停靠点。`[已实现]`
- 平板 / 桌面：单行分段；hover 反馈。`[已实现]`
- 交互与验收：方向键切换、辅助功能 radio/tab 语义；触摸段高 ≥ 44pt；换行后所有段仍可达。验收：`NarrowReflowTests.buttonGroupReflow`、`TouchDensityTests` segment、Gallery `--component buttonGroup`。

**Calendar**

- 外观：月视图、日期格由 `controlSize` 决定；前后月箭头为独立按钮。`[已实现]`
- 手机：日期格 ≥ 44pt，单月一屏；放不下时整板横向滚动，不缩格。`[部分]`（触摸格下限已实现；整板滚动与窄宽取样待验收）
- 平板 / 桌面：可多月份并排（`numberOfMonths`）；hover 日期反馈。`[已实现]`
- 交互与验收：方向键移动（±1/±7）；Home/End 定位焦点所属月份的首个/最后一个可用日期，PageUp/PageDown 按日号翻月并夹到月末。不可用目标在目标月内查找，空月不改变焦点；导航不提交选择，Return/Space 才激活。多月份窗口仅在目标超出已显示范围时移动；禁用日期释放焦点。辅助功能每格 role=button + 完整日期/选中态，月份箭头有名称。`[已实现]`。验收：`CalendarKeyboardNavigationTests`、`TouchDensityTests` calendar、`NavigationStateTests.calendarKeyboard`、`--component calendar` 三预览；完整契约见 [Calendar / DatePicker](calendar.md)。

### 3.3 文本与数值输入

**TextField / TextArea / CodeEditor**

- 外观：regular 28、small/mini 更低；单行水平、多行垂直（`maxVisibleLines` 默认 6）；clear 仅在聚焦且可清空时出现。`[已实现]`
- 手机：输入 surface 与 style host 命中 ≥ 44pt；获得焦点时宿主滚动显露光标；多行输入不因软键盘挤压丢光标。`[已实现]`（44pt、滚动显露）；IME 联动 `[部分]`
- 平板 / 桌面：恢复 authored 高度与 hover scrollbar；键盘 F1/补全等不依赖指针。`[已实现]`
- 交互与验收：完整编辑键位、提交/取消、Unicode 与文本缩放、辅助功能 role=textField + 值延迟生成。验收：`TouchDensityTests` field、`TextField*`/`CodeEditingUITests`；Gallery `--component textField`。

**SearchField**

- 外观：TextField chrome + 装饰性前导搜索图标 + clear action；联想列表内联在字段下方，选中项使用 `stateLayerSelected`。`[已实现]`
- 手机：字段沿用 TextField 的 44pt 命中；联想行由 Button 提供 44pt 触摸命中；窄宽随父容器收缩，候选长文本不撑出容器。`[已实现]`
- 平板 / 桌面：常规字段密度；方向键/Return/Escape 与指针选择均可用。`[已实现]`
- 交互与验收：Escape 清空或取消、Return 提交、ArrowUp/Down 移动候选高亮；辅助功能 role=textField + label "Search"；`SearchFieldTests` 覆盖清空、选择与提交；Gallery `--component searchField` 提供真实输入与联想。细节见 [SearchField](searchfield.md)。

**NumberField / Vec3Field**

- 外观：NumberField 为 TextField + 可选步进列（最小 22pt）；Vec3Field 为三个可收缩轴单元 + 固定轴字母。`[已实现]`
- 手机：步进按钮触摸 ≥ 44pt；Vec3Field 在宽度不足时按 96pt 基准换行，X/Y 一行、Z 下一行（极窄时逐行），轴单元最小 88pt 保持可编辑，不靠 clip 隐藏输入。`[已实现]`
- 平板 / 桌面：单行三联编辑；Shift/Alt 步进语义保持。`[已实现]`
- 交互与验收：提交/失焦解析、非法输入恢复、min/max 夹紧、辅助功能输入值；换行前后轴输入身份与草稿保留。验收：`NarrowReflowTests.vec3Reflow`、`--component numberField|vec3Field`。

**ColorField**

- 外观：色块 52×22 + 可选 inline hex；弹层 220 宽、通道行固定列。`[已实现]`
- 手机：弹层宽度 ≥ min(280, 窗口 − 24)，触摸通道行 ≥ 44pt；不因窄而隐藏 hex 输入。`[未实现]`（弹层固定 220）
- 平板 / 桌面：保持弹层宽度与 hover。`[已实现]`
- 交互与验收：弹层键盘可达、Escape 关闭、辅助功能值可读。验收：`--component colorField`。

**Select / Combobox**

- 外观：触发器继承 field chrome；弹层菜单、`maxVisibleRows` 默认 8、内部滚动；Combobox 带搜索与清除。`[已实现]`
- 手机：触发器单行截断并保留完整值（tooltip/辅助功能）；弹层宽度 ≥ 触发器宽度且 ≤ 窗口 − 24；行高按输入面取 32（指针）/ `max(44, minimumControlExtent)`（触摸），长选项自然增高。`[已实现]`
- 平板 / 桌面：触发器与弹层自然宽度、hover 高亮。`[已实现]`
- 交互与验收：键盘 Up/Down/Home/End/Enter/Escape、类型前缀查找；辅助功能为 `comboBox` 角色，label/value 为当前值、`isExpanded` 反映弹层；help 保留完整值。验收：`--component select|combobox`、`RowDensityTests.menuRows`（Menu 触摸行高）、DevTools 390pt Select 弹层实测（宽 346、x=32、右边界 378，触发器 286）。

**DatePicker / TimeField**

- 外观：触发器最小宽 140 + 清除按钮；弹层按月份数取宽。`[已实现]`
- 手机：触发器单行截断、弹层宽度 ≤ 窗口 − 24、日期格/时间格 ≥ 44pt。`[部分]`（弹层宽度与格高需补验收）
- 平板 / 桌面：弹出日历，键盘可导航。`[已实现]`（日历部分）
- 交互与验收：Escape 关闭、辅助功能 label/value/isExpanded；验收：`--component datePicker|timeField`。

**DateRangePicker**

- 外观：触发器显示起止日期 + clear + chevron；弹层复用 Calendar 月视图，端点 accent、区间段 `stateLayerSelected`。`[已实现]`
- 手机：日期格沿用 Calendar 44pt 触摸下限；单月一屏；弹层宽度由 Popover 夹紧。`[已实现]`
- 平板 / 桌面：可配双月并排；方向键/Home/End/PageUp/Down 复用 Calendar。`[已实现]`
- 交互与验收：第一击设起点、第二击设终点，反向点击自动交换；Escape/外部点击关闭；a11y 触发器读完整区间；区间预设/最大长度由应用层负责。`DateRangePickerTests` 覆盖两击与交换；Gallery `--component dateRangePicker`。细节见 [DateRangePicker](daterangepicker.md)。

**AssetRefField / JsonField**

- 外观：AssetRefField 显示资源 + 清除 + drop 目标；JsonField 紧凑多行编辑、提交校验、拖拽调整高度、展开为带行号的大编辑器。`[已实现]`
- 手机：drop 目标在触摸面保留清空与选择入口（拖放不是唯一路径）；JsonField 展开模式占满窗口并 ≥ 44pt 操作按钮。`[部分]`（清空已有；展开按钮触摸尺寸需验收）
- 平板 / 桌面：拖放与展开均可；hover 提示。`[已实现]`
- 交互与验收：Cmd+Return 提交、Escape 取消、校验失败保留草稿；验收：`--component assetRef|jsonField`。

**Form / PropertyGrid**

- 外观：前导标签与值槽，窄宽自动堆叠。Form 提供帮助、错误摘要和可换行提交区；PropertyGrid 提供区段、折叠、嵌套和滚动。`[已实现]`
- 手机：读取字段实际内容盒宽度，标签不足时移到值上方；Form 减少列数。`minValueWidth` 为共享的首选值槽阈值，极窄时单列填满可用宽度，不强撑窗口。输入和属性区段标题命中 ≥ 44pt。`[已实现]`
- 平板 / 桌面：宽度足够时恢复前导标签；labelWidth 随 TextScaler 缩放一次，字号变化重新决定是否并排。节点、草稿、光标与焦点不因重排重建。`[已实现]`
- 交互与验收：标签关联限于所属 Form，属性值继承行名称，支持 AI 诊断按标签定位。`FieldLayoutTests` 覆盖 390/720/1280pt、100%/200%、三种输入集合、真实编辑、列数切换和诊断位置；Gallery `--component form|propertyGrid` 提供三预览。固定布局配置与边界见 [Form / PropertyGrid](form.md)。

### 3.4 数据集合

**List / MultiSelectList / SectionedList / ReorderableList / Tree**

- 外观：行高 30（触摸 44）、选中/ hover 走 `SelectionAppearance(.navigation)`；MultiSelectList 与 SectionedList 使用同一行 host；SectionedList 平面 header/footer 不进入焦点，可选 sticky 标题固定当前区段并由下一标题上推；ReorderableList 行尾 44pt handle；Tree 每级缩进 16、箭头列 18。`[已实现]`
- Tree 指示线只保留低对比度竖线（1pt、`onSurfaceMuted` 的 24% alpha），移除横向连接；禁用、同步延迟子节点、Home / End 与 Option / Alt + Left / Right 全部折叠 / 展开已完成，具体边界见 [Tree](tree.md)。
- 手机：行高 `max(TextScaler.scale(rowHeight), 44)`；行内容单行截断，完整文本进辅助功能；不因窄而隐藏尾部语义（徽标/状态）。`[部分]`（行高与文本缩放已实现；截断未实现）
- 平板 / 桌面：移除触摸下限，List/Tree 行高与行间距均跟随 `TextScaler`；hover 行高亮。`[已实现]`
- 重排：`ReorderableList` 提供 44pt 拖拽 handle、2pt 放置线、Escape 取消与一次 `onMove`；聚焦 handle 后 Up/Down 和辅助功能 increment/decrement 移动同一行，行身份与焦点跟随原行。当前为全量挂载的非虚拟列表，视口边缘自动滚动未实现。`[已实现]`
- 滑动操作：`SwipeList` 只在触摸面启用左滑，横向阈值 8pt，纵向手势交给 `ScrollView`；最多露出两个 74pt 宽、行高 ≥44 的 trailing 操作。行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口，滑动不是唯一路径。当前为全量挂载。`[已实现]`，API 见 [SwipeList](swipelist.md)。
- 下拉刷新：`List`/`VirtualStack` 接受 `RefreshOptions(isRefreshing:threshold:action:)`；触摸下拉越过阈值（默认 64pt，含 ScrollView 阻尼）只触发一次，指示器在 `isRefreshing` 清除前保持并在顶部预留 36pt inset，完成后回弹；`Spinner` 在 reducedMotion 下冻结。Cmd+R/Ctrl+R 为键盘/命令入口，调用方也可提供显式按钮。`[已实现]`，API 与边界见 [RefreshableList](refresh.md)。
- 交互与验收：List 方向键/Home/End/Enter + listItem 语义；MultiSelectList 支持 Shift/Cmd 点选、Shift+Arrow、Cmd/Ctrl+A；Tree 方向键、Left/Right 折叠、treeItem + selected/expanded。验收：`MultiSelectListTests`、`ReorderableListTests`、`RefreshTests`、`TouchDensityTests` list、`RowDensityTests.collectionRows`、`TextScaleRowTests.collectionGeometry`、`NavigationStateTests` tree 200%。

**Table / DataTable**

- 外观：authored 行高（Table 36 / DataTable 36）与表头高度均随 `TextScaler` 缩放一次；表头固定、冻结列、单元格单行裁剪。`[已实现]`
- 手机：行、单元格与表头高度 ≥ 44pt，窗口化、冻结列、滚动范围和键盘翻页共用真实行高，内嵌按钮与编辑器保留完整命中。列按优先级隐藏低优先列，显隐入口及菜单行 ≥44pt；冻结列和活动编辑保留，必要内容超宽时横向滚动。`[已实现]`
- 平板 / 桌面：两轴窗口化、列宽拖拽、键盘单元格导航。`[已实现]`
- 交互与验收：键盘导航（箭头/Home/End/PageUp/PageDown/F2/Escape/Cmd+A）、编辑提交/取消、辅助功能 row/cell/slider（列宽）。验收：`DataTableInteractionTests`、`RowDensityTests`、`TextScaleRowTests.collectionGeometry` / `dataTableNavigation`、`--component table|dataTable`。

**Grid / LazyGrid**

- Grid 的命名 fixed/flexible 字段列按 minimum 和优先级自动隐藏，必要列保留，提供 ≥44pt 的 Columns 入口与菜单、用户选择 binding 和恢复自动模式。源行槽位、节点、局部编辑草稿不因显隐改变；隐藏子树不绘制、不接输入、不暴露语义，所属附属浮层关闭。必要列或显式显示超宽时横向滚动，匿名 adaptive 退化至 minimum 后同样可滚动。`[已实现]`
- Grid 验收：`GridColumnsTests` 覆盖三档宽度、100%/200%、三种输入、明暗主题、RTL、状态、菜单、滚动和 AI 查询；`CustomLayoutVisibilityTests` 覆盖缓存绘制与命中，`--component layout` 提供可交互示例。GridLayout 仅负责布局算法，菜单与滚动由 Grid facade 提供；span、二维窗口化及滚动条辅助功能仍待补齐。

- 固定与已知可变行高均接收未缩放逻辑高度，行高和行间距自动跟随 `TextScaler`；列宽与列间距不参与字号缩放。变量模式复用 authored 前缀索引，不因字号变化或滚动遍历全部数据。`[已实现]`
- 窗口化、占位、单元格高度与滚动 extent 使用同一份缩放几何；字号恢复后夹紧超出范围的滚动位置，保留重叠可见单元格身份。验收：`TextScaleRowTests.collectionGeometry` / `variableGrid`、`LazyGridTests`。

**Chart / Timeline**

- 外观：Chart 由调用方提供数据与几何；Timeline 垂直事件列。`[已实现]`
- 手机：图表宽度 100%、不缩字号；图例折行；Timeline 时间列与内容列在窄宽下上下堆叠。`[部分]`（按故事现状；堆叠规则需实现与验收）
- 平板 / 桌面：横向图例与并排时间列。`[已实现]`
- 交互与验收：数据点辅助功能值可读；验收：`--component chart|timeline`。

### 3.5 导航与流程

**TabView**

- 外观：strip + divider + 内容；选中 2px accent 指示；可选关闭按钮（ghost mini + tooltip/名称）。`[已实现]`
- 手机：`placement = .adaptive` 在 compact 把 strip 移到内容下方，节点与状态保留；触摸标签与关闭 ≥44pt。`.menu` 保留选中项，隐藏标签进入 More tabs（入口及行 ≥44pt）；标题单行省略并保留完整 tooltip/名称，图标、徽标和关闭按钮保留尺寸，极窄时横向滚动。`[已实现]`
- 平板 / 桌面：strip 在顶部；`.wrap`、`.scroll` 或 `.menu` 由调用方选择；roving focus。`[已实现]`
- 交互与验收：方向键/Home/End 可选择隐藏项并在实际放置后聚焦，支持同帧连续按键；禁用项跳过，菜单 Escape 恢复入口，选中菜单项聚焦该标签。标签语义、完整原文和关闭按钮独立停靠点均保留。验收：`TabOverflowTests`、`AdaptiveNavigationTests`、`TouchDensityTests` tabs、`--component tabs` 三预览；通用 ScrollView 触摸拖动/键盘滚动见第 5-9 项。

**NavigationStack**

- 外观：root + `[Route]` 路径页叠放；顶层页从 trailing 滑入并淡入，旧顶页向 leading 滑出；pop 时顶层页反向显露。页面背景取 `theme.colors.background`，隐藏页不绘制。`[已实现]`
- 状态：root 与 path 页面保持挂载，隐藏页不接输入/焦点/语义但保留 `@State`、草稿与滚动；非空初始 path 直接恢复深链。`[已实现]`
- 交互与验收：平台返回由宿主删除最后一个 route，组件不消费 Escape；页面标题加 `.navigationTitle` 后，新顶页布局完成即把焦点移到 heading 且不显示键盘环；过渡 settle 前的第二次 path 变化被拒绝并写回上一次接受的栈。`NavigationStackTests` 覆盖 push/pop 保留 root、深链、多页可见性、标题焦点与过渡去重；Gallery `navigationStack` 提供真实 push/back 与草稿。`[已实现]`，API 见 [NavigationStack](navigationstack.md)。

**AppBar / NavigationBar**

- 外观：48pt 基线、44pt 命中、bodyStrong 单行省略标题与 ghost 返回；实际容器 <600pt 最多一个操作，其他宽度最多三个，剩余操作复用 Toolbar / Menu；宽模式可见副标题。`[已实现]`
- 交互与验收：Tab 返回 → 操作 → 更多，菜单键盘与焦点还原、禁用清理、完整 heading / tooltip / 展开态；宿主安全区消费一次。`AppBarTests`、`SingleLineTextTests`、`NativeAccessibilityTests` 与 Gallery `--component appBar` / 三预览覆盖宽度、字号、输入、主题、RTL 与真实 AI 查询。平台原生角色边界见 [AppBar](appbar.md)。

**Sidebar**

- 外观：图标槽 + 标题 + 徽标；行高 ≥ 38；header/footer/滚动区各自边界。`[已实现]`
- 手机 / 紧凑：独立 `NavigationDrawer` 复用 Sidebar 目的地，打开时焦点进入、Escape 关闭、关闭后焦点还原；项行高 ≥ 44pt，支持左滑关闭。`NavigationRail` 和 `SidebarPresentation.rail` 提供轨道形态并保留按钮/焦点；`AdaptiveSidebar` 按实际容器宽度自动切换常驻栏、Rail 和抽屉，并支持可选触摸边缘唤出。`[已实现]`
- 平板 / 桌面：常驻分栏；图标/徽标/文字全部可见，`TextScaler` 200% 可用。`[已实现]`
- 交互与验收：方向键/Home/End 循环、Enter/Space 选择、选中显露、辅助功能完整标题 + 选中/禁用 + 徽标 value。跨形态保留页面、槽位、滚动和展开会话。验收：`--component sidebar`、`NavigationStateTests`、`AdaptiveSidebarTests` 与 Gallery `AdaptiveShellTests`。

**Toolbar**

- 外观：单行非换行容器，最小高度按控件；分隔线与分组。`[已实现]`
- 手机：`Toolbar(items:)` 按调用方优先级把次级命令收进“更多”菜单；`.always` 主命令保留，命令和更多入口 ≥ 44pt；图标按钮保留完整名称，不 shrink 到不可点。`[已实现]`
- 平板 / 桌面：单行完整命令；Left/Right/Home/End 在 toolbar 内移动焦点（`.bubble`）。`[已实现]`
- 交互与验收：辅助功能 role=toolbar、组 role=group、禁用整条阻断命中并关闭菜单；溢出菜单复用 Menu 契约，尺寸变化保持节点并交接焦点。验收：`ToolbarOverflowTests`、`--component toolbar` 的窄/宽/触摸预览；API 与自定义内容边界见 [Toolbar](toolbar.md)。

**Breadcrumb / Pagination**

- 外观：Breadcrumb 超过 `maxVisibleItems`（默认 4）折叠中段为"…"菜单；Pagination 用兄弟窗口 + 省略 gap。`[已实现]`
- 手机：Breadcrumb 保留首尾与"…"入口；Pagination 保留当前页、首尾与前后按钮，省略中段；命中 ≥ 44pt。`[部分]`（折叠策略已实现；触摸尺寸与窄宽取样需补）
- 平板 / 桌面：完整路径与页码窗口。`[已实现]`
- 交互与验收：菜单/按钮键盘与辅助功能；验收：`--component breadcrumb|pagination`。

**Accordion / DisclosureGroup**

- 外观：标题行 + chevron + 内容过渡；`DisclosureGroup` 使用同一过渡机制。`[已实现]`
- 手机：标题单行截断、内容自然换行；行命中 ≥ 44pt；展开内容不把父容器撑出可视区（外层滚动）。`[部分]`
- 平板 / 桌面：`TextScaler` 200% 可操作；roving focus。`[已实现]`
- 交互与验收：单一 Tab 停靠 + 方向键；辅助功能暴露 expanded；验收：`--component accordion|disclosure`、`NavigationStateTests`。

**Carousel / StatusBar**

- 外观：Carousel 页容器 + 可选箭头/指示点，页高由调用方定；StatusBar 统一 26pt 高度、单元格等高等宽策略。`[已实现]`
- 手机：一页一屏、滑动一页/次；箭头 ≥ 44pt；StatusBar 单元格单行截断 + 完整语义，不允许因窄改变窗口内容高度。`[部分]`
- 平板 / 桌面：方向键/Home/End 导航；hover 箭头。`[已实现]`
- 交互与验收：滑动 vs 点击不冲突（滑动取消按压）、辅助功能页标签 + 选中；验收：`CarouselStory`、`StatusBarStory`。

**CommandPalette**

- 外观：搜索行 + 结果列表 + 快捷键提示；桌面几何 640×440；结果经 `VariableVirtualStack` 只挂载视口 + overscan。`[已实现]`
- 手机：compact 下宽 `viewport − 16`、高 `min(560, viewport − 16)`，`inset 8` 居中；结果行触摸 ≥44pt、header 36pt，指针保持 36/28。`[部分]`（几何与行高已完成；软键盘出现后的结果区收缩仍由宿主 IME/安全区处理）
- 平板 / 桌面：640×440、顶部放置、键盘上下移动。`[已实现]`
- 交互与验收：Up/Down/Enter/Escape、前缀过滤、辅助功能 button 行 + 快捷键组；1000 条结果只挂载 <60 行，`scrollToIndex` 跟随 highlight；验收：`CommandPaletteAdaptiveTests`（390 触摸 / 1280 指针几何与行高）、`--component commandPalette`、`ProductInteractionRegressionTests.commandVirtualization` + 200% 行预算测试。

### 3.6 浮层与反馈面

**MenuButton**

- 外观：secondary 按钮触发器 + Popover 菜单；触发器保留 hover/press/focus/disabled 与 expanded 语义，菜单复用 Menu 的材质、行高和滚动。字符串标题单行省略，完整名称留在 accessibility label，可选 `tooltip:` 提供全文。`[已实现]`
- 手机：触发器与菜单行沿用 44pt 触摸下限；菜单下方不足时由 Popover 翻转/夹紧。`[已实现]`
- 平板 / 桌面：菜单在触发器下方展开；键盘 Enter/Space 打开，Up/Down/Home/End/Enter/Escape 沿用 Menu。`[已实现]`
- 交互与验收：选择菜单项执行一次并关闭；外部点击/再次点击触发器关闭；`MenuButtonTests` 覆盖打开、执行、关闭与禁用；Gallery `--component menuButton`。细节见 [MenuButton](menubutton.md)。

**SplitButton**

- 外观：主 secondary 按钮 + 相邻 MenuButton 箭头；主/备两区独立命中、禁用同步，菜单复用 MenuButton 的 Portal 与键盘导航。`[部分]`
- 手机：主/箭头均沿用 44pt 触摸下限；主按钮填充剩余宽度，箭头自然宽度。`[已实现]`
- 平板 / 桌面：主按钮执行默认动作，箭头打开菜单；菜单在锚点下方展开。`[已实现]`
- 交互与验收：主/箭头各自独立 Tab 停靠与键盘激活；当前尚未实现“Tab 一次进入整体 + 左右分区”的单一焦点和共享 1px 分隔 chrome。`SplitButtonTests` 覆盖主/备动作与禁用；Gallery `--component splitButton`。细节见 [SplitButton](splitbutton.md)。

**Menu / ContextMenu**

- 外观：Portal 浮层、独立宽度、行高随文字、子菜单独立 Portal；窗口边界夹紧，下方不足翻上、左右翻转。`[已实现]`
- 手机：行高 ≥ 44pt，`maxVisibleRows` 预算使用触摸下限，子浮层继承来源 surface 的输入环境。`[已实现]`；菜单宽 ≤ 窗口 − 24、长标题换行或截断策略一致、触摸不依赖 hover 展开子菜单（点击展开）。`[部分]`（翻转与夹紧已实现；触摸展开需补验收）
- 平板 / 桌面：hover 180ms 展开子菜单、前缀查找、快捷键列。`[已实现]`
- 交互与验收：Up/Down/Home/End/Right/Left/Escape/Enter/类型查找；辅助功能逐行 role、禁用与选中态。验收：Menu 测试族、`--component menu|contextMenu`。

**Popover / HoverCard / Tooltip**

- 外观：Popover 锚定 + 启动对齐；HoverCard 300 宽；Tooltip 自然宽度 ≤ 320、450ms 延迟、键盘焦点同样触发。`[已实现]`
- 手机：Tooltip/HoverCard 不作为信息唯一入口（触摸无 hover），等效信息必须在内容内或点击可达；浮层宽度 ≤ 窗口 − 24。`[部分]`（等入口由内容保证；宽度已夹紧）
- 平板 / 桌面：hover 触发、指针移出关闭、Escape 关闭。`[已实现]`
- 交互与验收：辅助功能 help / 可读文本；焦点与 Escape 行为一致；验收：Tooltip 测试族、`--component tooltip|hoverCard|popover`。

**Modal / Dialog / AlertDialog / Sheet**

- 外观：Modal 居中、默认 760×560、inset 16；Dialog header/body/footer；AlertDialog 420×240；Sheet 沿边、extent 默认 400。`[已实现]`
- 手机：对话框占满窗口宽（减 16pt）、按钮纵向排列且 ≥ 44pt；Sheet 的 bottom 呈现等价于底部抽屉并占满宽度；内容区滚动。`[部分]`（占满/纵向按钮未实现；Sheet 已占满对应边）
- 平板 / 桌面：居中模态、Sheet 侧边抽屉。`[已实现]`
- 交互与验收：焦点进入并循环、Escape/背景按配置关闭、关闭后焦点还原、禁用不打开；辅助功能 role=dialog + label/help。验收：Modal/Sheet 测试族、`--component modal|dialog|alertDialog|sheet`。

**BottomSheet**

- 外观：全宽拖拽柄（44pt 命中 / 36×4 视觉）、detent 高度档位、内容区；复用 Modal 的 backdrop、焦点与 Escape。`[已实现]`
- 手机 / 平板：compact/medium 贴底全宽；向下拖超过位移/速度阈值关闭，第一档之上先退档；向上拖进入下一档；内容不接拖拽。`[已实现]`
- 平板 / 桌面：expanded 表面退化为居中面板（`dialogWidth` 默认 560、`dialogInset` 16）；仍保留 detent 高度。`[已实现]`
- 交互与验收：关闭后焦点还原；释放无惯性尾段，reducedMotion 安全；辅助功能 handle label `Resize sheet`，内容 role=dialog。`BottomSheetTests` 覆盖关闭、展开与宽屏退化；Gallery `bottomSheet` 页提供真实拖拽。细节见 [BottomSheet](bottom-sheet.md)。

### 3.7 展示与反馈

**Text / Typography / Icon**

- 外观：语义角色 display/title/headline/body/bodyStrong/caption/label/mono；图标默认跟随 `TextScaler` 一次。`[已实现]`
- 手机：正文换行；单行标签按第 1 节截断规则；图标不缩到失去辨识度，`iconScaling` 提供固定策略。`[已实现]`
- 平板 / 桌面：与 `TextScaler` 200% 组合验收。`[已实现]`
- 交互与验收：截断文本的完整值进入 tooltip 与辅助功能；验收：`--component theme`（Typography 段）、`NavigationStateTests` 200%。

**Image / AsyncImage / Avatar**

- 外观：fit/fill/stretch；加载/失败/空阶段由调用方呈现；Avatar 尺寸 mini–large 12–512、首字母回退。`[已实现]`
- 手机：图片不因窄而放大像素；裁剪保持中心；头像 fallback 图标/首字母不溢出容器。`[已实现]`
- 平板 / 桌面：继续按 DPI 取物理尺寸；hover 不改变几何。`[已实现]`
- 交互与验收：图片失败必须给出占位与重试路径；头像暴露完整姓名 image 语义；验收：Image/Avatar 测试族、`--component image|avatar`。

**Badge / Tag / KeyCap / Label**

- 外观：非交互装饰，尺寸随语义字号。`[已实现]`
- 手机：不因窄而截断语义文本；长文本换成多行或由调用方收敛，不允许静默丢字。`[部分]`
- 平板 / 桌面：hover 无状态变化（非交互除外）。`[已实现]`
- 交互与验收：装饰性内容 `accessibilityHidden`，语义值并入宿主；验收：`--component badge|tag|keyCap|label`。

**Alert / Progress / Notification / Skeleton / Empty**

- 外观：反馈组件不参与布局竞争，按自身尺寸呈现；Skeleton 保持最终内容几何。`[已实现]`
- 手机：Alert 宽 ≤ 窗口 − 32、操作按钮 ≥ 44pt 且可纵向堆叠；Notification 单行标题 + 换行正文；Empty 自然居中。`[部分]`
- Notification / Toast：队列、稳定 ID 替换、时长与 hover 暂停；最多两个内联操作（撤销/重试），操作是真实按钮、键盘可达；`.automatic` 定位在 compact 底部、medium/expanded 右上，并计入宿主 `safeArea`。`[已实现]`，细节见 [Toast](toast.md)。
- 平板 / 桌面：inline alert 与窗口宽度自适应。`[已实现]`
- 交互与验收：Progress 暴露数值语义；Alert 操作键盘可达；验收：`--component alert|progress|notification|skeleton|empty`。

## 4. 验收方法

### 4.1 取样矩阵

每个控件与容器至少覆盖以下组合；结论必须能指向具体命令或测试名。

| 维度 | 取值 |
| --- | --- |
| 宽度 | 390（compact）、720（medium）、1280（expanded） |
| 输入 | touch-only；touch + pointer + keyboard；pointer + keyboard |
| 文本缩放 | 100% 与 200%（Gallery 工具栏 100–200% 可调） |
| 主题 | light 与 dark |
| 安全区 | 非零（手机竖屏与横屏各一组） |
| 动效 | 默认与 reducesMotion |

### 4.2 启动与取样

```sh
# 桌面：直接打开某一页；名称大小写不敏感，接受 rawValue 或标题
swift run --package-path GuavaUI/Examples GuavaUIDemo --component textField
swift run --package-path GuavaUI/Examples GuavaUIDemo --component layout --performance-hud

# iOS 模拟器 / 真机
./guava run GuavaUI/Examples --ios --simulator UDID
./guava run GuavaUI/Examples --ios --device UDID --team TEAM_ID

# Android（设备/模拟器；同一组故事与组件）
guava showcase gallery --android --component NAME
```

- 宽度取样：把窗口/模拟器设为 390 / 720 / 1280 逻辑宽度；已接入 `AdaptiveControlExamples.supports` 的页面在故事底部自动附带 `adaptive-<page>-narrow | -wide | -touch` 三组预览（390 指针、720 指针、390 触摸），包括 Toolbar，其余页面以窗口或单元测试取样。预览不覆盖 1280pt 和混合输入，仍需按第 4.1 节补齐测试。
- 输入取样：桌面默认指针 + 键盘；触屏设备默认触摸 + 键盘；混合形态（平板 + 触控板）另行验证 hover 与 44pt 并存。
- 性能基线：`--benchmark [--no-vsync]` + `GUAVA_FPS_LOG=1`；滚动与输入不得因重排产生持续重组（`graph.recomposer.hasPending == false`）。

### 4.3 自动化

| 范围 | 入口 |
| --- | --- |
| 全部页面在 light/dark、1280×820 物化且无重叠 | `swift test --package-path GuavaUI/Examples`（`GalleryTests`） |
| 触摸 44pt 族、密度恢复、hover gating | `GuavaUI/Tests/GuavaUIComposeTests/TouchDensityTests.swift` |
| Tree / Table / DataTable / Menu 行高、节点与选择保留、翻页/编辑、子浮层环境 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/RowDensityTests.swift` |
| List / Table / DataTable / LazyGrid 字号缩放一次、行间距、前缀索引与滚动边界 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/TextScaleRows.swift` |
| Form / PropertyGrid 标签、列数、编辑状态与 AI 诊断定位 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/FieldLayoutTests.swift` |
| Toolbar 优先级、菜单、密度与焦点交接 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/ToolbarOverflowTests.swift` |
| Table / DataTable 列优先级、显隐、排序、编辑迁移、会话和 AI 查询 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/TableColumnsTests.swift` |
| Grid 列优先级、源行槽位、草稿、附属浮层、菜单、滚动与 AI 查询 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/GridColumnsTests.swift` |
| Calendar 月内首尾/翻月、日期限制、实际焦点、禁用与 DatePicker 提交 | `GuavaUI/Tests/GuavaUIComposeTests/Calendar/KeyboardNavigationTests.swift` |
| TabView compact 换边且保留面板状态 | `AdaptiveNavigationTests.swift` |
| TabView 菜单、隐藏项焦点、三种模式截断、极窄布局与 AI 查询 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/TabOverflowTests.swift` |
| 宽度类与 `minimumControlExtent` | `AdaptiveEnvironmentTests.swift` |
| 高度类、方向与 viewport reader | `ViewportTraitsTests.swift` |
| 滚动区域位置/角色与 comboBox | `AccessibilitySemanticsTests.swift` |
| 可聚焦滚动条 thumb | `ScrollbarTests.swift` |
| 菜单触摸子菜单 | `MenuHierarchyTests.swift` |
| ViewThatFits 分支状态保留 | `ViewThatFitsTests.swift` |
| 容器查询发布与阈值 | `ContainerQueryTests.swift` |
| Android 设备逐页启动 | `guava-dev android gallery`（页面名直接来自 `GalleryCatalog.swift`） |
| 通用回归 | `swift test --package-path GuavaUI` |

新控件进入验收的门槛：

1. 加入 `GalleryCatalog`，并提供至少一个可交互故事；
2. 可交互控件必须出现在 `AdaptiveControlExamples.supports`（或提供等价的窄/宽/触摸预览），并保持 `adaptive-<page>-narrow|wide|touch` debugName 约定；
3. 为第 3 节的触摸、键盘、辅助功能条目各提供至少一条测试；无法自动化的真机行为按第 3 节标注"真机验收"并记录；
4. 触摸目标、焦点环、disabled/loading 不误触发、状态保留（重排前后 `@State`/焦点/滚动）必须有断言。

### 4.4 验收记录

- 每条要求记录：测试名 + 覆盖行为 + 平台（宿主 + 输入形态 + 宽度）。
- 原生视觉验收记录截图组合：light/dark × 390/720/1280，加 200% 文本缩放与触摸形态各一组。
- 已知无法在本轮验收的条目必须写入第 5 节，不允许以"设计如此"绕过。

Calendar 键盘导航验收：`CalendarKeyboardNavigationTests` 在 macOS 宿主上覆盖 390pt 触摸 + 键盘、720pt 混合输入、1280pt 指针 + 键盘，验证 Home/End、PageUp/PageDown、日期限制与空月、闰年/月底/跨年/DST、受控多月份窗口、禁用释放焦点，以及 DatePicker 导航不提交、Enter 提交后关闭并恢复触发器焦点。`NavigationStateTests.calendarKeyboard` 验证 Gallery 周末禁用故事。`swift test --package-path GuavaUI` 与 `swift test --package-path GuavaUI/Examples` 均通过；手机真机视觉仍按上述矩阵验收。

## 5. 规范完成清单（按本文验收）

以下条目来自对 `GuavaUICompose` 与 Gallery 的代码复核。截至 2026-10-18，第 5 节清单已全部清空；第 6、10、14、15、16 项的完成证据见本节末尾记录。完整缺失组件与既有组件的其他功能缺口继续由[组件覆盖与缺失清单](gaps.md)跟踪。

第 5 项 TabView 溢出菜单与标题截断已实现：`.menu` 使用实际测量保留所选项与能放下的标签，其余通过 ≥44pt 的 More tabs 菜单可达。隐藏标题保留节点但停止绘制、输入和语义；Roving focus 支持隐藏目标延后聚焦与同帧连续按键。三种 overflow 模式均采用单行省略、完整 tooltip/名称和独立的图标/徽标/关闭槽；必要的非文本空间不足时横向滚动。同类型面板按标签 ID 隔离，条件内容的 ID 在多层修饰下保留正确身份与局部状态。`TabOverflowTests` 验证三档宽度、100%/200%、三种输入、主题、RTL、三种外观、菜单生命周期与真实 AI wire 查询；`TabViewTests` / `StructuralModifierTests` 验证状态隔离、重排与卸载恢复。Gallery `tabs` 及三预览已采用。DevTools 的输入与渲染画面入口见 [AI 诊断闭环](../architecture/agent-framework.md#操作与画面闭环)，验证不依赖操作系统自动化。

AppBar 新组件已完成：共享 Toolbar 命令树、优先级与更多菜单，按实际容器在 1 / 3 个平铺操作之间收敛；标题与文字主操作使用统一的单行省略能力，保留全文及 heading 语义，安全区由宿主消费。组件、菜单和原生角色测试及 Gallery 可交互页已经接入；第 6 项仍保留既有控件的逐项采用工作，不能由 AppBar 的完成代替。

第 4 项已实现：Grid、Table、DataTable 共享 `ColumnVisibility` 与 Columns 菜单，按实际分配移除低优先自动列，支持显隐 binding 和恢复自动模式。Table / DataTable 的必要列、冻结列和活动草稿优先；显隐不改变排序、记录、选择或列宽，隐藏焦点列交接并释放捕获，键盘跳过隐藏列，程序化导航可揭示目标。Grid 命名字段列保留源行槽位、节点与局部草稿，必要 minimum 超宽仍可横向滚动；普通 adaptive 卡片流保持原语义。`TableColumnsTests`、`GridColumnsTests` 覆盖容器/字号/输入/主题矩阵、菜单、会话和经校验的 AI 查询；Gallery 三页均有交互与三预览。初始隐藏单元格输出有限的零几何，隐藏时关闭所属附属浮层；DevTools 的 `get_diagnostics.layoutIssues` 可定位非有限或负尺寸及源码，避免查询只返回 JSON 编码失败。

第 1 项命令工具栏溢出已实现：`Toolbar(items:)` 以实测按钮树分配自然宽度，支持优先级、始终保留、始终溢出及图标命令；隐藏 inline 节点仍挂载但不绘制、不接输入、不暴露语义。`ToolbarOverflowTests` 覆盖三档宽度、100%/200% 字号、三种输入集合、菜单操作、节点保留和焦点交接；Gallery Toolbar 已接入自动预览。自定义任意内容仍由应用显式重排，真机触摸和读屏继续按第 4 节取样。

第 2 项中的 SplitView 单面板部分已实现：`SplitCompactPresentation` 按容器自身轴向长度切换，页签支持完整名称、换行、键盘与触摸；双侧保留节点、本地状态和滚动，折叠不覆盖请求比例，隐藏时交接焦点并取消捕获。分隔柄随输入集合在 7pt / 44pt 命中区间切换。`SplitPresentationTests` 覆盖横纵阈值、三档宽度、100%/200% 文字、明暗主题、三类输入、草稿和滚动保留及卸载重置，并通过 DevTools AI `query_ui_nodes` 验证可见性和输入状态；Gallery 已增加三种预览及 `SplitTests`。设备触摸/读屏仍按第 4 节取样。

第 2 项中的独立 NavigationDrawer 已实现：按实际窗口保留 56pt 外部空间，复用 Sidebar 的选择/显露与激活，提供标题、关闭、焦点约束/还原、独立关闭策略、左滑关闭和可反转的边缘动画。`NavigationDrawerTests` 覆盖窗口变化时节点与草稿保留、完整输入矩阵及生命周期；Gallery 新增独立页/三种预览，Sidebar 页共享选择。验证中补齐 DevTools AI 的模态输入权限与 `input_enabled_only` 筛选，`DiagnosticPresentationTests` 覆盖深层节点、嵌套模态、附属浮层和窗口隔离。统一壳层与可选边缘唤出现已由 AdaptiveSidebar 实现；设备输入取样见组件文档。

第 2 项中的 NavigationRail 已实现：72/56pt 两种形态、2pt 指示条、44pt 行高、受约束的主题图标、完整 tooltip/语义与头尾槽位；`SidebarPresentation` 在同一目的地节点上切换普通栏和 Rail，保留选择、焦点与槽位状态。`NavigationRailTests` 覆盖宽度/字号/输入/主题矩阵、长词换行、模式切换、显露及普通滚动、生命周期与 AI 名称发现；Gallery 新增独立页和三种预览。显露操作补齐重排后的实际滚动范围与目标坐标换算，roving 目标发现使用线性遍历。统一壳层现已由 AdaptiveSidebar 完成。

第 2 项统一壳层已完成：`AdaptiveSidebar` 按容器实际分配在 <600pt 抽屉、600…<1000pt Rail、≥1000pt Sidebar 间切换，同一导航和页面保留节点、草稿、滚动及展开会话。焦点随模态开关和布局交接，关闭立即禁用输入，边缘/左滑遵守输入意图，动画可反转并响应减少动画。`AdaptiveSidebarTests` 覆盖完整宽度/字号/输入/主题矩阵与真实 AI `query_ui_nodes`；Gallery 已接入壳层与换行工具栏，`AdaptiveShellTests` 验证故事、搜索和主题入口，Sidebar 增加三预览。第 16 项已覆盖全部 Gallery 页面；参数和边界见 [Sidebar](sidebar.md#自适应壳层)。

第 3 项表单标签重排已实现：Form / PropertyGrid 共享 `FieldLabelPlacement` 与首选值槽宽度，按容器而非窗口决定标签位置，Form 列数变化只重新放置原字段；属性网格默认使用内在行高，标题与输入遵守缩放和触摸下限。条件/数组经普通 modifier 修饰后不再于首次更新重建用户组件；`StructuralModifierTests` 验证状态保留及卸载默认值。`FieldLayoutTests` 同时通过 AI 诊断 facade 查询可读字段名称与实际几何，防止只修视觉而遗漏语义。设备输入取样仍按第 4 节验收。

第 7 项列表族文本缩放已完成：List、Table、DataTable、LazyGrid 自动解析字号后的行高，表格表头与 List/LazyGrid 行间距同步缩放；Table 把 authored 高度交给内部 List，避免二次缩放。LazyGrid 的可变行高复用前缀索引，Gallery 100K 示例已移除手动缩放。`TextScaleRowTests` 在 macOS 宿主上覆盖 390/720/1280pt、light/dark、100%/125%/200%、触摸/混合/指针输入、选择与焦点保留、部分末行、缩放恢复的滚动夹紧以及 DataTable 翻页/末行/冻结列对齐；`NavigationStateTests.lazyGridTextScale` 验证 Gallery 100K 示例在 200% 下实际行高为 96pt、视口仍为 240pt。`swift test --package-path GuavaUI` 与 `swift test --package-path GuavaUI/Examples` 均通过。原生设备视觉仍按第 4 节矩阵验收。

第 8 项触摸行高已完成：`RowDensityTests.collectionRows` 在 macOS 宿主上覆盖 390/720/1280pt、touch-only、touch + pointer + keyboard、pointer + keyboard，验证 36/56pt authored 行高、44pt 下限、节点与选择保留、单元格/展开按钮命中及密度恢复；`dataTableNavigation` 验证触摸翻页、末行显露、冻结列对齐与 44pt 编辑器；`scaledRows` 覆盖 Tree/Menu 的 100%/200% 文本缩放与 light/dark；`menuRows` 验证嵌入表面的菜单及子浮层继承输入环境、行底部点击展开与键盘关闭。`swift test --package-path GuavaUI` 与 `swift test --package-path GuavaUI/Examples` 均通过。设备视觉与系统触摸派发仍按第 4 节真机矩阵验收。

第 17 项动画曲线扩展已完成：`AnimationCurve` 新增 `steps(_:position:)`、`piecewiseLinear(LinearTimingCurve)`、`bounceOut` 与 `elasticOut`；`CurveTests` 在 macOS 宿主上覆盖端点与非法时间、阶梯边界跳变与单调性、折线平台/反向/过冲与极端 progress、弹跳撞击连续性与递衰、弹性过冲与衰减、延迟/精确终值/调度清理。Gallery `--component animation` 新增可交互 `AnimationCurveExamples` 双向尺寸动画（`animation-curve-choice-*`、`animation-curve-play`、`animation-curve-bar`），`AnimationTests` 覆盖 390/720/1280pt、light/dark、双向播放、减少动画立即吸附与禁用状态；同时补齐通用 `animatableSet` 在减少动画下吸附终值并取消在飞控制器（`ReducedMotionEnvironment` 键下沉到 `GuavaUIScene`，Compose 侧只保留 `.reducedMotion()` 修饰器）。`swift test --package-path GuavaUI`、`swift test --package-path GuavaUI/Portable` 与 `swift test --package-path GuavaUI/Examples` 均通过。真机视觉仍按第 4 节矩阵验收。

第 18–21 项动画能力已完成：几何弹簧可显式过冲并继承实际值速度，通用 `springDrag` 提供带速度释放；新增关键帧、普通域相位、有限 / 无限循环、共享位置尺寸和数值过渡；完成组区分名义期限与物理尾部，并处理取消、卸载、减少动画和布局后登记。Button、Toggle、菜单、加载指示与 Gallery 已应用。API、适用边界和测试入口统一记录在 [动画系统](animation.md)。

第 11–12 项窄宽重排已完成：`Stepper` 按每步 148pt 加 24pt 连接段的横向预算在宽/窄两套 retained 分支间切换，窄分支纵向堆叠，Left/Right 停止导航、Up/Down 生效；`StepperOptions.minimumHorizontalStepWidth` 供长标题调用方提高预算。开发中的 390pt DevTools 实测发现，原地把同一 `Box` 从 `.row` 改成 `.column` 会让 Yoga 沿用旧行高、把步骤压成 0pt；改为 `ViewThatFits` 的两套稳定布局树后，步骤恢复 56pt 行高。`ButtonGroup` 改用可换行 flex line，段宽与 44pt 触摸高度保持；`Vec3Field` 以 96pt 基准和 88pt 最小轴宽换行，窄宽下 X/Y 一行、Z 下一行。`NarrowReflowTests` 在 390/720pt、触摸输入下验证堆叠/单行几何、换行位置、44pt 段高与轴感知键盘。Gallery `stepper`、`buttonGroup`、`vec3Field` 页与自适应预览已更新；DevTools `query_ui_nodes` 实测 390pt 步骤为 y=446/526/606 × 56pt，720pt 为同一 y=294、x=102/302/502；ButtonGroup 260pt 五段换行；Vec3Field 390pt 的 X/Y 同 y=409、Z y=437，720pt 全宽 X/Y/Z 同 y=277。`capture-ui` 截图确认纵向连接线、分段换行与 Vec3 的 X/Y→Z 排布。

CommandPalette compact 几何已完成：`SurfaceReader` 读取 surface 尺寸与输入，compact 下使用 `viewport − 16` 宽、`min(560, viewport − 16)` 高、8pt inset 并居中；触摸面结果行取 `max(36, minimumControlExtent)`、header 36，指针保持 36/28。`CommandPaletteAdaptiveTests` 在 390pt 触摸面断言 374×560 panel 与 44pt 行，在 1280pt 指针面断言 640×440 与 36pt 行。DevTools 在 390×820 真机窗口中打开 Gallery `commandPalette`，`query_ui_nodes` 的 `role=dialog` 返回 374×560、位置 (8,130)，`capture-ui` 确认搜索行、结果区与 footer 均在窗口内；宿主默认指针输入下现场行高为 36，触摸 44pt 由单元测试覆盖。软键盘出现后的结果区收缩仍由宿主 IME/安全区处理。

Select 弹层宽度与行高已完成：触发器继续单行截断并保留完整辅助功能值；弹层复用 Menu 的 `MenuWindowBounds` 与 `MenuRowMetrics`，宽度不小于触发器、由 Portal `viewportMargin` 夹紧在窗口 − 24 内，行高按指针 32 / 触摸 44 取最大值，长选项自然换行增高。DevTools 在 390×820 打开 Gallery `select`：触发器 286pt，弹层宽 346pt、x=32、右边界 378（窗口 390，右/左各 12pt），行高 32 为宿主指针面；触摸 44pt 由 `RowDensityTests.menuRows` 覆盖。`capture-ui` 确认长选项与禁用项都在窗口内。第 10 项剩余 Sheet 底部呈现与菜单触摸展开子菜单验收。

第 13 项焦点环已统一：Toggle 的开关/复选框自绘路径与 Slider/RangeSlider 的 `SliderStyleConfiguration` 都改为 `focused && isFocusVisible`，与 Button-based 样式、Rating 和表格头共用同一键盘可见性来源。`FocusRingTests.customDrawnControlsFollowFocusVisibility` 直接渲染 Toggle/Slider/RangeSlider 的 DrawList，断言指针焦点时没有 `focusRing` 顶点、键盘焦点时存在；既有 Button ring 测试继续覆盖样式路径。DevTools 在 720×820 Gallery `toggle` 点击 Notifications 后数值翻转、焦点目标移动，但 `capture-ui` 与点击前像素一致（无环）；键盘环由渲染顶点断言覆盖。

列表重排已完成：`ReorderableList` 在行尾提供 44pt handle，指针拖动期间以 2pt accent 放置线标记目标边界，释放后只调用一次 `onMove(from, to)`；Escape 取消、聚焦 handle 后 Up/Down 以及辅助功能 increment/decrement 走同一移动路径。根节点提供 flex 布局节点并从实际 ScrollView viewport 读取内容宽度，避免内容按 handle 的固有宽度收缩。`ReorderableListTests` 覆盖指针放置线与单次移动、键盘/辅助功能移动并保持焦点、Escape 取消、触摸 44pt handle。Gallery `reorderableList` 页与自适应预览已接入；DevTools 在 720×820 上从 Main Camera 的 handle（x=618）下拖 72pt，截图确认 “Moving” 行与 2pt 放置线，释放后顺序查询为 `Key Light → Main Camera → Player → Ground → Trigger → Audio Source`。当前为非虚拟列表，视口边缘自动滚动仍待补。

NavigationStack 已完成：`NavigationStack(path:root:destination:)` 以 caller-owned `[Route]` 为栈，root 与 path 页面通过 `AnimatedVisibility(retainsContent:)` 保持挂载，隐藏页不进入命中/焦点/辅助功能树；push 时新页从 trailing 滑入并淡入、旧页向 leading 滑出，pop 时新顶页反向显露。非空初始 path 首帧恢复深链；`ContainerSizeReader` 把页面固定到实际容器尺寸。页面标题加 `.navigationTitle` 后，新顶页布局完成即把焦点移到 heading（`visible:false`，无键盘环）；过渡 settle 前的第二次 path 变化被拒绝并写回上一次接受的栈。`NavigationStackTests` 覆盖 push/pop 后 root 草稿保留、深链、多页仅顶层可见、标题焦点与过渡去重。Gallery `navigationStack` 页与自适应预览已接入；DevTools 在 720×820 点击 `Open details` 后查询到 Details（`role=heading`）与 `Path: details`，点击 Back 后 root 草稿仍为 “Draft kept across push and pop”。平台返回手势由宿主删除最后一个 route；该边界已记录在 [NavigationStack](navigationstack.md)。

列表滑动操作已完成：`SwipeList` 在触摸面左滑露出最多两个 74pt 宽、行高 ≥44 的 trailing 操作；横向阈值 8pt，纵向手势仍交给 `ScrollView`。`ScrollView` 的触摸拖动改为轴感知阈值，避免垂直滚动抢占横向滑动。行尾 44pt Actions 按钮展开同一组操作，右键上下文菜单为指针等价入口；行选择、键盘 Up/Down/Home/End/Return 与辅助功能 activate 走 `SelectionKeyHost`。`SwipeListTests` 覆盖触摸滑动与 44pt 操作、Actions 按钮非滑动路径、纵向滚动不误触、禁用态与指针面不响应滑动。Gallery `swipeList` 页与自适应预览已接入；DevTools 在 720×820 点击 Inbox 行 Actions 后查询到 Archive（74×52）和 Delete，执行 Archive 后 `swipe-log` 为 “Archived Inbox”。当前为全量挂载的非虚拟列表，RTL 滑动方向仍待补。

列表下拉刷新已完成：`List`/`VirtualStack` 的 `RefreshOptions` 在 `ScrollView` 负向 overscroll 越过阈值时只触发一次；`isRefreshing` 控制顶部 36pt inset 与指示器，清除后内容回弹。指示器使用 `Spinner`，reducedMotion 下冻结；Cmd+R/Ctrl+R 在列表子树内触发同一 action。`ScrollView` 仍保持原始根节点，指示器以绝对定位放进滚动内容，因此列表宽度不被包装层压缩。`RefreshTests` 覆盖触摸下拉只触发一次、指示器保持到绑定清除、Cmd+R 与重复按键去重。Gallery `refreshableList` 页与自适应预览已接入；DevTools 在 720×820 点击 `Refresh now` 后查询到 `Refreshing`，计数变为 `Refreshes: 1`，3 秒后指示器移除且列表恢复宽度 548pt。触摸下拉的宿主实测受 DevTools pointer 输入限制，由单元测试覆盖。

第 6 项控制标题截断已完成：`Button`、`Link`、`MenuButton` 的字符串入口与 `DatePicker` 触发标题统一使用 `Text.truncatingTail()`；Button/Link 默认把完整标题作为 tooltip，MenuButton 可通过 `tooltip:` 把完整标题放入 trigger description，DatePicker 的标题额外附加完整 tooltip。`Select`/`Combobox` 原有单行省略与 trigger description 保持不变；菜单项仍按文档自然换行，不属于控制标题。`TruncationTests` 在 150/170pt 约束下验证 button/link/menu/date 标题 `clipsToBounds` 且辅助功能名称完整。Gallery `button` 页新增 “Long labels” 分区与 `long-button`/`long-link`/`long-menu`/`long-date`；DevTools 720×820 查询到标题文本宽 126/146/125/158pt，悬停后 portal 中出现完整 234pt tooltip。

第 15 项的高度类/方向读取已完成：`UIEnvironment.Viewport` 新增 `heightClass` 与 `orientation`，阈值与宽度类一致（600/1000），方形归 landscape；`HeightClassReader`/`OrientationReader` 从 `SurfaceEnvironment` 读取并驱动壳层内容，不额外测量。`ViewportTraitsTests` 覆盖 599/600/999/1000 边界、方形与横竖屏切换，以及 reader 在 1280×720 → 390×500 → 1200×1100 变化下的重算。Gallery `viewportTraits` 页与 README 入口已接入；DevTools 在 720×820 实测 medium/medium/portrait，390×820 实测 compact/medium/portrait，1200×842 实测 expanded/medium/landscape。

第 15 项的内在内容拟合已完成：`ViewThatFits(fitting: .intrinsic)` 在 unspecified 宽高下测量 wide 分支，只有自然宽高都放得下时才选 wide，否则选 compact；`threshold:` 初始化保持原行为。intrinsic 模式立即挂载两套分支以便测量，隐藏分支通过 `LayoutSubview.place(isVisible:false)` 停止绘制/输入/语义并释放焦点与捕获，两套分支的节点与 `@State` 均保留。`ViewThatFitsTests.intrinsicFitting` 覆盖 200/100pt 切换、隐藏分支不可交互、状态往返保持。Gallery 新增 `viewThatFits` 页；DevTools 720×820 截图确认 wide 行与 compact 列，按钮在 520/180pt 提案间切换。

第 14 项的滚动位置、选择角色、described-by 与可聚焦 thumb 已完成：`ScrollView` 暴露 `.scrollArea` 语义，`accessibilityLabel` 可命名，value 按实际 offset/maxOffset 输出百分比，help 提供键盘滚动提示，辅助功能 increment/decrement 每次滚动约一页；`Select`/`Combobox` 触发器改用 `.comboBox` 角色，保留当前值 label/value 与 `isExpanded`。macOS 原生桥新增 `scrollArea`/`comboBox` 角色映射。独立 `Scrollbar` companion 提供 `.slider` thumb：拖动、方向键/Page/Home/End、increment/decrement、`setValue` 与 focus ring；与 ScrollView 绑定同一 offset。`AccessibilitySemanticsTests` 覆盖滚动语义、comboBox 与 describedBy；`ScrollbarTests` 覆盖键盘/辅助功能/拖动/几何。DevTools 在 `button` 页验证 describedBy help，在 `scrollView`/`select` 页验证角色与位置，在 `scrollbar` 页拖到底得到 `value=100%`、`Offset: 220`，PageUp 回到 0%。`Scrollbar` 是 companion，ScrollView 内建 chrome 不自动叠加；该边界已记录在 [Scrollbar](scrollbar.md)。

第 16 项 Gallery 预览覆盖已完成：`AdaptiveControlExamples.supports` 覆盖全部 92 个 Gallery 页面，每页生成 narrow/wide pointer 与 narrow touch 三档；新增 multiSelectList、scrollbar、viewportTraits、viewThatFits、dragAndDrop、menuButton、tooltip、link、badge、tag、keyCap、progress、empty、skeleton、accordion、datePicker、icon、avatar、panel、scrollView、statusBar、carousel、breadcrumb、pagination、radio、timeline、tree、virtualList、virtualStack、chart、boundedScroll、label、disclosure、alert、textArea、colorField、jsonField、assetRef、dateRangePicker、timeField、theme、codeEditor、menu、contextMenu、popover、modal、dialog、alertDialog、sheet、bottomSheet、commandPalette、hoverCard、animation、introduction、image、workspace、notification，并按页面设置预览高度。DevTools 在 scrollbar/timeline/tree/colorField/dialog 等页验证三档容器物化（如 adaptive-dialog-touch 为 390×104）；`swift test --package-path GuavaUI/Examples` 27/27。

第 10 项浮层自适应已完成：`BottomSheet` 在 compact/medium 贴底全宽、expanded 退化为 `dialogWidth` 560 的居中面板，detent 与拖拽关闭沿用既有 Modal 契约；`MenuHierarchyTests.touchSubmenu` 新增 390pt 触摸面用例，点击父行直接打开子菜单并执行叶子。DevTools 在 390×800 测得 dialog 390×280、y=520，1280×840 测得 560×280、x=360/y=280；`capture-ui` 确认贴底与居中两种呈现。触摸子菜单无 hover 依赖，Portal 层级、焦点与展开语义保持。

P1 通用拖放已完成：`DragScope` 持有类型化会话，`Draggable` 在 6pt 位移后夺取捕获并投射 Portal 预览，`DropTarget` 按 payload 类型与最深命中节点接收 drop，`onTargeted` 提供 hover 高亮；外部释放与类型不匹配不触发回调。`DragAndDropTests` 覆盖匹配 drop、外部取消与预览生命周期；Gallery `dragAndDrop` 页与 README 入口已接入；DevTools 720×820 将 Camera 拖入 Lane A 后查询到 `A: Camera · B: empty`。该协议不提供自动滚动或键盘重排，集合重排继续使用 `ReorderableList`。

列表 sticky 区段已完成：`SectionedList(stickyHeaders: true)` 观察真实 `ScrollView` offset，按 `entryIndex × (已缩放行高 + 行距)` 解析当前区段；原 header 行滚出顶部后由固定副本接替，下一 header 进入标题高度范围时把它上推，到达顶部后完成交接。固定副本通过 `ContainerSizeReader` 取得列表实测宽度，覆盖行内容区并物理左对齐，保留右侧 12pt 稳定滚动条槽；底部 1pt 分隔线不改变行高。它关闭命中、隐藏语义，原 header 行仍是唯一语义来源。`SectionedListTests.stickyHeaders` 覆盖首段固定与宽度、上推 15pt、区段交接、边界处仅一份语义，以及 End 程序化显露后的跟随；`stickyHeadersDisabled` 验证默认关闭。Gallery `sectionedList` 页改为三段可滚动列表；DevTools 用 `input-ui` 滚动条拖动后，`query_ui_nodes` 返回固定 `Scene` 条带位于列表顶部（548×30、`hasBackground=true`、`inputEnabled=false`），`capture-ui` 截图确认左对齐、滚动条槽完整与底部半露行被分隔。重排、swipe 与下拉刷新均已实现，边界见 [缺失清单](gaps.md#29-列表能力包p1)。

## 6. 动效与动画（动画效果实现）

分两类：**时间曲线**（用 `cubic-bezier` / ease 控制"速度怎么变"）与**物理动画**（弹簧、阻尼、惯性模拟真实运动）。GuavaUI 的实现层与 SwiftUI 同形：`withAnimation`、`.animation(_:value:)`、`AnimatedVisibility` + `Transition`、`Animation.spring(response:dampingFraction:)`，再加滚动的系统惯性与回弹。本章定义效果选型、参数与验收；[已实现] 等标注同前。

### 6.1 两类动画与"拟合"边界

- **时间曲线**：总时长内进度 = `f(t)`，可预算、可导出（CSS / SwiftUI / Flutter 通用）。GuavaUI 对应 `Animation(duration:curve:delay:)`。`[已实现]`
- **物理动画**：无固定时长，可中断、可继承速度。GuavaUI 对应 物理 spring controller、`springDrag` 与 `ScrollPhysics`（rubber band、系统 momentum、settle spring）。`[已实现]`
- **拟合不是物理**：把弹簧导出成 Bezier 或 CSS `linear()` 多点曲线只是看起来接近，不能实时响应中断、继承速度。拖拽释放、连续反馈用物理路径，不要用拟合曲线代替。`[已实现]`（`springDrag(offset:restingAt:spring:)` 负责实际释放速度与重新抓取）

### 6.2 缓动曲线：效果与实现

| 名称 | cubic-bezier | 效果 | 常用场景 | GuavaUI | SwiftUI / Flutter |
| --- | --- | --- | --- | --- | --- |
| linear | (0,0,1,1) | 匀速、机械 | 进度条、旋转 loading、循环 | `Animation.linear`、`AnimationCurve.linear` | `.linear` / `Curves.linear` |
| ease | (.25,.1,.25,1) | 轻微慢起慢收（CSS 默认） | 通用 | 无同名预设，写 `cubicBezier(0.25,0.1,0.25,1)` | `.easeInOut`、`Curves.ease` |
| ease-in | (.42,0,1,1) | 慢起、越来越快 | 退出、消失 | `Animation.easeIn`（二次近似） | `.easeIn` / `Curves.easeIn` |
| ease-out | (0,0,.58,1) | 快起、慢慢停 | 进入、出现 | `Animation.easeOut`（二次近似） | `.easeOut` / `Curves.easeOut` |
| ease-in-out | (.42,0,.58,1) | 慢—快—慢 | 位移、尺寸、状态切换 | `Animation.easeInOut`（分段二次近似）/ 语义 `.medium` | `.easeInOut` / `Curves.easeInOut` |
| cubic-bezier | 自定义 | 精确速度 | 设计系统、品牌动效 | `AnimationCurve.cubicBezier(x1,y1,x2,y2)`、`Easing` token | `Animation.timingCurve` / `Cubic` |
| steps | steps(5, end) | 一格一格跳 | 帧动画、数字变化 | `AnimationCurve.steps(5, position: .end)` | SwiftUI/Flutter 无同名预设，需离散量化 |
| linear() | 多段折线 | 近似弹跳 | 新 API 的多点曲线 | `AnimationCurve.piecewiseLinear(LinearTimingCurve)`（可平台、反向、过冲） | CSS `linear()`；Flutter 自定义 `Curve` |

注意：GuavaUI 的 `easeIn/easeOut/easeInOut` 是二次近似，不比 CSS 的贝塞尔端点值；需要精确曲线时显式写 `cubicBezier(...)`。

### 6.3 曲线语义与过冲预设

- 横轴是时间、纵轴是进度；曲线越陡速度越快，越平越慢；`y > 1` 过冲（先冲过目标再回来），`y < 0` 先反向（蓄力后弹出）。
- `cubicBezier` 求值不裁剪 y，插值同样不裁剪，所以过冲可直接表达；只用于位移、缩放、几何属性，颜色和透明度保持 [0,1] 语义。
- 常用过冲/蓄力预设（作为 `cubicBezier` 常量使用）：

| 效果 | 曲线 | 场景 |
| --- | --- | --- |
| easeOutBack | cubic-bezier(0.34, 1.56, 0.64, 1) | 出现时轻微过冲再落位 |
| easeInBack | cubic-bezier(0.36, 0, 0.66, -0.56) | 退出前先蓄力 |
| easeInOutBack | cubic-bezier(0.68, -0.6, 0.32, 1.6) | 强调形变 |
| emphasized | cubic-bezier(0.2, 0, 0, 1) | Material 大转场（已有 token） |

Flutter 的 `easeOutBack` 属于这一类；`elasticOut` / `bounceOut` 是多段振荡函数，Bezier 表达不了，已提供命名曲线 `.elasticOut`（周期 0.4 的衰减振荡）与 `.bounceOut`（四次递衰抛物线）`[已实现]`。

### 6.4 设计系统曲线与主题 token

| 系统曲线 | cubic-bezier | GuavaUI |
| --- | --- | --- |
| Material standard / Android FastOutSlowIn | (.4,0,.2,1) | `Easing.standard` = `theme.motion.standardEasing` `[已实现]` |
| Material emphasized | (.2,0,0,1) | `Easing.emphasized` = `theme.motion.emphasized` `[已实现]` |
| Material decelerate（进入） | (0,0,.2,1) | `Easing.decelerate`、`.semantic(.entering)` `[已实现]` |
| Material accelerate（退出） | (.4,0,1,1) | `Easing.accelerate`、`.semantic(.exiting)` `[已实现]` |
| iOS spring | `response` + `dampingFraction` | `Animation.spring(response:dampingFraction:)` `[已实现]` |

语义动效引用（应用与组件默认使用）：

| 引用 | 解析 | 默认 |
| --- | --- | --- |
| `.semantic(.fast)` | `theme.motion.fast` + standardEasing | 80ms |
| `.semantic(.medium)` | `theme.motion.standard` + standardEasing | 180ms |
| `.semantic(.slow)` | `theme.motion.slow` + emphasized | 320ms |
| `.semantic(.snappy)` | spring(response: fast, dampingFraction: 0.90) | 80ms |
| `.semantic(.bouncy)` | spring(response: standard, dampingFraction: 0.68) | 180ms |

应用通过 `theme.motion.fast/standard/slow/standardEasing/emphasized` 全局替换曲线与时长；组件内取 `node.theme`（解析发生在使用点，不受调用方硬编码影响）。`[已实现]`

### 6.5 物理动画

**Spring 弹簧**

- `Animation.spring(response:dampingFraction:delay:)`；`response` 是单次自然振荡的近似周期（秒），`dampingFraction` 是阻尼比：
  - `= 1` 临界阻尼，不回弹；
  - `< 1` 欠阻尼，会回弹（数值越低越弹）；
  - `> 1` 过阻尼，慢而粘。
- 预设：`.snappy`（0.30 / 0.90）、`.bouncy`（0.45 / 0.65）、`.smooth`（0.40 / 1）、无参 `.spring()`（0.40 / 0.82）。
- 物理 controller 按真实秒数求解析解，在收敛上界吸附精确终值；几何动画通过 `allowsOvershoot: true` 放开过冲，颜色 / 透明度默认限制进度。`AnimationCurve.spring` 是有明确端点的归一化时间曲线，与物理求值分开。`[已实现]`

**其他物理/特殊效果**

| 效果 | 说明 | GuavaUI |
| --- | --- | --- |
| Bounce 弹跳 | 像球落地反弹 | `AnimationCurve.bounceOut`（四次递衰抛物线）`[已实现]` |
| Elastic 弹性 | 多次振荡 | `AnimationCurve.elasticOut`（周期 0.4 的衰减振荡）`[已实现]` |
| Back / Overshoot | 冲过目标再回来 | `cubicBezier` y>1（6.3 预设） `[已实现]` |
| Anticipate 预期 | 先反向蓄力再走 | `cubicBezier` y<0（6.3 预设） `[已实现]` |
| Decay / Inertia 惯性 | 滚动、拖拽甩出 | 滚动已有系统 momentum/回弹/收敛，`reducesMotion` 下禁用 `[已实现]`；`springDrag` 提供一般组件带速度释放 `[已实现]` |

**可中断性**：几何弹簧替换旧 controller 时保留当前值与各分量的实际速度，改变目标距离或方向时也保持连续；受边界约束的动画从当前值静止启动。`springDrag` 以窗口内的实际指针样本估算释放速度，重新抓取取消旧尾部。`[已实现]`

### 6.6 选型与时长

| 场景 | 语义动效 | 曲线 | 时长 |
| --- | --- | --- | --- |
| 进入 / 出现 | `.semantic(.medium)` 或显式 ease-out | decelerate | 180–200ms |
| 退出 / 消失 | `.semantic(.fast)` 或显式 ease-in | accelerate | 80–120ms |
| 位置、尺寸、状态切换 | `.semantic(.medium)` | standard | 180–200ms |
| 循环（loading、进度） | `Animation.linear` | linear | 由自身周期决定 |
| 拖拽释放、可打断 | `.semantic(.snappy)` / `.bouncy` | spring | 无固定时长 |
| hover / press 微反馈 | `.semantic(.fast)` | standard | 80ms |
| 模态、大区域、主题切换 | `.semantic(.slow)` | emphasized | 320ms |
| 活泼、俏皮（仅位移/缩放） | `.semantic(.bouncy)` 或 back 曲线 | spring / cubicBezier | — |
| 正式、克制 | standard / emphasized | — | — |

- 时长分级：小元素 100–200ms、中等 200–300ms、大区域 300–500ms；默认 `standard` 180ms、`slow` 320ms 落在区间内，`fast` 80ms 专用于最轻的 hover/press 微反馈；超出分级时显式写 duration。
- `reducesMotion`：立即到终态、禁用框架运动与滚动回弹/惯性；状态反馈（颜色/透明度终值）仍保留；通用 `animatableSet` 属性写入同样吸附终值并取消在飞控制器。`[已实现]`

### 6.7 实现（GuavaUI API，SwiftUI 对照）

显式动画（`withAnimation` 与 SwiftUI 同名同形，直接迁移）：

```swift
// SwiftUI
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { flag.toggle() }

// GuavaUI
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { flag.toggle() }
withAnimation(Animation(duration: 0.2, curve: .easeOut)) { expanded.toggle() }
```

隐式动画（值变化时触发；首帧吸附，之后才动画）：

```swift
// SwiftUI
Row().background(active ? .green : .red)
     .animation(.easeInOut(duration: 0.25), value: active)

// GuavaUI：应用直接传 Animation
content
    .background(active ? .accent : .surface)
    .animation(.easeInOut(duration: 0.25), value: active)
```

组件内部则统一写 `.animation(.semantic(.fast, in: node.theme), value: visualKey)`，让主题一次替换曲线与时长（现有 Button / TextField / List / Menu 等均为此模式）。

进入 / 退出（不同效果、快速反转、退出期间保留子树状态且不接输入）：

```swift
// SwiftUI
if visible { DetailView().transition(.opacity.combined(with: .move(edge: .top))) }

// GuavaUI：条件 if 不接管退出，进入/退出统一用 AnimatedVisibility
AnimatedVisibility(isVisible: visible,
                   transition: .opacity.combined(with: .move(edge: .top, distance: 12))) {
    DetailView()
}
```

过渡原语：`.opacity`、`.offset(x:y:)`、`.move(edge:distance:)`、`.scale(from:anchor:)`、`.collapse`（高度折叠）、`.combined(with:)`、`.asymmetric(insertion:removal:)`。默认动画为 `.semantic(.medium)`；`onVisibilitySettled` 提供退出完成回调。生命周期缩放保留阴影偏移/模糊尺寸，普通节点缩放同步缩放两层阴影；嵌套与缓存遵循相同规则，见 [动画系统](animation.md)。

窗口主题切换可用 `.appearance(appearance, transition: .circular())`，自定义主题用 `.theme(palette, transition: .circular(), value: themeMode)`。Button / Switch 自动提供扩散中心，GPU 保留上一帧并以圆形遮罩揭示新主题；减少动画或缺少上一帧来源时立即切换。Gallery 已应用，调用方式、反向切换与后端边界见 [动画系统](animation.md)。

可动画的属性（`withAnimation` / `.animation(_:value:)` 生效范围）：样式类（background/foreground/opacity/cornerRadius/border/shadow）、布局类（frame 宽高与 min/max、padding、flex grow）、过渡用的 `contentOffset`。`[已实现]`

主题覆盖与自定义曲线：

```swift
var theme = Theme.defaultDark
theme.motion.fast = .milliseconds(120)
theme.motion.standard = .milliseconds(220)
theme.motion.slow = .milliseconds(380)
theme.motion.standardEasing = .cubicBezier(0.4, 0, 0.2, 1)
theme.motion.emphasized = .cubicBezier(0.2, 0, 0, 1)

// 品牌大转场：过冲只用于位移/缩放
withAnimation(Animation(duration: 0.3, curve: .cubicBezier(0.34, 1.56, 0.64, 1), allowsOvershoot: true)) {
    showBadge = true
}
```

减少动画与滚动惯性：

```swift
content.reducedMotion()          // 子树声明；组件读 node.prefersReducedMotion
.scrollPhysics(.bouncy)          // 覆盖滚动摩擦/回弹；reducedMotion 下框架回弹与惯性禁用
```

**逐效果对照（SwiftUI → GuavaUI）**

```swift
// SwiftUI：常用四式
withAnimation(.easeOut(duration: 0.2)) { shown = true }          // 进入：减速
withAnimation(.easeIn(duration: 0.15)) { shown = false }         // 退出：加速
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { dragPos = .zero }   // 拖拽释放
withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.3)) { badgeIn = true } // 过冲

// GuavaUI：对应能力
withAnimation(Animation(duration: 0.2, curve: .easeOut)) { shown = true }
withAnimation(Animation(duration: 0.15, curve: .easeIn)) { shown = false }
card.springDrag(offset: $dragPos, restingAt: .zero)
withAnimation(Animation(duration: 0.3, curve: .cubicBezier(0.34, 1.56, 0.64, 1), allowsOvershoot: true)) { badgeIn = true }
```

| 效果 | SwiftUI | GuavaUI |
| --- | --- | --- |
| 固定时长缓动 | `.animation(.easeOut(duration: 0.2), value:)` | 同形；组件内 `.semantic(.fast/.medium/.slow)` 走主题 `[已实现]` |
| 自定义曲线 | `.timingCurve(0.4, 0, 0.2, 1, duration: 0.25)` | `Animation(duration:curve: .cubicBezier(0.4,0,0.2,1))` `[已实现]` |
| 弹簧（参数） | `.spring(response:dampingFraction:)` | 解析解、释放与继承速度，几何过冲显式启用 `[已实现]` |
| 弹簧（系统预设） | `.snappy` / `.bouncy` / `.smooth`、`Spring(duration:bounce:)` | `.snappy` / `.bouncy` / `.smooth` 与主题语义引用 `[已实现]` |
| Back 过冲 | `.timingCurve(0.34, 1.56, 0.64, 1, duration:)` | `cubicBezier(0.34,1.56,0.64,1)` `[已实现]` |
| Bounce / Elastic | `.spring(duration:bounce:)`、iOS 17 `UnitCurve` / `CustomAnimation` | `.bounceOut` / `.elasticOut` `[已实现]` |
| 阶梯 steps | 手动量化 / `TimelineView` | `AnimationCurve.steps(_:position:)` `[已实现]` |
| 多点折线（linear()） | CSS `linear()`、自定义 `UnitCurve` / `CustomAnimation` | `AnimationCurve.piecewiseLinear(LinearTimingCurve)` `[已实现]` |
| 隐式动画 | `.animation(_:value:)` | 同名 `[已实现]` |
| 显式动画与完成回调 | `withAnimation`、`withAnimation(_:completionCriteria:_:completion:)` | `withAnimation(...completionCriteria:...completion:)`，支持逻辑期限与物理停止判定 `[已实现]` |
| 进入 / 退出 | `.transition(.opacity.combined(with: .move(edge: .top)))` | `AnimatedVisibility` + `Transition`（同原语集）`[已实现]` |
| 数值 / 文本过渡 | `.contentTransition(.numericText())` | `NumericText` 数值插值与自定义格式，非任意字符滚轮 `[已实现]` |
| 关键帧 / 相位 | `KeyframeAnimator` / `PhaseAnimator` | `KeyframeTimeline`、`KeyframeAnimator`、普通域值 `PhaseAnimator` `[已实现]` |
| 跨节点几何 morph | `matchedGeometryEffect` | `.matchedGeometry(id)` 共享表面位置 / 宽高，ID 在场景内唯一 `[已实现]` |
| 循环动画 | `.repeatForever(...)` | `.repeatCount` / `.repeatForever`；加载组件复用通用控制器 `[已实现]` |
| 减少动画 | `@Environment(\.accessibilityReduceMotion)` | `.reducedMotion()` + `node.prefersReducedMotion` `[已实现]` |
| 惯性 / 甩出 | 系统滚动物理、`.scrollTargetBehavior` | `ScrollPhysics` 系统 momentum + 回弹 `[已实现]` |

### 6.8 验收

| 范围 | 入口 / 断言 |
| --- | --- |
| 语义 token 解析（时长、曲线、spring） | `Tests/GuavaUIComposeTests/SemanticMotionTests.swift` |
| controller tick / 替换 / finish / cancel / 调度 | `Tests/GuavaUIRuntimeTests/AnimationControllerTests.swift` |
| 新曲线求值（端点 / 阶梯边界 / 弹跳连续性 / 过冲 / 非有限时间） | `Portable/Tests/GuavaUISceneTests/Animation/CurveTests.swift` |
| 动画页双向尺寸动画（390/720/1280 × light/dark × 减少动画 × 禁用） | `Examples/Tests/GalleryContentTests/AnimationTests.swift` |
| 关键帧 / 循环 / 速度 / 完成判定 | Portable `Animation/PlaybackTests.swift` |
| 相位 / 几何 / 数字 / 帧顺序 | Gallery `AnimationSystemTests.swift` |
| 拖拽释放 / 按压缩放 | Compose `Animation/InteractionTests.swift` |
| `.animation(_:value:)`：首帧吸附、值变化触发、nil 关闭 | `AnimationValueModifierTests.swift` |
| 属性动画（opacity / bg / fg / cornerRadius） | `WithAnimationOpacityTests.swift`、`WithAnimationPropertiesTests.swift`、`AnimationIntegrationTests.swift` |
| 控件动效（field hover、toggle 反转从当前进度继续） | `ControlMotionTests.swift` |
| 浮层沿边动画与退出后清理 | `SheetTests.swift`、Portal 测试 |
| 滚动惯性/回弹与 reducedMotion 禁用 | Portable `Scrolling` 测试族 |

必查项：首帧不产生入场动画；只有 keyed value 变化才动画；中断从当前显示值继续且不重复应用终值；`reducesMotion` 立即到终态；动画结束后 scheduler 活跃数归零；过冲不用于颜色/透明度；循环动画用 linear。

## 7. 与其他文档的关系

- [组件标准](standard.md)：交付要求与层次；本文是其空间、重排与输入维度的展开。
- [组件覆盖与缺失清单](gaps.md)：缺失组件规范、既有组件功能缺口与优先级；实现新组件后回到本文补第 3 节契约与第 5 节状态。
- [布局](layout.md)：容器 API、测量与自定义布局；本文第 1 节定义其空间不足语义。
- [设计系统与缩放](design-system.md)：token、`TextScaler`、图标策略；本文第 2 节只给验收基线。
- 各组件文档末尾的"响应式与输入密度"小节保存该控件的现状细节；本文冲突时以本文契约与第 5 节状态为准。

### 7.1 参考对照（SwiftUI / Flutter）

用于实现时查找对应的成熟模式；行为契约对齐，名称与 API 不对齐。

| 需求 | SwiftUI | Flutter / Material 3 |
| --- | --- | --- |
| 宽度/高度类与设备判定 | `horizontalSizeClass`、`verticalSizeClass` | `MediaQuery.sizeOf`、`LayoutBuilder` |
| 容器级自适应 | `ViewThatFits`、自定义 `Layout` | `LayoutBuilder`、`CustomMultiChildLayout` |
| 标签条换边 | `TabView` 位置配合 size class | `NavigationBar`（compact）↔ `NavigationRail`（medium）↔ `Drawer` |
| 侧栏收敛 | `NavigationSplitView` 的 column visibility | `NavigationRail` / `NavigationDrawer` |
| 溢出菜单 | `Menu`、工具栏 `ToolbarItemGroup` | `PopupMenuButton`、AppBar 的 overflow |
| 单行截断 | `lineLimit(1)` + `truncationMode(.tail)` | `maxLines` + `TextOverflow.ellipsis` |
| 换行容器 | `FlowLayout`（自定义） | `Wrap` |
| 滚动与虚拟化 | `List`、`LazyVStack`、`ScrollView` | `ListView.builder`、`SliverGrid` |
| 触摸目标 | HIG 44pt | Material 48dp（本项目下限取 44pt，与既有密度契约一致） |
| 安全区 | `safeAreaInset`、`ignoresSafeArea` | `SafeArea`、`MediaQuery.paddingOf` |
| 焦点与键盘 | `focusable`、`FocusState`、`focusEffect` | `Focus`、`FocusTraversalGroup`、`Shortcuts` |
| 辅助功能 | accessibility label/value/trait | `Semantics`（label/value/onTap） |
