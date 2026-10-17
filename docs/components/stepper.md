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

`StepperOptions` 管理方向、整体可用性、循环策略、辅助功能名称和横向步骤预算。外层 `.controlSize`、主题及减少动画偏好继续生效。步骤图标同时使用数字、完成/失败符号和忙碌指示；辅助功能值提供序号及结果。

窄宽重排：横向布局按每步 `minimumHorizontalStepWidth`（默认 148pt）加每段 24pt 连接线计算预算；容器不足时切换到纵向堆叠。宽/窄两套布局分支都被保留，切换只改变可见分支，不重建调用方绑定；步骤行高、说明文本和触摸目标不被压缩。390pt 触屏下三步骤会纵向排列，720pt 保持单行。

键盘 Tab 只停靠一个可用步骤。横向使用 Left/Right，纵向（包括窄宽自动堆叠）使用 Up/Down；Home/End 定位边缘，默认到达边界后停止。锁定步骤不接受选择。空集合没有操作和焦点停靠；无效或缺失选择使用首个可用步骤作为 Tab 入口，不擅自修改调用方绑定。

真实示例：`swift run --package-path GuavaUI/Examples GuavaUIDemo --component stepper`。示例可启动、失败、完成、解锁 Review，并切换横/纵向、密度、主题和禁用状态。`NarrowReflowTests.stepperReflow` 覆盖 390pt 堆叠、720pt 单行、轴感知方向键与 44pt 触摸高度。

RTL 与超长标题的逐字换行仍未提供；标题更长的调用方应提高 `minimumHorizontalStepWidth`，让堆叠更早发生。行为与验证边界详见 [GPUI Kit 对照审计](standard.md)。
