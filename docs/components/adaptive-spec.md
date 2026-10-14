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
| `ScrollView` / `BoundedScrollView` | 先按内容测量；`BoundedScrollView` 在 min/max 高度内先长大再滚动。溢出轴在边界处按 `.whenScrollable` 停留（顶部/底部继续吃滚动，不带动父级），非溢出轴允许事件透传；滚动条用 `.stable` gutter 预留 12pt 不压尾部控件 | `[已实现]`；键盘 Page/Home/End 与滚动条辅助功能 `[未实现]` |
| `SplitView` | 空间足够时优先满足两侧 minimum；比例范围与像素最小冲突时像素最小优先。空间不足 minFirst + minSecond 时按两个最小尺寸的比例共享空间并继续裁剪，不让面板撑破窗口；比例作为"请求值"保留，窗口恢复后还原分配。拖拽/键盘/辅助功能写回约束后的 binding | `[已实现]`；compact 单栏/折叠阈值 `[未实现]` |
| `Grid` / `LazyGrid` | `fixed` 列保持像素宽并在不足时滚动或收缩；`flexible(minimum:)` 不跌破 minimum；`adaptive(minimum:)` 按可用宽度减少列数直至最小列数。窄于单列 minimum 时退化为单列并允许横向滚动或自身滚动 | 列策略 `[已实现]`；单列退化后的滚动兜底、span/二维窗口化 `[未实现]` |
| `ViewThatFits` / `LayoutThatFits` | 按容器实测宽（默认阈值 600）或候选测量选择布局；两分支各自保留节点与 `@State`，隐藏分支不参与布局/绘制/输入/辅助功能并释放焦点与指针捕获；重任务由应用按当前形态控制 | `[已实现]` |
| `ContainerSizeReader` | 发布自身内容盒（扣 padding/border）实测尺寸；首次收到 `.zero`，变化 < 0.5pt 不发布；父级必须有界宽。卡片内部自适应用它，不用窗口宽度 | `[已实现]` |
| `WidthClassReader` | 读取 surface 级 width class（窗口级），用于壳层：导航收敛、栏位切换；不用于卡片内部 | `[已实现]` |
| `SafeArea` | 只应用宿主提供的 logical insets，嵌套时只消费未使用边；桌面默认零；不推断刘海/软键盘/窗口 chrome。宿主要求：手机竖屏底部 inset 含 home indicator，横屏含侧边；IME 出现由宿主处理，组件不用占位 | `[已实现]`；IME 联动 `[部分]` |
| `Form` / `PropertyGrid` | 宽布局用 leading label + 右侧 value 槽；`minValueWidth` 保证输入可测。窄布局 label 折到 value 上方（stacked），label 单行截断且完整值可达 | `[未实现]`（见第 5 节） |
| `TabView` 标签条 | 单行不换行；超出时按 `overflow` 横向滚动或折叠菜单；compact 时按 `TabStripPlacement.adaptive` 移到内容下方，节点与状态保留 | 换边/滚动 `[已实现]`；折叠菜单 `[未实现]` |
| `Toolbar` | 空间不足按优先级把次级命令收进 overflow 菜单，保留主命令与关闭；标题先截断后隐藏；触摸面高度 ≥ 44pt。优先级由调用方声明，容器只执行 | overflow `[未实现]` |
| `Sidebar` | expanded 常驻；compact/medium 按壳层选择折叠为抽屉/覆盖层或 rail；抽屉打开时焦点进入、Escape 关闭、关闭后焦点还原；项行高 ≥ 44pt（触摸） | 常驻列表 `[已实现]`；抽屉/rail `[未实现]` |
| `Workspace` | widthClass != expanded 时自动进入紧凑呈现：单面板 + 面板选择器；expanded 恢复停靠树。折叠、比例、活动面板作为会话保留，不写入文档 | 紧凑切换 `[已实现]`；标签条键盘与完整语义 `[部分]` |
| `Panel` / `StatusBar` / `Carousel` 等边框容器 | 标题/状态格单行截断并保留完整语义；`Carousel` 一页一屏、不因窄而缩小内容，方向键/滑动/Home/End 导航；`StatusBar` 单元格等高等宽策略由调用方声明 | 结构 `[已实现]`；状态格截断策略 `[部分]` |

### 1.2 虚拟化与大数据

