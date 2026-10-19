# Rating

`Rating` 是受控的评分组件（默认星形，可换图形），值来自 `Binding<Double>`。`RatingSelection` 管理选择规则；`RatingAppearance` 管理尺寸、间距和语义颜色。悬停和按下状态归挂载节点所有，不写入评分值。

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
| Left / Down、Right / Up | 按一份精度减、加；加 Shift 按整图形 |
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

示例在 [RatingStory.swift](../../GuavaUI/Examples/Sources/GalleryContent/Stories/Feedback/RatingStory.swift)，可用 `swift run --package-path GuavaUI/Examples GuavaUIDemo --component Rating` 打开。Rating 测试族和独立画廊交互测试覆盖真实事件派发、半星命中、提交前的帧、捕获取消、配置变化、卸载、键盘、辅助功能、尺寸、SVG 解码及部分填充裁剪。

当前验收使用 `RatingTests` 与 Gallery 自有 DevTools 输入/查询/镜像，覆盖明暗主题、尺寸、部分填充、清空、焦点与捕获生命周期；未保存的旧坐标记录不作为当前通过依据。RTL 的直接触摸与方向键验收记录见 [自适应验收](adaptive-spec.md#5-规范完成清单按本文验收)。

## 精度与图形

`RatingPrecision` 把每个图形等分为 1–20 份：`.whole`、`.half`、`.quarter`、`.tenth`，或 `.divisions(n)`。提交值按精确分数取整（`0.1 + 0.2` 记为 `0.3`）。指针候选按图形本身（而非含留白的单元格）计算比例并向上取整，因此触到图形前缘至少选中一份；落在分界上的点不会因浮点误差跨入下一份。方向键移动一份，Shift + 方向键移动一个整图形，细精度下仍能快速遍历。

`RatingAppearance.symbol` 接受任意单色“填充 / 轮廓”图标对，内置 `.star` 与 `.heart`。两者都作为着色遮罩绘制，颜色仍由 `filled` / `empty` 语义色决定；尺寸或图形变化时重建栅格缓存并重绘。

```swift
Rating("Favorite level", value: $level) {
    $0.selection.precision = .quarter
    $0.appearance.symbol = .heart
    $0.appearance.filled = .error
}
```

RTL 已镜像星位、部分填充裁剪、指针候选和左右方向键；上下方向键保持增减语义。当前边界：表单校验集成仍未提供。

## 响应式与输入密度

可交互 Rating 在 touch surface 上为每颗星保留至少 44pt 的命中 lane，组件高度至少 44pt；星形仍使用 authored starSize 并在 lane 中居中。半星按 lane 的左右半区选择。touch-only surface 不产生被动 hover preview，但按下后的拖动仍可预览；只读评分保留紧凑展示尺寸。

## Gallery 窄宽组合

评分原语保留固有星位与触摸 lane；示例将分数和可换行操作放在独立下行，避免与星带争抢宽度。多星使用有界横向 ScrollView（底部保留滚动条），滚动坐标为 LTR，但评分本身显式继承外部方向；RTL 星序与键盘语义保持。拖动滚动条或横向滚轮可以显露两端星位，不能仅依赖卡片裁剪。

`RatingLayoutTests.matrix` 覆盖 390/720/1280、100%/200%、明暗主题和 LTR/RTL；验证星带视口、评分说明边界和方向键。Gallery 原有 `ratingPointer` 继续验证真实指针提交。DevTools 三档 Set 4 均得到 4.0；390 RTL 十星带横向滚轮后 offset=180，拖动滚动条到 198，再点击原本隐藏的第一颗得到 1.0。三档镜像确认说明/按钮不越界，十星保留滚动条且无卡片外溢。

- [RatingSample.swift](../../GuavaUI/Examples/Sources/GalleryContent/Stories/Feedback/RatingSample.swift)
- [RatingLayoutTests.swift](../../GuavaUI/Examples/Tests/GalleryContentTests/RatingLayoutTests.swift)

精度与图形验收：`RatingTests.fractionalPrecision` 覆盖等分夹紧、精确取整、十分之一指针命中与 Shift 整图形步进；`customSymbol` 覆盖图形切换重建栅格。DevTools 在 1280 Gallery `--component rating` 中点击十分星第三颗约 30% 处得到 2.4（分界浮点误差已加容差修正），Shift+→ 得到 3.4；镜像确认十分星与四分之一心形的部分填充贴合图形边缘。
