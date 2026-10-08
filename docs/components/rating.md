# Rating

`Rating` 是受控的星形评分组件，值来自 `Binding<Double>`。`RatingSelection` 管理选择规则；`RatingAppearance` 管理尺寸、间距和语义颜色。悬停和按下状态归挂载节点所有，不写入评分值。

```swift
@State private var score = 2.5

Rating("Customer score", value: $score) {
    $0.selection.precision = .half
    $0.selection.maximum = 5
    $0.appearance.filled = .warning
}
```

默认五颗星、整星步长、允许清空。最大星数限制为 1–20；显式星形尺寸限制为 10–64pt，间距为 0–24pt。非有限尺寸恢复默认，非有限评分按零显示。展示时只夹紧到范围，不擅自改写绑定，也不把 4.25 等外部评分舍入成半星；用户提交时才按指定步长取整。

| 操作或状态 | 行为 |
| --- | --- |
| 悬停 | 填充预览评分，不提交；离开恢复当前值 |
| 左键按下 | 捕获指针，只预览 |
| 在组件内释放 | 提交释放位置；同一评分再次点击可清零 |
| 拖动后释放 | 提交释放位置；不会触发重复点击清零 |
| 在组件外释放 / Escape | 取消，不改评分，释放捕获 |
| Tab | 整个评分只有一个停靠点 |
| Left / Down、Right / Up | 按整星或半星步长减、加 |
| Home / End | 最小可选值、最大值 |
| Delete / Backspace | 允许清空时置零 |
| Ctrl / Command / Alt 组合键 | 留给宿主快捷键 |
| `allowsClear = false` | 最小用户选择为一个步长；程序仍可提供零值作未评分展示 |
| 只读 | 保留分数显示，辅助功能角色为 image，不参加焦点或指针输入 |
| 禁用 | 降低颜色 alpha，不接受输入，移出 Tab 顺序 |

输入组件提供 slider 辅助功能角色、调用方标签、当前值、“评分 / 最大值”的说明，以及 setValue / increment / decrement 操作。非法辅助功能输入被忽略。原生读屏体验仍需实际 VoiceOver 验证。

尺寸来自最近的 `.controlSize`，显式 `appearance.size` 或 `starSize` 可覆盖。mini / small / regular / large 的星形分别为 12 / 16 / 20 / 28pt；可交互区域至少高 32pt。每星左右各 4pt，加上组件左右各 4pt；宽度受宿主约束时按同一边界裁剪绘制与命中区。

两张自绘 SVG 使用同一星形路径，按实际点数和 drawable 密度栅格化；分数用局部裁剪填充，不依赖文本星号。悬停只标记重绘，保留 SVG 尺寸缓存。键盘焦点绘制 2pt 语义焦点环。主题变化重新解析颜色，节点透明度同时应用到轮廓、填充和焦点环。

外部评分、最大值、步长和几何配置改变时，节点取消原预览和捕获；禁用和只读切换另清除原焦点。卸载自动取消交互和资源注册。

参考本机 GPUI Kit 的 `crates/component/src/rating.rs`：吸收逐星预览、可控最大值、尺寸和禁用的设计。该快照使用整数值，点击已填充星会选中前一星。GuavaUI 明确选择“再次点击当前评分清零”的契约，并增加半星和键盘输入，行为并非逐字复刻。[上游 Rating 源码](https://github.com/longbridge/gpui-kit/blob/main/crates/component/src/rating.rs)。

示例在 `GuavaUIGallery/RatingStory.swift`，可用 `swift run --package-path GuavaUI GuavaUIDemo --component Rating` 打开。9 项 Rating 测试和独立画廊交互测试覆盖真实事件派发、半星命中、提交前的帧、捕获取消、配置变化、卸载、键盘、辅助功能、尺寸、SVG 解码及部分填充裁剪。

原生 Retina 窗口已确认明暗主题、12/16/20/28/36pt SVG、半星和 4.25 填充、禁用颜色、键盘步长、Home/End、清空策略、焦点环、辅助功能写入和独立重置。鼠标整星/半星命中、预览不提交、重复清零、内部拖动提交、外部释放取消及只读/禁用忽略输入也已完成原生验收。[Rating 验证](../guava-ui/evidence/rating-native.json)记录口径和限制。原生点击验收使用的 CUA 坐标仍待后续在输入驱动层稳定复现与修复。

当前边界：水平 LTR 星形布局；未提供 RTL、其他评分图形、触摸专属手势和表单校验集成。