- 大集合（List/Tree/DataTable/VirtualStack）必须使用窗口化协议，空间不足不改变虚拟化契约：行高在触摸面替换为 `max(authored, 44)`，窗口化 extent 与滚动范围使用同一高度；切回指针恢复 authored 高度。
- 已知可变行高用 `VariableVirtualStack`；未知高度测量 `[未实现]`。普通 `ScrollView` 不自动窗口化，长列表必须显式选择容器。
- 数据表列在窄宽下：调用方声明列优先级，容器按优先级隐藏低优先列并提供横向滚动与"列可见性"入口；`frozenColumnCount` 冻结列不参与隐藏 `[未实现]`。

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
- 交互与验收：键盘 Space / Return；RadioGroup 单一 Tab 停靠 + 方向键循环；辅助功能 role=checkbox / toggle / radio，暴露 value 与 selected。焦点环目前对点击聚焦也绘制，要求改为仅键盘焦点可见。`[部分]`。验收：`TouchDensityTests`（checkbox/toggle）、Gallery `--component checkbox|toggle`。

### 3.2 连续与离散值

**Slider**

- 外观：高 24pt、thumb 18、track 4、填充 accent；disabled 全 surfaceVariant。`[已实现]`
- 手机：命中区 ≥ 44pt 且轨道居中；每行一个滑杆；数值标签同行放不下时移至下一行而不截断。`[已实现]`（44pt 命中）；标签重排由调用方布局。
- 平板 / 桌面：hover/press thumb 反馈；恢复 24pt 原生高度。`[已实现]`
- 交互与验收：指针拖动、方向键、Home/End、辅助功能 slider setValue / increment / decrement；Page 键与离散刻度视觉 `[未实现]`。验收：`TouchDensityTests` slider、Gallery `--component slider`。

**Rating**

- 外观：星 12/16/20/28（mini/small/regular/large），可交互高度 ≥ 32；半星预览；只读用 image 语义。`[已实现]`
- 手机：每星命中 lane ≥ 44pt、组件高 ≥ 44pt；触摸面无被动 hover 预览，按下拖动仍预览；最大星数下放不下时整体裁剪绘制与命中，不允许负值布局。`[已实现]`
- 平板 / 桌面：hover 预览、键盘焦点环 2pt；恢复紧凑展示尺寸。`[已实现]`
- 交互与验收：方向键步进、Home/End、Delete 清空、Escape 取消；辅助功能 slider 语义 + setValue/increment/decrement。验收：Rating 测试族 + Gallery `--component rating` 的 narrow/wide/touch。

**Stepper**

- 外观：数字/完成/失败/忙碌图标 + 标题 + 说明；选中是导航、状态是业务值，互不写入。`[已实现]`
- 手机：窄宽下先换纵向排列，再退化为横向滚动；不得压缩步骤或触摸目标，不得把说明截断到不可读。`[未实现]`（当前无自动换纵向/滚动）
- 平板 / 桌面：横向单行；200% 文本缩放可操作。`[已实现]`
- 交互与验收：单一 Tab 停靠、方向键（随轴）、Home/End、边界停止、禁用跳过；辅助功能暴露序号与结果。验收：`--component stepper` + `Stepper` 测试。

**ButtonGroup / Segment**

- 外观：分段单选，选中填充 accent；roving focus 单停靠点。`[已实现]`
- 手机：段数多时不缩文字；超出宽度改为横向滚动或换行成两段。`[未实现]`
- 平板 / 桌面：单行分段；hover 反馈。`[已实现]`
- 交互与验收：方向键切换、辅助功能 radio/tab 语义；触摸段高 ≥ 44pt。验收：`TouchDensityTests` segment、Gallery `--component buttonGroup`。

**Calendar**

- 外观：月视图、日期格由 `controlSize` 决定；前后月箭头为独立按钮。`[已实现]`
- 手机：日期格 ≥ 44pt，单月一屏；放不下时整板横向滚动，不缩格。`[部分]`（触摸格下限已实现；整板滚动与窄宽取样待验收）
- 平板 / 桌面：可多月份并排（`numberOfMonths`）；hover 日期反馈。`[已实现]`
- 交互与验收：方向键移动（±1/±7）、辅助功能每格 role=button + 选中态、月份箭头有名称；Home/End/PageUp/PageDown `[未实现]`。验收：`TouchDensityTests` calendar、`--component calendar` 的三预览。

### 3.3 文本与数值输入

**TextField / TextArea / CodeEditor**

- 外观：regular 28、small/mini 更低；单行水平、多行垂直（`maxVisibleLines` 默认 6）；clear 仅在聚焦且可清空时出现。`[已实现]`
- 手机：输入 surface 与 style host 命中 ≥ 44pt；获得焦点时宿主滚动显露光标；多行输入不因软键盘挤压丢光标。`[已实现]`（44pt、滚动显露）；IME 联动 `[部分]`
- 平板 / 桌面：恢复 authored 高度与 hover scrollbar；键盘 F1/补全等不依赖指针。`[已实现]`
- 交互与验收：完整编辑键位、提交/取消、Unicode 与文本缩放、辅助功能 role=textField + 值延迟生成。验收：`TouchDensityTests` field、`TextField*`/`CodeEditingUITests`；Gallery `--component textField`。

