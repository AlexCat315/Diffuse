# TimePicker

内联小时/分钟/可选秒/AM-PM 滚轮组。数据模型复用 `TimeOfDay`；触发器、Popover、Sheet 或表单卡片由调用方提供。

```swift
@State private var time: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)

TimePicker(selection: $time) {
    $0.hourCycle = .twelve
    $0.minuteStep = 5
    $0.minimum = TimeOfDay(hour: 8)
    $0.maximum = TimeOfDay(hour: 18)
    $0.label = "Start time"
}
```

## Anatomy

```
 07     20
 08     25
┌────┐ ┌────┐ ┌────┐
│ 09 │ : │ 30 │ │ AM │
└────┘ └────┘ └────┘
 10     35
 11     40
```

- hour / minute 必选
- `showsSeconds` 时增加 seconds 列
- `hourCycle == .twelve` 时增加 AM/PM 列
- 每列复用 [WheelPicker](wheelpicker.md) 的中央 band、拖拽/滚轮/键盘与 disabled 语义
- 双列/四列由 `Row` 组合，行高仍由 WheelPicker 的 pointer 32 / touch 44 决定

## Options

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `selection` | 必填 | `TimeOfDay?`；nil 显示 minimum 作为未提交起点 |
| `hourCycle` | `.twentyFour` | `.twentyFour` 或 `.twelve` |
| `minuteStep` | `5` | 1–60，分钟列只生成该步长选项 |
| `showsSeconds` | `false` | 增加秒列 |
| `isEnabled` | `true` | 禁用所有列与语义动作 |
| `minimum` / `maximum` | 00:00 / 23:59:59 | 提交时按总秒数夹紧 |
| `label` | `"Time"` | 组语义名称 |

## Behavior

- 每次滚轮/键盘/辅助功能提交都写入 `selection`，并通过 `onChange` 回调
- 12 小时制：内部仍存 0–23 小时；AM/PM 切换保持分钟/秒，只加减 12 小时
- `minuteStep` 列只显示步长倍数；绑定值不在步长上时显示最近的下界，用户操作后写回规范值
- 超出 min/max 的候选值按总秒数夹紧到边界；不会产生非法 `TimeOfDay`
- 秒列逐秒，不继承分钟步长
- 清空由调用方把 binding 设为 nil；组件不隐藏清空按钮
- 时区与日期由调用方负责；TimePicker 不读取 `Calendar`/时区

## Accessibility

- 组：`group` + label
- 每列：`slider`，label 为 Hour / Minute / Second / AM or PM，value 为当前显示值
- increment/decrement 移动一格；disabled 列不暴露动作
- 所有列共用组件级 `isEnabled`；不创建第二个 Tab 停靠点组

## Verification

- `TimePickerTests` 2/2：12 小时 hour/minute/AM-PM、24 小时 + seconds、min/max 夹紧
- Gallery `--component timePicker`：12/24 小时切换、seconds 开关、Now/Clear
- DevTools：query 到 Hour / Minute / AM or PM 三列；键盘与数值动作联动 `Committed` 文案
- 390 下整体宽度收在卡片内；1200 下居中显示

## Limits

- 无时区选择、无 12/24 自动按 locale 切换
- 无“现在”快捷入口；由宿主按钮写入 binding
- 不是弹层触发器；需要 Popover 时由调用方组合
