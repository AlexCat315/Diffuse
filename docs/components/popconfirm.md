# Popconfirm

由触发按钮打开的轻量确认气泡。适合删除、归档、丢弃等需要明确确认的动作；气泡通过窗口 Portal 绘制，能越过局部裁剪，复用焦点、外部点击和 Escape 关闭机制。

```swift
Popconfirm("Delete", icon: UIIcons.Action.trash,
           title: "Delete this project?",
           message: "This cannot be undone.",
           confirmTitle: "Delete", role: .destructive) {
    deleteProject()
}
```

## 外观与尺寸

触发器沿用 secondary 按钮；destructive 使用红色文字与图标。只有气泡中的确认按钮使用 error 实底，避免把“打开问题”和“执行删除”画成同一动作。

卡片与三角指针复用 [Popover](popover.md) 的同一个绘制节点，使用不透明的 surfaceFloating、1pt border、主题圆角与 low 阴影。标题为 bodyStrong，说明为 onSurfaceVariant，Cancel 为 secondary，Confirm 为 primary/destructive。按钮是真实 Button，保留悬停、按下、禁用、焦点、触摸尺寸与辅助功能行为，不自动显示重复的标题提示。

卡片首选宽 280pt，外围每侧 10pt 用于指针与阴影，Portal 首选宽为 300pt。更窄的窗口会收缩到窗口边距以内；标题与说明换行，按钮在空间不足时换行。触摸和混合输入目标至少 44pt；200% 字体保留完整说明和操作。窗口高度不足时沿用 Portal 的内部滚动。

## API

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| triggerTitle | 必填 | 触发器完整名称 |
| icon | nil | 装饰性的前导图标 |
| title | 必填 | 确认问题，也作为 dialog 的完整名称 |
| message | 空字符串 | 可选说明 |
| confirmTitle | Confirm | 执行按钮名称 |
| cancelTitle | Cancel | 取消按钮名称 |
| role | normal | destructive 使用红色触发文字与确认按钮 |
| placement | bottom | 首选方位和对齐 |
| isEnabled | true | 禁用打开；已打开时立即开始关闭 |
| onConfirm | 必填 | 先关闭，再执行一次 |

### 定位

| 上方 | 下方 | 前导侧 | 尾随侧 |
| --- | --- | --- | --- |
| topLeading / top / topTrailing | bottomLeading / bottom / bottomTrailing | leadingTop / leading / leadingBottom | trailingTop / trailing / trailingBottom |

复用 `PopoverPlacement`。Leading/trailing 随触发器的实际布局方向解析，气泡内容也继承该方向。指定方位保持不变：top 在上方、bottom 在下方，侧向同理；空间不足时限制该侧可用尺寸并滚动，保留窗口 8pt 边距。箭头跟随触发器中心并避开卡片圆角；滚动、重排或移动触发器后重新定位。需要自动翻边的普通浮层可使用 Popover 的显式 `overflow: .flip`。

## 交互

- 点击、Enter/Space 或辅助功能激活触发器打开，触发器暴露实时 expanded。
- 焦点进入 Cancel；Tab 在 Cancel/Confirm 之间循环。Cancel、Escape、外部点击、再次点击触发器均只关闭。
- Confirm 先关闭再执行；重复调用已关闭气泡的旧动作不会再次执行。
- 关闭后还原触发器焦点。禁用或卸载时释放 Portal、焦点与输入，不留下透明按钮。
- 主题、字体、问题文字在打开期间更新，不生成第二个气泡；减少动画遵循共享 Portal 过渡。
- 跨窗口数据与后续操作由调用方管理；组件不持久化打开状态。

## 验收

PopconfirmTests 验证确认仅执行一次、取消与各关闭路径、Tab 循环/焦点还原、禁用/卸载、打开后的内容更新、真实 AI query_ui_nodes 发现及关闭后的隐藏。布局/绘制矩阵覆盖 390/720/1280pt、100%/200%、明暗主题、指针/触摸/混合和 RTL；12 向同时验证真实 Portal 保持指定侧、尺寸约束，以及显式翻边策略。绘制回归还检查非零绘制原点，防止气泡背景再次落在窗口原点。

Gallery 的 popconfirm 页包含 Delete/Archive、执行结果、禁用开关、12 向定位示例和三种容器/输入预览。

### 2026-10-18 原生验收

通过 GuavaUI 自带 DevTools 的 `query_ui_nodes`、节点点击/键盘输入与 Metal 渲染捕获验收，未使用系统界面自动化。

| 窗口 / 字号 / 主题 | 验收结果 |
| --- | --- |
| 1280×820 / 100% / 明、暗 | 十二向均保持指定侧；卡片与箭头连续、背景不透字，Cancel 无重复 tooltip |
| 1280×820 / 200% / 暗 | 标题、说明、操作完整；定位预览高度随字号增长，按钮不越界 |
| 720×820 / 100% / 明 | 十二向均保持指定侧；Left 在该侧收窄并换行；普通 Popover 表单使用同一张卡片，Done 关闭 |
| 390×820 / 100% / 明 | 切换为方向选择器 + 单锚点预览；十二向保持指定侧且位于窗口内 |
| 390×820 / 200% / 暗 | 十二向保持指定侧；侧向卡片按剩余空间收窄，操作换行，高度不足时内部滚动 |

真实操作验证 Cancel/Escape 后 `Last action: None`，确认 Delete/Archive 后分别变为 Deleted/Archived。自动化验证包括 `PopconfirmTests` 7 项、Button 显式 tooltip 回归、Gallery 大字号定位预览边界；完整 GuavaUI Compose 892 项、Runtime 320 项及 Gallery 28 项通过。Editor 调用已迁移；EditorUI 联编仍受已有的 ScrollView 内容构建错误阻塞（EditorOutputPanel、ParticleDiagnosticsView、DeveloperProfilerPanel）。

## 边界

暂不提供异步确认中的 loading 状态、自定义触发 View 或宽度配置；应用可在确认后显示进度。ActionSheet 仍为单独的待补组件。