**NumberField / Vec3Field**

- 外观：NumberField 为 TextField + 可选步进列（最小 22pt）；Vec3Field 为三个可收缩轴单元 + 固定轴字母。`[已实现]`
- 手机：步进按钮触摸 ≥ 44pt；Vec3Field 窄宽下允许两行（X/Y 一行、Z 一行）或横向滚动，不允许把轴单元压到不可编辑。`[未实现]`（当前只有 shrink + clip）
- 平板 / 桌面：单行三联编辑；Shift/Alt 步进语义保持。`[已实现]`
- 交互与验收：提交/失焦解析、非法输入恢复、min/max 夹紧、辅助功能输入值；验收：`--component numberField|vec3Field`。

**ColorField**

- 外观：色块 52×22 + 可选 inline hex；弹层 220 宽、通道行固定列。`[已实现]`
- 手机：弹层宽度 ≥ min(280, 窗口 − 24)，触摸通道行 ≥ 44pt；不因窄而隐藏 hex 输入。`[未实现]`（弹层固定 220）
- 平板 / 桌面：保持弹层宽度与 hover。`[已实现]`
- 交互与验收：弹层键盘可达、Escape 关闭、辅助功能值可读。验收：`--component colorField`。

**Select / Combobox**

- 外观：触发器继承 field chrome；弹层菜单、`maxVisibleRows` 默认 8、内部滚动；Combobox 带搜索与清除。`[已实现]`
- 手机：触发器单行截断并保留完整值（tooltip/辅助功能）；弹层宽度 ≥ 触发器宽度且 ≤ 窗口 − 24；行高 ≥ 44pt。`[未实现]`（触发器可换行、弹层固定 280、行高 32）
- 平板 / 桌面：触发器与弹层自然宽度、hover 高亮。`[已实现]`
- 交互与验收：键盘 Up/Down/Home/End/Enter/Escape、类型前缀查找；辅助功能 popup/值/展开态。验收：`--component select|combobox`（Menu 测试族）。

**DatePicker / TimeField**

- 外观：触发器最小宽 140 + 清除按钮；弹层按月份数取宽。`[已实现]`
- 手机：触发器单行截断、弹层宽度 ≤ 窗口 − 24、日期格/时间格 ≥ 44pt。`[部分]`（弹层宽度与格高需补验收）
- 平板 / 桌面：弹出日历，键盘可导航。`[已实现]`（日历部分）
- 交互与验收：Escape 关闭、辅助功能 label/value/isExpanded；验收：`--component datePicker|timeField`。

**AssetRefField / JsonField**

- 外观：AssetRefField 显示资源 + 清除 + drop 目标；JsonField 紧凑多行编辑、提交校验、拖拽调整高度、展开为带行号的大编辑器。`[已实现]`
- 手机：drop 目标在触摸面保留清空与选择入口（拖放不是唯一路径）；JsonField 展开模式占满窗口并 ≥ 44pt 操作按钮。`[部分]`（清空已有；展开按钮触摸尺寸需验收）
- 平板 / 桌面：拖放与展开均可；hover 提示。`[已实现]`
- 交互与验收：Cmd+Return 提交、Escape 取消、校验失败保留草稿；验收：`--component assetRef|jsonField`。

### 3.4 数据集合

**List / Tree**

- 外观：行高 30（触摸 44）、选中/ hover 走 `SelectionAppearance(.navigation)`；Tree 每级缩进 16、箭头列 18。`[已实现]`
- 手机：行高 `max(rowHeight, 44)`；行内容单行截断，完整文本进辅助功能；不因窄而隐藏尾部语义（徽标/状态）。`[部分]`（行高已实现；截断与文本缩放未实现）
- 平板 / 桌面：恢复 authored 行高；hover 行高亮；Tree 跟随 `TextScaler`。`[已实现]`
- 交互与验收：List 方向键/Home/End/Enter + listItem 语义；Tree 方向键、Left/Right 折叠、treeItem + selected/expanded。Tree 行高与展开按钮命中在触摸面均 ≥ 44pt，切回指针恢复 authored 尺寸；List 的文本缩放仍待补齐。验收：`TouchDensityTests` list、`RowDensityTests.collectionRows`、`NavigationStateTests` tree 200%。

