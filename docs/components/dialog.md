# Modal / Dialog / AlertDialog

`Modal` 提供窗口级浮层、遮罩、焦点范围和关闭策略；`Dialog` 在其上提供固定标题、滚动正文和操作区；`AlertDialog` 组合确认/取消与忙碌状态。调用方只持有 `Binding<Bool>` 和业务动作，页面需在 `LayerRoot` 内。

```swift
Dialog(isPresented: $editing, title: "Edit profile", configure: {
    $0.description = "Changes apply to this workspace"
}) {
    TextField("Name", text: $name)
} footer: {
    Button("Cancel") { editing = false }.buttonStyle(.secondary)
    Button("Save") { save(); editing = false }
}
```

## 布局

- Modal / Dialog 默认 760×560pt、16pt 外边距、主题表面与细边框；居中呈现遇到 compact 窗口（<600pt）时宽度为窗口减两侧各 8pt，显式更小的 inset 保留。侧边 Sheet / BottomSheet 使用各自的几何契约。
- Dialog 标题与说明自然换行，正文独立滚动，header/footer 不随正文滚走。默认关闭按钮有可读名称；无关闭按钮时仍由业务提供取消路径。
- 操作区按调用方声明顺序排列。compact 纵向堆叠；其他宽度横排靠 trailing，总自然宽度放不下时也转为纵排。RTL 解析逻辑 trailing，操作节点不因重排重建。
- AlertDialog 按内容高度收拢，默认宽 420、高度上限 `max(280, TextScaler.scale(200) + 80)`；200% 上限为 480pt，长正文独立滚动。高度还受实际窗口可用范围限制，字号只由文本系统缩放一次。危险确认使用 error 实底，表面使用 `surfaceFloating`、主题轻阴影与细边框。
- 自定义 Dialog 的 `modal.geometry.height` 是调用方显式约束，应为标题、操作与正文留足空间；低矮窗口中正文可以滚动，不能靠缩小触摸目标容纳内容。

## 输入与状态

- Tab / Shift+Tab 在模态内循环；打开后焦点进入，关闭后回到有效的原触发器。Escape / 遮罩由 `ModalDismissal` 配置，正文点击不触发遮罩关闭。
- Button 继承 touch ≥44pt、hover gating、键盘焦点环与 disabled/loading 契约；辅助功能为命名的 dialog 和真实按钮。
- AlertDialog 的 `isConfirming` 禁用 Cancel/Confirm 并阻止 Escape / 遮罩关闭；`dismissAfterConfirm` 决定同步回调后是否关闭。异步业务自行管理 `isConfirming` 与打开 binding。
- 打开态、草稿、焦点、滚动均属 session，不进入持久化；减少动画关闭进出运动。

## 验收

`DialogAdaptiveTests.matrix` 覆盖 390/720/1280、light/dark、100%/200%、触摸/混合/指针输入，断言 374/420pt 面板、紧凑按钮纵排、触摸目标、完整短标题、可见正文、有限几何与辅助功能确认去重。`retention` 验证 720→390→1280→720 的动作节点、编辑草稿与字段焦点保留。模态焦点与关闭回归复用既有 Modal/Sheet 测试。

2026-10-18 DevTools：390×820 touch/200% 的 Cancel/Delete 为 103×50 / 98×50、纵向相隔 8pt；720×820 dark/mixed 的 Cancel/Save 同行且命中高 44，完整显示短标题；1280×820 dark/pointer 的确认框按内容收拢、两按钮同行。390 点击 Delete 后 AI 查询为 `Example deleted`；720 在 Name 中输入 `Guava Studio` 并 Save 后为 `Name: Guava Studio`。镜像实际查看确认正文换行、危险色、轻边框、表面层次与按钮可达。被其他测试窗口遮挡时仍完成进场动画，相关时钟修复见 DevTools README。

Gallery `dialog` / `alertDialog` 提供真实打开、编辑、确认/取消与三档预览。AI 验收通过 [DevTools](../../GuavaUI/DevTools/README.md#ai-driven-component-acceptance) 查询 dialog 与按钮几何、执行操作并查看镜像。

源码：[Modal](../../GuavaUI/Sources/GuavaUICompose/Primitives/Overlays/Modal/)。
