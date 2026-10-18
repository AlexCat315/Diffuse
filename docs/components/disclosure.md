# Accordion / DisclosureGroup

两者都把展开状态交给调用方，并用 `AnimatedVisibility` 管理内容过渡。标题保持单行，长标题省略到尾部，全文保留在 tooltip 与辅助功能名称中；正文默认自然换行。容器放在外层 ScrollView 内，使展开内容可滚动到达。

```swift
DisclosureGroup("Project details", isExpanded: $expanded) {
    TextField("Description", text: $description)
}

Accordion([
    AccordionItem("general", "General") { GeneralSettings() },
    AccordionItem("privacy", "Privacy") { PrivacySettings() }
], expanded: $expandedSections)
```

- `DisclosureGroup` 是独立 Button 头部，Space/Return 展开。自定义 `label:` 可组合任意 View；需要多行标题时由自定义 label 明确声明，字符串入口遵守单行契约。
- `Accordion` 单一 Tab 停靠，Up/Down/Home/End 在启用头部间移动，Return/Space 展开；`allowsMultiple` 默认 false，选中新段收起旧段。
- 触摸头部至少 44pt；字号增大时保留一行真实行高，chevron 不参与截断。hover 与键盘焦点使用主题状态色。
- 辅助功能头部提供完整名称、`isExpanded` 和启用态。关闭立即释放内容的焦点/捕获并禁用输入，退出动画结束后卸载内容；需要跨卸载保留的草稿由调用方持有。
- 减少动画立即切换；容器不拥有持久化格式，也不注册全局快捷键。

`DisclosureAdaptiveTests.headers` 在 390/720/1280 surface、220pt 卡片、light/dark、100%/200% 下验证单行几何、完整语义、44pt 触摸与键盘展开。`DisclosureContainerTests` 验证缩放行高、禁用跳过、焦点与退出生命周期；Gallery `accordion` / `disclosure` 包含可交互长标题。

2026-10-18 DevTools：390×820 dark/touch/200% 的 disclosure 头部为 286×46pt，标题保持一行省略、chevron 完整，AI 名称保留全文；点击后 `isExpanded` 从 true 变 false。720×820 mixed 的长标题 Accordion 头部为 560×44pt，点击后展开；1280×820 pointer 的 disclosure 为 929×28pt。三张镜像实际检查了长标题、输入框、禁用态、圆角分组与宽窄密度。

源码：[Accordion.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/Accordion.swift)、[DisclosureGroup.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Layout/DisclosureGroup.swift)。