**Table / DataTable**

- 外观：固定行高（Table 36 / DataTable 36）、表头固定、冻结列、单元格单行裁剪。`[已实现]`
- 手机：行、单元格与表头高度 ≥ 44pt，窗口化、冻结列、滚动范围和键盘翻页共用真实行高，内嵌按钮与编辑器保留完整命中。`[已实现]`；列按优先级隐藏低优先列并提供横向滚动与"列可见性"入口，冻结列不参与隐藏。`[未实现]`
- 平板 / 桌面：两轴窗口化、列宽拖拽、键盘单元格导航。`[已实现]`
- 交互与验收：键盘导航（箭头/Home/End/PageUp/PageDown/F2/Escape/Cmd+A）、编辑提交/取消、辅助功能 row/cell/slider（列宽）。验收：`DataTableInteractionTests`、`RowDensityTests.collectionRows` / `dataTableNavigation`、`--component table|dataTable`。

**Chart / Timeline**

- 外观：Chart 由调用方提供数据与几何；Timeline 垂直事件列。`[已实现]`
- 手机：图表宽度 100%、不缩字号；图例折行；Timeline 时间列与内容列在窄宽下上下堆叠。`[部分]`（按故事现状；堆叠规则需实现与验收）
- 平板 / 桌面：横向图例与并排时间列。`[已实现]`
- 交互与验收：数据点辅助功能值可读；验收：`--component chart|timeline`。

### 3.5 导航与流程

**TabView**

- 外观：strip + divider + 内容；选中 2px accent 指示；可选关闭按钮（ghost mini + tooltip/名称）。`[已实现]`
- 手机：`placement = .adaptive` 在 compact 把 strip 移到内容下方，节点与状态保留；strip 横向滚动，触摸标签与关闭 ≥ 44pt；隐藏标签必须有可达入口（溢出菜单）。`[部分]`（换边/滚动/触摸已实现；溢出菜单未实现）
- 平板 / 桌面：strip 在顶部；`.wrap` 或 `.scroll` 由调用方选择；roving focus。`[已实现]`
- 交互与验收：方向键/Home/End 在标签间移动、单选 tab 语义 + isSelected、关闭按钮独立停靠点。验收：`AdaptiveNavigationTests`、`TouchDensityTests` tabs、`--component tabs` 三预览。

**Sidebar**

- 外观：图标槽 + 标题 + 徽标；行高 ≥ 38；header/footer/滚动区各自边界。`[已实现]`
- 手机 / 紧凑：收敛为抽屉或覆盖层（或 rail + 覆盖层），打开时焦点进入、Escape 关闭、关闭后焦点还原；项行高 ≥ 44pt。`[未实现]`
- 平板 / 桌面：常驻分栏；图标/徽标/文字全部可见，`TextScaler` 200% 可用。`[已实现]`
- 交互与验收：方向键/Home/End 循环、Enter/Space 选择、选中显露、辅助功能完整标题 + 选中/禁用 + 徽标 value。验收：`--component sidebar`、`NavigationStateTests`；抽屉行为加入 `AdaptiveNavigationTests` 或新套件。

**Toolbar**

- 外观：单行非换行容器，最小高度按控件；分隔线与分组。`[已实现]`
- 手机：溢出按调用方优先级收进"更多"菜单；主命令与关闭保留 ≥ 44pt；图标按钮必须带名称；不允许 shrink 到不可点。`[未实现]`
- 平板 / 桌面：单行完整命令；Left/Right/Home/End 在 toolbar 内移动焦点（`.bubble`）。`[已实现]`
- 交互与验收：辅助功能 role=toolbar、组 role=group、禁用整条阻断命中；溢出菜单键盘与辅助功能对齐 Menu 契约。验收：`--component toolbar` + 新增溢出测试。

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

- 外观：搜索行 + 结果列表 + 快捷键提示；默认几何高 440。`[已实现]`
- 手机：占满窗口宽（减 16pt inset）、结果行 ≥ 44pt、软键盘出现后结果区收缩且当前项可见。`[未实现]`（固定 440 与行预算）
- 平板 / 桌面：固定宽度居中、键盘上下移动。`[已实现]`
- 交互与验收：Up/Down/Enter/Escape、前缀过滤、辅助功能 button 行 + 快捷键组；验收：`--component commandPalette` + 200% 行预算测试。

### 3.6 浮层与反馈面

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

