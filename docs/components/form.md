# Form / PropertyGrid

两者负责标签与值槽的布局，业务值由调用方的 binding 保存。Form 提供字段帮助、校验摘要与提交区；PropertyGrid 提供分组、折叠、嵌套区段及滚动。

## Form

```swift
Form([
    FormField("name", "Display name", configure: {
        $0.isRequired = true
        $0.help = "Visible to teammates"
    }) { TextField("Name", text: $name) },
    FormField("email", "Email") { TextField("Email", text: $email) }
], controller: controller, configure: {
    $0.columns = 2
    $0.labelPlacement = .adaptive
    $0.labelWidth = 120
    $0.minValueWidth = 220
}) {
    Button("Save") { save() }
}
```

`columns` 是最大列数，空间不足时减少到单列。字段始终位于同一 Grid 子节点集合中，改变列数只改变位置；不通过重建行容器来搬动输入。footer 自动换行，错误与帮助文字自然增高。

字段 ID 在本 Form 内唯一。关联标签只查找所属 Form 的输入，不要求不同表单对相同的业务字段另造全局 ID。帮助、必填、错误与名称传入辅助功能；校验策略由 FormController / 调用方管理。

## PropertyGrid

```swift
PropertyGrid([
    PropertyGridSection(id: "identity", title: "Identity", rows: [
        PropertyGridRow(id: "name", label: "Display name") {
            TextField("Name", text: $name)
        }
    ], isCollapsible: true)
], labelWidth: 96, minValueWidth: 220, labelPlacement: .adaptive)
```

`.twoColumn` 行默认按可用空间切换标签位置；`.fullWidth` 保持标签在上、内容在下。默认 `sizing: .intrinsic`，rowHeight 为下限，值内容自然增长。显式 `.fixed` 会约束值槽或 fullWidth 行的总高度预算，但仍应用文字缩放、平台命中下限及标签所需空间。行的输入语义继承行名称。

`scrollAxes` 决定滚动轴，不再决定标签和值槽的最小宽度。默认 both 也使用真实视口来决定重排；不会先把内容强撑到 labelWidth + minValueWidth，导致窄宽永远无法切换。分组折叠可由调用方控制，也可使用节点会话中的本地状态。

## 共享的响应式与输入密度

| 配置 | 规则 |
| --- | --- |
| `labelPlacement = .adaptive` | 当前字段宽度 ≥ 缩放后的 labelWidth + 标签间距 + minValueWidth 时前导并排，否则标签堆叠在值上方 |
| `.leading` / `.stacked` | 显式固定标签位置；固定 leading 的调用方应提供足够宽度 |
| `labelWidth` | authored 标签列宽，按 TextScaler 缩放一次 |
| `minValueWidth` | 同一语义的逻辑点首选值槽宽度，用于列数与标签位置的决策；极窄时单列填满当前宽度，不强撑窗口 |

判断依据是字段自身的内容盒，嵌入窄卡片时不会因窗口很宽而错误保留双列。标签位置只改变 Box 的方向；输入、绑定、草稿、光标与焦点继续使用原节点。文字与控件使用继承主题，标签完整名称进入 tooltip 与辅助功能。

PropertyGrid 的普通行与可折叠标题允许按内容增长；touch surface 的输入、标题命中至少 44pt。切回 pointer 恢复 authored 下限并保留字体缩放，touch-only 不显示被动 hover。显式传入的固定尺寸内容仍是调用方约束。

## 验收

- `Adaptive/FieldLayoutTests.swift`：390/720/1280pt、100%/200%、触摸/混合/指针，实际文本输入、焦点与节点保留、标签位置、列数重排、重复字段 ID 的标签关联。
- 同一测试通过 `GuavaUIAgent` 的 `UIDiagnostics.queryNodes` 查询真实字段标签、节点身份与窗口位置，验证与 AI 工具共用的诊断入口。
- Portable `StructuralModifierTests`：修饰条件/数组时保留子视图状态；数组插入与重排保留 key，真正移除后重新挂载使用默认状态。
- `PropertyGridSizingTests`、`ButtonScrollViewTests`：内在高度、折叠、滚动及 hover 不持续重组；初次容器查询完成后必须空闲。
- Gallery `--component form|propertyGrid`：可交互故事与窄/宽/触摸预览；Android / iOS 设备触摸与读屏仍按 [跨平台矩阵](adaptive-spec.md#41-取样矩阵) 验收。

源码：[Form.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Form.swift)、[Form/LabelPlacement.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Form/LabelPlacement.swift)、[PropertyGrid.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/PropertyGrid.swift)。通用省略号截断仍按规范第 5-6 项推进。
