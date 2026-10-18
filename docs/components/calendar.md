# Calendar / DatePicker 日历导航

`CalendarView` 提供月视图、可用日期规则和键盘焦点；日期选择由调用方 binding 持有。选中日期使用实心圆形 accent，今天使用 accent 圆形描边，均为 iOS 月历形态。`DatePicker` 在弹层中复用同一日历，选择日期后提交并关闭。

```swift
CalendarView(selection: $date) { options in
    options.calendar.firstWeekday = 2
    options.presentation.numberOfMonths = 2
    options.visibleMonth = $month
    options.availability.minimum = earliestDate
    options.availability.maximum = latestDate
}
```

`CalendarOptions` 管理 Foundation Calendar、locale、today、可用日期和可选的受控月份。`CalendarPresentation` 管理日期格大小、月份数量和启用状态。焦点日期与请求属于会话，不写入选择或 authored 配置。

## 键盘与日期限制

| 按键 | 行为 |
| --- | --- |
| Left / Right | 向前 / 后移动一天，按相同步长跳过不可用日期 |
| Up / Down | 向前 / 后移动七天，按相同步长跳过不可用日期 |
| Home / End | 定位当前焦点所属月份的首个 / 最后一个可用日期 |
| PageUp / PageDown | 移到上一 / 下一月，尽可能保留当前日号，目标月份较短时夹到月末 |
| Return / Space | 选择当前日期；在 DatePicker 中同时关闭弹层 |

月份跳转的目标不可用时，先沿翻月方向在目标月内查找，再向反方向查找。不会越过目标月份或跳过整个空月；目标月没有可用日期时，焦点、可见月份与选择均不改变。Home/End 同样只在当前月内查找。`minimum`、`maximum` 按宿主 calendar 的本地日期比较，禁用谓词收到当天开始时间。

算术使用 calendar 的月/日组件，不把一天当作固定 24 小时。闰年、跨年、月底与夏令时由同一套日期运算处理。导航只移动实际焦点和 Tab 入口，按 Return/Space 或激活日期的辅助功能动作才写入选择。修饰键组合不被这些导航命令消费。

多月份视图中，目标仍在已显示范围内时保持月份窗口；超出范围时只移动必要的窗口，使目标落在首月或末月。日历或日期禁用后移除 Tab 入口并释放已有焦点。DatePicker 中翻月保持弹层与旧选择，提交后关闭并恢复触发器焦点。

## 响应式与输入密度

日期格在 touch 或混合输入 surface 上至少 44pt；pointer 使用 authored `cellSize`。宽度与输入能力分别由 surface 提供，组件不读取平台类型。每个已显示月份保留一个可用日期作为 Tab 入口，辅助功能暴露完整日期名称、选中与禁用状态。

整板使用横向 ScrollView，月份最小宽度为 `7 × cellSize + 32`（含六个 2pt 间隙与两侧 10pt padding）；窄于该宽度时滚动月份，不压缩日期格。`.stable` 为横向滚动条保留底部 12pt，避免覆盖末行。日期键盘命令先于外层滚动处理；焦点显露仍通过同一 ScrollView。待完成的日期点击可让位于拖动，起拖不会误选日期；Slider 等明确拖动保持独占捕获。

DatePicker / DateRangePicker 的弹层宽度预算使用触摸解析后的 cellSize，随后由 Popover 夹到窗口 −24pt；单月在 390pt 窗口中能完整显示七列，极窄或多月份仍可整板滚动。日期区间触发标题单行省略并保留全文 tooltip 与语义。

`CalendarKeyboardNavigationTests` 覆盖 390pt 触摸 + 键盘、720pt 混合输入、1280pt 指针 + 键盘，验证焦点与提交分离、月底/闰年/跨年/DST、可用范围与空月、多月份窗口、禁用释放焦点及 DatePicker 提交/关闭。`CalendarAdaptiveTests.narrow` 覆盖普通/区间月历、200/286/390/720/1280pt、100%/200%、44pt 格、末行滚动条间距、从启用日期开始的整板拖动与不误选；`SliderAxisTests.exclusiveDrag` 防止滚动抢走滑杆拖动。`NavigationStateTests.calendarKeyboard` 验证 Gallery 的周末禁用故事。

2026-10-18 DevTools：390×820 touch 的故事月历视口宽 286pt，从 (260,600) 左拖到 (80,600)，AI 查询 `calendar-scroll.contentOffset.x = 54`，镜像确认右侧星期日和日期列可达、末行没有被滚动条覆盖。390×820 dark/touch 的 DatePicker 弹层月历宽 344pt、日期格 44×44；点击 2026-10-20 后弹层关闭，触发器语义值与正文均为 `2026年10月20日`。两张镜像均实际检查了字号、对齐、圆形状态与明暗表面。
