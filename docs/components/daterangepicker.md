# DateRangePicker

日期区间选择。触发器打开真实 Calendar；第一次点击设起点、第二次点击设终点，区间段与端点分别高亮。复用 Calendar 的月份导航、可用日期、键盘与焦点契约。

## Anatomy

```
┌───────────────────────────────┐
│  Oct 12, 2026 – Oct 20, 2026 × │
└───────────────────────────────┘
        ↓
┌───────────────────────────┐
│  ◀   October 2026      ▶  │
│  S  M  T  W  T  F  S      │
│        ...                │
│  11 [12] 13 14 15 16 17   │  ← 12/20 为端点，13–19 为区间
│  ...            [20] ...  │
└───────────────────────────┘
```

- **trigger**：起止日期文本 + 可选 clear + chevron
- **calendar**：复用 `CalendarGrid` / `CalendarNavigation` / `CalendarKeyHost`
- **range fill**：端点之间使用 `stateLayerSelected`
- **endpoints**：起点/终点使用 accent 填充与 `onAccent` 文本

## API

```swift
@State private var range: ClosedRange<Date>?

DateRangePicker(selection: $range) {
    $0.presentation.width = 280
    $0.calendar.presentation.numberOfMonths = 2
}
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `selection` | 必填 | `Binding<ClosedRange<Date>?>` |
| `presentation.placeholder` | `"Choose dates"` | 空态文本与 a11y label |
| `presentation.isClearable` | `true` | 是否显示 clear |
| `presentation.isEnabled` | `true` | 禁用后不打开 |
| `presentation.width` | `260` | 触发器宽度 |
| `calendar` | `CalendarOptions()` | 日历/区域/可用日期/月份数 |

`DateRangeCalendar` 也可单独使用，参数为 `selection` 与 `CalendarOptions`。

## Sizing

- 触发器最小高度 34pt；触摸由 Popover/Button 提升到 44pt。
- 日历格沿用 Calendar 的 `cellSize`，触摸面自动提升到 44pt。
- 弹层宽度按 `numberOfMonths × (cellSize × 7 + 36)` 计算，再由 Popover 夹紧窗口。
- 单月默认；宽屏可配 `numberOfMonths = 2` 并排。

## Tokens

| 槽位 | 来源 |
| ---- | ---- |
| 触发器 chrome | `surface` / `inputRadius` / `border` |
| 端点 | `accent` / `onAccent` |
| 区间段 | `stateLayerSelected` |
| 今日/focus | `accent` / `focusRing` |
| 禁用/非当月 | `onSurfaceMuted` / opacity 0.35 |

## States

| 状态 | 行为 |
| ---- | ---- |
| 空 | 显示 placeholder；无区间 |
| 第一次点击 | 起点 = 终点 = 当天；等待第二次点击 |
| 第二次点击 | 完成区间；若在起点之前，自动交换上下界 |
| 再次点击 | 以该日为新的起点，开始下一段 |
| Escape / 外部点击 | 关闭弹层；已完成的区间保留 |
| clear | 清空 selection |
| disabled | 触发器不可打开 |

## Behavior

- **指针**：点击日期格；点击端点/区间外的日期会按当前 pending 状态开始或完成区间。
- **键盘**：方向键、Home/End、PageUp/PageDown 复用 Calendar 导航；Enter 激活当前焦点日期，走同一 `choose` 路径。
- **辅助功能**：触发器 label + `"start – end"` value + expanded 状态；日期格 role=button、完整日期 label、端点 selected；区间内日期不单独宣称 selected。
- **焦点**：弹层内 Calendar 保留一个 Tab 停靠；关闭后 Popover 还原触发器焦点。
- **限制**：没有内置“快捷预设”（今天/最近 7 天）；需要时由调用方在弹层外提供按钮并写回 binding。没有区间最大长度限制；需要时在 `onChange` 侧夹紧。

## Authoring rules

- 区间选择用 `DateRangePicker`，不要用两个 `DatePicker` 拼装。
- 起止日期应使用同一 `Calendar`/时区；跨时区项目由调用方统一 `CalendarOptions.calendar`。
- 需要快捷预设时在应用层提供按钮，不要改组件内部状态。
- 区间用于筛选时，明确端点是否包含；本组件使用闭区间 `ClosedRange<Date>`。
- 需要只选一个日期时用 `DatePicker`。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/DateRangePickerTests.swift`）：

- 两次点击选择 10–15；再点击 20 后点击 12，自动交换为 12–20。

Gallery `dateRangePicker` 页提供真实日历、端点/区间高亮、clear 与状态文本。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component dateRangePicker --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Choose dates","visible_only":true}'
guava-dev devtools input-ui 9229 --click-node <Choose dates>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # 2026年10月12日 / 20日
guava-dev devtools input-ui 9229 --click-node <12>
guava-dev devtools input-ui 9229 --click-node <20>
guava-dev devtools capture-ui 9229 /tmp/guava-daterange.jpg
```

## References

- Flutter `showDateRangePicker`
- SwiftUI 无内置 DateRangePicker（Calendar + 自定义状态）
