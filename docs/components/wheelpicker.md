# WheelPicker

iOS/macOS 风格的滚轮选择器。固定五行视口，中央 band 标记提交值；支持指针拖拽、鼠标滚轮、点击行、方向键与辅助功能 increment/decrement/setValue。

```swift
WheelPicker(
    selection: $minute,
    options: stride(from: 0, to: 60, by: 5).map {
        WheelPickerOption($0, String(format: "%02d", $0))
    },
    visibleRows: 5,
    label: "Minute"
)
```

## Anatomy

```
┌──────────────┐
│     07       │  faded
│     08       │  faded
│ ┌──────────┐ │
│ │    09    │ │  committed / center band
│ └──────────┘ │
│     10       │  faded
│     11       │  faded
└──────────────┘
```

- **center band**：`surfaceVariant` 胶囊，标记当前提交值
- **rows**：选中行 `bodyStrong` / 普通行 `body`，按距离递减 opacity
- **disabled rows**：muted + 降低 opacity，滚轮/键盘不会提交
- **gesture layer**：覆盖整个视口，拥有 slider 语义；装饰文字和 band 不重复进入语义树

## API

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `selection` | 必填 | 外部持有的选中值 |
| `options` | 必填 | `WheelPickerOption(value,label,isEnabled:)` |
| `isEnabled` | `true` | 禁用后不接收指针/键盘/滚轮 |
| `visibleRows` | `5` | 建议奇数；3–9 之间夹取 |
| `label` | `"Wheel picker"` | 辅助功能名称 |
| `onChange` | `nil` | 提交值变化回调 |

## Sizing

- 行高：pointer `32pt`，touch `44pt`（`SurfaceEnvironment.input`）
- 视口高度：`rowHeight × visibleRows`
- 宽度由调用方决定；三列时间选择建议每列 72–82pt
- 选中 band 宽等于整列宽，高 `rowHeight − 4`，圆角 `theme.radius.sm`
- 滚动行只在可见窗口附近渲染（选中索引 ± visibleRows + 2），不创建全部选项视图

## Interaction

- **拖拽**：按下即取得 pointer capture；上行/下行越过半行阈值提交一格；移动不足 4pt 视为点击
- **点击**：按点击点相对中心的位移选择目标行
- **滚轮**：每个 wheel 事件移动一个可用选项
- **键盘**：↑/← 上一项、↓/→ 下一项、Home/End 首尾；不消费文本输入
- **辅助功能**：role=`slider`，value 为当前 label；increment/decrement 跳过 disabled，setValue 只接受可用 label
- **焦点**：指针按下聚焦滚轮；禁用时移除焦点与语义动作

## Visual / accessibility

- 所有行使用同一个 `rowHeight`，没有逐行动态高度；选中 band 与行中心严格共用同一基线
- disabled 行只降低视觉强度，不改变行高或列宽
- 中央 band 不是装饰性的“第二层选中态”，而是唯一提交位置；拖拽过程中文字跟随手指，释放后回落
- 空选项显示 `No options`，不暴露 slider 动作

## Verification

- `WheelPickerTests` 4 tests / 2 suites：键盘/滚轮/拖拽/点击/辅助功能提交、disabled 行跳过、视口高度
- Gallery `--component wheelPicker`：三列时间 + 单列音量；390/720/1280 预览在 `AdaptiveControlExamples`
- DevTools：query 到四个 `slider`（Hour/Minute/AM or PM/Volume）；`input-ui` 发送 `keyDown key:"ArrowDown"` 与 wheel 后 value 逐格变化；capture 复核中央 band、fade 与列对齐

## Limits

- 单列滚轮；多列由调用方用 Row 组合，列间不共享循环/吸附
- 释放后没有惯性尾段，只有 0.2s 内的吸附动画
- 不支持循环首尾（`12 → 1` 由调用方提供循环选项）
- 高亮 band 由组件自绘；调用方不能替换成图片底
