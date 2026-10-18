# Badge / Tag / KeyCap / FieldLabel

这些组件分别表达状态、内容分类、键盘提示和输入名称。Gallery 的 `label` 页使用 `FieldLabel` 与 Form；公共 API 没有独立的 `Label` 类型。

| 组件 | 用途与语义 | 可交互入口 |
| --- | --- | --- |
| Badge | 状态文本，`staticText` 的 label 为全文、value 为 tone | 非交互；装饰性实例可用 `.accessibilityHidden()` 并入宿主 |
| Tag | 分类或筛选条件，`group` 保留全文 | 可选 `onRemove`，独立按钮名为 `Remove <全文>` |
| KeyCap | 一键一卡的快捷键提示，`staticText` 使用平台的完整口述形式 | 非交互，显示顺序沿布局方向 |
| FieldLabel | 输入名称及必填/帮助说明 | 指定 targetID 后点击或键盘激活聚焦关联输入；Form 自动建立关联 |

## API 与状态

```swift
Badge("Synchronization pending", tone: .warning) { $0.showsDot = true }
Tag("Workspace reviewers") { $0.onRemove = { removeReviewers() } }
KeyCap(.primaryShift("P"))
KeyCap(["Control", "Option", "Open workspace command palette"])

Form([FormField("name", "Workspace display name", configure: {
    $0.isRequired = true; $0.help = "Visible to your teammates"
}) {
    TextField("Enter a name", text: $name)
}])
```

Badge 与 Tag 默认 `.soft`、`.neutral`、启用；`.solid` 使用 tone 实底与对比 ink，`.outline` 为细边框。两者可配置 icon 或 dot，icon 优先。`isEnabled=false` 使用 disabled ink/透明度，Tag 的移除按钮同步禁用。Badge 永不产生点击行为；Tag 正文也不会冒充按钮。

独立 FieldLabel 用 `options.targetID` 匹配最近 Form（无 Form 时在本场景）内同名的可聚焦输入 `accessibility.identifier`，不使用全局注册；未配置 targetID 时为普通文字。必填符号不进入控件的名称，帮助信息由 Form 建立 describedBy 关联。

## 空间与缩放

- Badge/Tag 的字体、水平/垂直 padding、图标/圆点与间距按 `.controlSize` 的 mini/small/regular/large 解析，文本与图标遵守各自缩放策略。
- 标题在实际剩余宽度内完整换行，不固定行高、不省略尾部；图标和 Tag 的移除按钮不被文本挤小。触摸移除按钮至少 44×44，非交互 Badge 不额外增加命中区。
- KeyCap 在空间不足时按完整 cap 换行；单个长键名也可换行，不截断名称。每个 cap 用 caption、水平 6/垂直 2pt padding、surfaceVariant、细边框和 rowRadius。
- Badge 和 KeyCap 合并装饰性子文本，辅助功能只读一次完整值；Tag 合并文字但保留独立移除按钮。
- FieldLabel 在紧凑 Form 中移到输入上方，长名称完整换行；可激活标签沿用 Button 的触摸下限，文字块保持逻辑 leading，不继承普通按钮的居中排版。
- 调用方在同一行摆放多个实例时使用可换行容器；不要用固定高度或裁剪容器隐藏长值。整个标签是装饰时显式隐藏语义，交互标签保留名称与操作。

## 验收

`CompactLabelTests.matrix` 在 390/720/1280、100%/200%、明暗主题与 LTR/RTL 下，把四类标签放入 220pt 内容区，验证全文换行、边界、移除目标、cap 完整口述，以及标签激活后的真实输入焦点。ProductComponentTests 与 DesignSystemTests 覆盖原有状态、快捷键格式和图标缩放。

Gallery `badge`、`tag`、`keyCap` 加入长文本，`label` 页提供组合展示、移除/恢复和关联输入；三档 DevTools 实际输入与镜像结果记录在[自适应验收](adaptive-spec.md#5-规范完成清单按本文验收)。

## 源码

- [Badge.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Feedback/Badge.swift)
- [Tag.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Tag.swift)
- [KeyCap.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/KeyCap.swift)
- [FieldLabel.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/FieldLabel.swift)
- [Form](form.md)