- 宽度取样：把窗口/模拟器设为 390 / 720 / 1280 逻辑宽度；12 个已接入的控件页在故事底部自动附带 `adaptive-<page>-narrow | -wide | -touch` 三组预览（390 指针、720 指针、390 触摸），其余页面以窗口或单元测试取样。
- 输入取样：桌面默认指针 + 键盘；触屏设备默认触摸 + 键盘；混合形态（平板 + 触控板）另行验证 hover 与 44pt 并存。
- 性能基线：`--benchmark [--no-vsync]` + `GUAVA_FPS_LOG=1`；滚动与输入不得因重排产生持续重组（`graph.recomposer.hasPending == false`）。

### 4.3 自动化

| 范围 | 入口 |
| --- | --- |
| 全部页面在 light/dark、1280×820 物化且无重叠 | `swift test --package-path GuavaUI/Examples`（`GalleryTests`） |
| 触摸 44pt 族、密度恢复、hover gating | `GuavaUI/Tests/GuavaUIComposeTests/TouchDensityTests.swift` |
| Tree / Table / DataTable / Menu 行高、节点与选择保留、翻页/编辑、子浮层环境 | `GuavaUI/Tests/GuavaUIComposeTests/Adaptive/RowDensityTests.swift` |
| TabView compact 换边且保留面板状态 | `AdaptiveNavigationTests.swift` |
| 宽度类与 `minimumControlExtent` | `AdaptiveEnvironmentTests.swift` |
| ViewThatFits 分支状态保留 | `ViewThatFitsTests.swift` |
| 容器查询发布与阈值 | `ContainerQueryTests.swift` |
| Android 设备逐页启动 | `scripts/android/verify-gallery.py`（页面名直接来自 `GalleryCatalog.swift`） |
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

## 5. 未实现项清单（按本文验收）

以下条目来自对 `GuavaUICompose` 与 Gallery 的代码复核，是本文契约中当前**未实现**的部分。每项按"位置 → 验收归属"列出；实现后从清单移除并在第 3 节改为 `[已实现]`。完整缺失组件（AppBar、RangeSlider、SearchField、列表能力包等）与既有组件的其他功能缺口见[组件覆盖与缺失清单](gaps.md)。

| # | 条目 | 位置 | 验收归属 |
| --- | --- | --- | --- |
| 1 | 工具栏溢出：优先级、overflow 菜单、图标收敛 | `Controls/Toolbar.swift` | 新增 Toolbar 溢出测试 + Gallery `toolbar` |
| 2 | Sidebar 抽屉/rail 紧凑呈现；SplitView 单栏模式 | `Layout/Sidebar/Sidebar.swift`、`Layout/SplitView.swift` | `AdaptiveNavigationTests` 或新套件 + `sidebar` 页窄预览 |
| 3 | Form / PropertyGrid 宽度触发的 stacked ↔ leading label 切换；统一 `minValueWidth` 语义 | `Controls/Form.swift`、`Data/PropertyGrid.swift` | `--component form|propertyGrid` 390/720 取样 + 单元测试 |
| 4 | DataTable / Table / Grid 列优先级、隐藏与"列可见性"入口 | `Data/DataTable/*`、`Data/Lists/Table.swift`、`Layout/Grid/*` | 新列策略 API 测试 + `dataTable` 页窄宽验收 |
| 5 | TabView 溢出菜单模式（隐藏标签可达入口）与标签标题截断 | `Layout/TabView.swift` | `AdaptiveNavigationTests` 扩展 |
| 6 | Button / Select / DatePicker 等单行标题截断 + 完整 tooltip（当前只换行或裁剪） | `Text/Text.swift`（`lineLimit(1)` 仅禁换行）、各控件 | `Text` 截断测试 + 对应页面 |
| 7 | 列表族文本缩放：List / Table / DataTable / LazyGrid 行高不跟随 `TextScaler` | `Data/Lists/*`、`Layout/Grid/LazyGrid.swift` | 200% 行高测试（现有 Tree 为对照实现） |
| 9 | ScrollView 触摸拖动/惯性、键盘滚动（箭头/Page/Home/End）、横向滚动条 gutter | `Layout/ScrollView.swift` | 触摸滚动测试 + `scrollview` 页；键盘测试 |
| 10 | 浮层自适应：底部抽屉 Sheet、Select/CommandPalette 弹层宽度与行高、菜单触摸展开子菜单 | `Overlays/*`、`Fields/Select.swift` | 对应浮层测试 + 390pt 取样 |
| 11 | Stepper / ButtonGroup 窄宽替代布局（纵向或滚动） | `Navigation/Stepper/*`、`Layout/NavigationComponents.swift` | 390pt 取样 + 布局测试 |
| 12 | NumberField / Vec3Field 窄宽重排（两行或滚动） | `Fields/NumberField.swift`、`Fields/Vec3Field.swift` | 390pt 取样 + 布局测试 |
| 13 | 焦点环模态统一：仅键盘焦点绘制（Toggle/Slider/表格等当前点击也绘制） | 各控件 style | 统一断言助手 + 逐控件测试 |
| 14 | 辅助功能补齐：滚动条/滚动位置语义、Select/Combobox 专用角色、hint/described-by | `GuavaUIScene/Accessibility.swift`、各控件 | 语义快照测试 |
| 15 | 高度类/方向读取；`ViewThatFits` 从固定阈值扩展到内在内容拟合 | `Portable/Adaptive/*`、`Layout/Responsive/*` | 新 API 测试 |
| 16 | Gallery 自身自适应：壳层固定 240pt 侧栏，手机宽度仍渲染桌面骨架；12 页以外无可交互自适应预览 | `Examples/Sources/GalleryContent/GalleryView.swift`、`AdaptiveExamples.swift` | Gallery 壳层窄宽验收 + 扩充 `supports` 列表 |
| 17 | 动画曲线扩展：`steps` 阶梯、多点 `linear()`、`bounceOut` / `elasticOut` 命名曲线 | `Portable/Sources/GuavaUIScene/Animation/Animation.swift` | 曲线求值测试（端点、单调段、过冲） |
| 18 | 弹簧过冲：欠阻尼求值当前夹到 [0,1]；在位移/缩放等安全属性上放开 | 同上 | Spring 求值测试 + 视觉验收 |
| 19 | 可中断物理：中断从当前值继续但不继承速度；一般组件拖拽释放的带速度弹簧 | `AnimationController.swift`、拖拽组件 | `AnimationControllerTests` 扩展 |
| 20 | Keyframe / Phase 动画与跨节点位置尺寸 morph（matched geometry） | 未实现 | 新 API 测试 |
| 21 | `withAnimation` 完成回调（SwiftUI 的 completionCriteria + completion） | `Animation/WithAnimation.swift` | 完成回调测试 |

