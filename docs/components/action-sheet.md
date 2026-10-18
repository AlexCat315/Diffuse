# ActionSheet

将一组相关操作放在底部抽屉中。所有宽度都使用抽屉：compact 表面是全宽面板，顶部只有拖拽柄；medium/expanded 是底部居中、最大 560pt 的抽屉，并在右上提供关闭图标。组件自身不写任何界面文案；`closeLabel` 由调用方传入，供宽屏关闭图标本地化使用。

```swift
ActionSheet(isPresented: $actionsOpen, title: "Project actions",
            message: "Choose an action for this project.", actions: [
    ActionSheetAction("duplicate", "Duplicate", icon: UIIcons.Action.copy) { duplicate() },
    ActionSheetAction("delete", "Delete", role: .destructive) { delete() }
], closeLabel: String(localized: "Close actions")) {
    Text("More actions")
}
```

## 数据与行为

调用方持有打开状态和操作数组。`ActionSheetAction` 接收稳定且同组唯一的 String ID、完整标题、可选图标、ButtonRole、isEnabled 和回调；不要求改造业务类型。

`closeLabel` 是必填参数，作为 wide 抽屉右上关闭图标的辅助功能名称与 tooltip；compact 不显示关闭图标，避免手机端多一个重复的退出入口。组件不内置 Cancel 文案、默认英文名称或底部取消行；所有用户可见/可读文案都由调用方本地化。

触发器是 secondary Button，保留 expanded、完整名称、禁用与触摸尺寸；额外说明不会自动变成重复 tooltip。`isEnabled: false` 或空操作数组禁用触发器并关闭已打开的面板。仅所有操作都禁用时仍可打开，通过下拉、外部点击或关闭图标退出。

点击操作先关闭，再执行一次回调。关闭图标（wide）、Escape、外部点击和再次点击触发器只关闭，不执行命令；禁用行不能执行。关闭或卸载释放输入与 Portal，关闭后还原触发器焦点。

## 外观与空间

- 抽屉随内容确定高度：compact 宽等于窗口宽、贴底，保留宿主底部安全区；medium/expanded 宽为 `min(560, 窗口宽 − 24)`，距窗口 12pt，四角圆角 18pt。
- 顶部是固定区：compact 的 44pt 拖拽区（36×4pt grabber 居中）独占顶部；medium/expanded 的右上角是 44pt 关闭图标。标题、可选说明紧随其下。操作列表在下方独立滚动，长列表不会把顶部控件或标题推出窗口。
- 操作行至少 44pt，文字随 TextScaler 增长并换行；危险操作使用红色文字与图标，禁用项使用 onSurfaceDisabled。wide 关闭图标保持 44×44pt 命中区域。
- 操作行之间使用 1pt 分隔线；hover 与键盘焦点只叠中性 state layer，不绘制 accent 焦点描边，避免选中态出现突兀的蓝色边框。
- compact 支持下拉关闭：向下超过 80pt，或释放时向下速度超过 900pt/s；短距离拖动回弹。所有宽度都支持点击遮罩关闭。打开期间跨越宽度阈值只保留一个有效 Portal，并保留打开状态与触发器节点。

## 键盘与辅助功能

焦点进入第一个启用操作；Up/Down 循环并跳过禁用项，Home/End 到首尾并滚动显露。操作组采用单一 Tab 停靠；wide 抽屉 Tab 会继续移动到右上关闭图标。Enter/Space 执行当前按钮，Escape 关闭。wide 关闭图标是真实 Button，label/help 使用调用方传入的 `closeLabel`；所有行都是真实 Button，行内图标为装饰，抽屉提供完整 dialog 标题和说明。

## 验收与边界

`ActionSheetTests` 验证 wide 关闭图标/执行一次/焦点还原、Escape/外部点击、compact 拖拽关闭与短拖回弹、compact 无关闭图标、行间分隔线、聚焦态无 accent 描边、禁用/卸载、跨宽度抽屉几何、长列表滚动与安全区，以及 390/720/1280 × 100%/200% × 明暗 × 指针/触摸 × RTL 矩阵、调用方中文关闭名称和真实 AI 查询。Gallery 的 ActionSheet 页包含项目命令、禁用 Export、执行结果、长列表与三种自适应预览。

当前不提供异步执行中的加载状态、多档 detent 或命令子菜单。异步进度由调用方在执行后呈现；需要可拖动多档高度使用 BottomSheet，需要分层命令使用 Menu。
