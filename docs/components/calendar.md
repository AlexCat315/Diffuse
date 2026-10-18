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

`CalendarKeyboardNavigationTests` 覆盖 390pt 触摸 + 键盘、720pt 混合输入、1280pt 指针 + 键盘，验证焦点与提交分离、月底/闰年/跨年/DST、可用范围与空月、多月份窗口、禁用释放焦点及 DatePicker 提交/关闭。`NavigationStateTests.calendarKeyboard` 验证 Gallery 的周末禁用故事。手机整板横向滚动兜底和真机视觉仍见 [跨平台控件规范](adaptive-spec.md)。

本轮 macOS 宿主验证：`swift test --package-path GuavaUI` 与 `swift test --package-path GuavaUI/Examples` 均通过，Gallery 共 9 项测试通过。