建议顺序：先做 1–4（壳层与数据密度，直接影响手机/平板可用性），再做 5–8（截断与行密度），然后 9–16（输入与语义补齐）；动画相关 17–21 随第 6 节的实现与验收排期。每项实现时同步更新组件文档的"响应式与输入密度"小节与本节状态。

第 8 项触摸行高已完成：`RowDensityTests.collectionRows` 在 macOS 宿主上覆盖 390/720/1280pt、touch-only、touch + pointer + keyboard、pointer + keyboard，验证 36/56pt authored 行高、44pt 下限、节点与选择保留、单元格/展开按钮命中及密度恢复；`dataTableNavigation` 验证触摸翻页、末行显露、冻结列对齐与 44pt 编辑器；`scaledRows` 覆盖 Tree/Menu 的 100%/200% 文本缩放与 light/dark；`menuRows` 验证嵌入表面的菜单及子浮层继承输入环境、行底部点击展开与键盘关闭。`swift test --package-path GuavaUI` 与 `swift test --package-path GuavaUI/Examples` 均通过。设备视觉与系统触摸派发仍按第 4 节真机矩阵验收。

## 6. 动效与动画（动画效果实现）

分两类：**时间曲线**（用 `cubic-bezier` / ease 控制"速度怎么变"）与**物理动画**（弹簧、阻尼、惯性模拟真实运动）。GuavaUI 的实现层与 SwiftUI 同形：`withAnimation`、`.animation(_:value:)`、`AnimatedVisibility` + `Transition`、`Animation.spring(response:dampingFraction:)`，再加滚动的系统惯性与回弹。本章定义效果选型、参数与验收；[已实现] 等标注同前。

### 6.1 两类动画与"拟合"边界

- **时间曲线**：总时长内进度 = `f(t)`，可预算、可导出（CSS / SwiftUI / Flutter 通用）。GuavaUI 对应 `Animation(duration:curve:delay:)`。`[已实现]`
- **物理动画**：无固定时长，可中断、可继承速度。GuavaUI 对应 spring 曲线与 `ScrollPhysics`（rubber band、系统 momentum、settle spring）。`[已实现]`
- **拟合不是物理**：把弹簧导出成 Bezier 或 CSS `linear()` 多点曲线只是看起来接近，不能实时响应中断、继承速度。拖拽释放、连续反馈用物理路径，不要用拟合曲线代替。`[部分]`（滚动已是物理；一般组件拖拽释放仍缺）

### 6.2 缓动曲线：效果与实现

