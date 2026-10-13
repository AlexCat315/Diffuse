# Stepper

`Stepper` 是受控的流程导航，不是数字输入框。步骤结果由调用方持有，选中另一步不会改写已完成或失败的状态。

```swift
@State var selected: String? = "details"

Stepper([
    StepperItem("account", "Account") { $0.status = .completed },
    StepperItem("details", "Details") { $0.detail = "Configure your workspace" },
    StepperItem("review", "Review") { $0.isEnabled = false }
], selection: $selected) {
    $0.axis = .horizontal
    $0.label = "Project setup"
}
```

`StepperItem` 持有稳定 ID、标题、说明、状态和可用性；ID 必须唯一。状态包含 `pending`、`inProgress`、`completed`、`failed`。选择是导航目的地，状态是业务结果，两者独立。动画、按压和焦点不进入这些业务值。

`StepperOptions` 管理方向、整体可用性、循环策略和辅助功能名称。外层 `.controlSize`、主题及减少动画偏好继续生效。步骤图标同时使用数字、完成/失败符号和忙碌指示；辅助功能值提供序号及结果。

键盘 Tab 只停靠一个可用步骤。横向使用 Left/Right，纵向使用 Up/Down；Home/End 定位边缘，默认到达边界后停止。锁定步骤不接受选择。空集合没有操作和焦点停靠；无效或缺失选择使用首个可用步骤作为 Tab 入口，不擅自修改调用方绑定。

真实示例：`swift run --package-path GuavaUI/Examples GuavaUIDemo --component stepper`。示例可启动、失败、完成、解锁 Review，并切换横/纵向、密度、主题和禁用状态。

目前未提供 RTL、自动换行或适合极窄视口的替代布局；这些仍属于后续工作。行为与验证边界详见 [GPUI Kit 对照审计](../guava-ui/gpui-kit-audit.md)。