| 名称 | cubic-bezier | 效果 | 常用场景 | GuavaUI | SwiftUI / Flutter |
| --- | --- | --- | --- | --- | --- |
| linear | (0,0,1,1) | 匀速、机械 | 进度条、旋转 loading、循环 | `Animation.linear`、`AnimationCurve.linear` | `.linear` / `Curves.linear` |
| ease | (.25,.1,.25,1) | 轻微慢起慢收（CSS 默认） | 通用 | 无同名预设，写 `cubicBezier(0.25,0.1,0.25,1)` | `.easeInOut`、`Curves.ease` |
| ease-in | (.42,0,1,1) | 慢起、越来越快 | 退出、消失 | `Animation.easeIn`（二次近似） | `.easeIn` / `Curves.easeIn` |
| ease-out | (0,0,.58,1) | 快起、慢慢停 | 进入、出现 | `Animation.easeOut`（二次近似） | `.easeOut` / `Curves.easeOut` |
| ease-in-out | (.42,0,.58,1) | 慢—快—慢 | 位移、尺寸、状态切换 | `Animation.easeInOut`（smoothstep 近似）/ 语义 `.medium` | `.easeInOut` / `Curves.easeInOut` |
| cubic-bezier | 自定义 | 精确速度 | 设计系统、品牌动效 | `AnimationCurve.cubicBezier(x1,y1,x2,y2)`、`Easing` token | `Animation.timingCurve` / `Cubic` |
| steps | steps(5, end) | 一格一格跳 | 帧动画、数字变化 | 无 | SwiftUI/Flutter 无同名预设，需离散量化 |
| linear() | 多段折线 | 近似弹跳 | 新 API 的多点曲线 | 无（用 cubicBezier 近似或实现多关键帧） | CSS `linear()`；Flutter 自定义 `Curve` |

注意：GuavaUI 的 `easeIn/easeOut/easeInOut` 是二次/smoothstep 近似，不比 CSS 的贝塞尔端点值；需要精确曲线时显式写 `cubicBezier(...)`。

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

Flutter 的 `easeOutBack` 属于这一类；`elasticOut` / `bounceOut` 是多段振荡函数，Bezier 表达不了，尚未提供 `[未实现]`。

### 6.4 设计系统曲线与主题 token

| 系统曲线 | cubic-bezier | GuavaUI |
| --- | --- | --- |
| Material standard / Android FastOutSlowIn | (.4,0,.2,1) | `Easing.standard` = `theme.motion.standardEasing` `[已实现]` |
| Material emphasized | (.2,0,0,1) | `Easing.emphasized` = `theme.motion.emphasized` `[已实现]` |
| Material decelerate（进入） | (0,0,.2,1) | 无命名 token，写 `cubicBezier(0,0,.2,1)` `[部分]` |
| Material accelerate（退出） | (.4,0,1,1) | 无命名 token，写 `cubicBezier(0.4,0,1,1)` `[部分]` |
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
- 预设：`.snappy`（0.30 / 0.90，控件交互）、`.bouncy`（0.45 / 0.65，活泼动效）、无参 `.spring()`（0.40 / 0.82）。
- 现状：解析解归一化后**夹到 [0,1]**，欠阻尼在视觉上不过冲；与 SwiftUI 的弹簧体感存在差异 `[部分]`。

**其他物理/特殊效果**

| 效果 | 说明 | GuavaUI |
| --- | --- | --- |
| Bounce 弹跳 | 像球落地反弹 | `[未实现]`（可用分段函数实现） |
| Elastic 弹性 | 多次振荡 | `[未实现]` |
| Back / Overshoot | 冲过目标再回来 | `cubicBezier` y>1（6.3 预设） `[已实现]` |
| Anticipate 预期 | 先反向蓄力再走 | `cubicBezier` y<0（6.3 预设） `[已实现]` |
| Decay / Inertia 惯性 | 滚动、拖拽甩出 | 滚动已有系统 momentum/回弹/收敛，`reducesMotion` 下禁用 `[已实现]`；一般组件拖拽释放 `[未实现]` |

**可中断性**：新目标替换旧 controller 时从当前显示值继续（Toggle 快速反转已有测试），但**不继承速度**；真物理的"可打断、继承速度"仍缺 `[部分]`。

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
- `reducesMotion`：立即到终态、禁用框架运动与滚动回弹/惯性；状态反馈（颜色/透明度终值）仍保留。`[已实现]`

### 6.7 实现（GuavaUI API，SwiftUI 对照）

显式动画（`withAnimation` 与 SwiftUI 同名同形，直接迁移）：

```swift
// SwiftUI
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { flag.toggle() }

// GuavaUI
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { flag.toggle() }
withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
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

过渡原语：`.opacity`、`.offset(x:y:)`、`.move(edge:distance:)`、`.collapse`（高度折叠）、`.combined(with:)`、`.asymmetric(insertion:removal:)`。默认动画为 `.semantic(.medium)`；`onVisibilitySettled` 提供退出完成回调。

可动画的属性（`withAnimation` / `.animation(_:value:)` 生效范围）：样式类（background/foreground/opacity/cornerRadius/border/shadow/backdropBlur）、布局类（frame 宽高与 min/max、padding、flex grow）、过渡用的 `contentOffset`。`[已实现]`

主题覆盖与自定义曲线：

```swift
var theme = Theme.defaultDark
theme.motion.fast = .milliseconds(120)
theme.motion.standard = .milliseconds(220)
theme.motion.slow = .milliseconds(380)
theme.motion.standardEasing = .cubicBezier(0.4, 0, 0.2, 1)
theme.motion.emphasized = .cubicBezier(0.2, 0, 0, 1)

// 品牌大转场：过冲只用于位移/缩放
withAnimation(Animation(duration: 0.3, curve: .cubicBezier(0.34, 1.56, 0.64, 1))) {
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

// GuavaUI：一一对应
withAnimation(.easeOut(duration: 0.2)) { shown = true }
withAnimation(.easeIn(duration: 0.15)) { shown = false }
withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { dragPos = .zero }
withAnimation(Animation(duration: 0.3, curve: .cubicBezier(0.34, 1.56, 0.64, 1))) { badgeIn = true }
```

| 效果 | SwiftUI | GuavaUI |
| --- | --- | --- |
| 固定时长缓动 | `.animation(.easeOut(duration: 0.2), value:)` | 同形；组件内 `.semantic(.fast/.medium/.slow)` 走主题 `[已实现]` |
| 自定义曲线 | `.timingCurve(0.4, 0, 0.2, 1, duration: 0.25)` | `Animation(duration:curve: .cubicBezier(0.4,0,0.2,1))` `[已实现]` |
| 弹簧（参数） | `.spring(response:dampingFraction:)` | 同名 API；解析解，欠阻尼当前不过冲 `[部分]` |
| 弹簧（系统预设） | `.snappy` / `.bouncy` / `.smooth`、`Spring(duration:bounce:)` | `.snappy` / `.bouncy` 与语义引用；`.smooth` 无 `[部分]` |
| Back 过冲 | `.timingCurve(0.34, 1.56, 0.64, 1, duration:)` | `cubicBezier(0.34,1.56,0.64,1)` `[已实现]` |
| Bounce / Elastic | `.spring(duration:bounce:)`、iOS 17 `UnitCurve` / `CustomAnimation` | `[未实现]`（第 5 节 17） |
| 阶梯 steps | 手动量化 / `TimelineView` | `[未实现]`（第 5 节 17） |
| 隐式动画 | `.animation(_:value:)` | 同名 `[已实现]` |
| 显式动画与完成回调 | `withAnimation`、`withAnimation(_:completionCriteria:_:completion:)` | `withAnimation` 同名；无 completion `[部分]`（第 5 节 21） |
| 进入 / 退出 | `.transition(.opacity.combined(with: .move(edge: .top)))` | `AnimatedVisibility` + `Transition`（同原语集）`[已实现]` |
| 数值 / 文本过渡 | `.contentTransition(.numericText())` | `[未实现]` |
| 关键帧 / 相位 | `KeyframeAnimator` / `PhaseAnimator` | `[未实现]`（第 5 节 20） |
| 跨节点几何 morph | `matchedGeometryEffect` | `[未实现]`（第 5 节 20） |
| 循环动画 | `.repeatForever(...)` | 组件内 Clock 驱动（Spinner / Progress / Skeleton）`[部分]` |
| 减少动画 | `@Environment(\.accessibilityReduceMotion)` | `.reducedMotion()` + `node.prefersReducedMotion` `[已实现]` |
| 惯性 / 甩出 | 系统滚动物理、`.scrollTargetBehavior` | `ScrollPhysics` 系统 momentum + 回弹 `[已实现]` |

### 6.8 验收

| 范围 | 入口 / 断言 |
| --- | --- |
| 语义 token 解析（时长、曲线、spring） | `Tests/GuavaUIComposeTests/SemanticMotionTests.swift` |
| controller tick / 替换 / finish / cancel / 调度 | `Tests/GuavaUIRuntimeTests/AnimationControllerTests.swift` |
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
| 宽度类与设备判定 | `horizontalSizeClass`、`verticalSizeClass` | `MediaQuery.sizeOf`、`LayoutBuilder` |
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
