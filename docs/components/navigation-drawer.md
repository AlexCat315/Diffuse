# NavigationDrawer

带标题和关闭按钮的模态导航抽屉，复用 Sidebar 的目的地、图标、徽标、禁用项与键盘导航。应用只提供标题、受控的展开状态和选择；不需要注册全局对象或管理焦点、Portal。

```swift
@State private var navigationOpen = false
@State private var destination: String? = "overview"

Button("打开导航") { navigationOpen = true }
NavigationDrawer("工作区", isPresented: $navigationOpen,
                 selection: $destination, sections: sections) {
    $0.closeLabel = "收起导航"
    $0.closesOnSelection = true
    $0.allowsSwipeDismissal = true
}
```

自定义 `header` 与 `footer` 的初始化器可插入账户信息、说明和底部操作；标准标题/关闭按钮始终位于最上方。

`expanded` 可选传入 `Binding<Set<ID>>`：抽屉、常驻栏和 Rail 可共享同一嵌套展开会话；省略时各呈现自己持有展开状态，关闭抽屉再打开仍保留本地集合。

## 尺寸与输入

宽度为 `min(320, max(0, 实际窗口宽度 − 56))`，高度填满窗口，从 leading 边缘进入。计算来自 Portal 所属窗口的实际布局，不使用调用处卡片尺寸或可能过期的 surface width。打开时改变宽高、主题、字号或输入集合，会重新计算尺寸并保留当前节点、选择及仍挂载的 header/footer 状态。遮罩与普通 Modal 共用主题 `overlay`，默认明暗主题均为中性黑色透明层，不再借用蓝色选中态；背景接收不到输入。

目的地行高至少 44pt，长标题换行；200% 文字按内容增长，折叠按钮保持独立的 44pt 命中区。Sidebar 负责初始选中项和应用主动改变选择后的显露。方向键/Home/End 浏览且跳过禁用项，不会关闭；点击、Enter、Space 激活目的地后才按 `closesOnSelection` 决定是否关闭。

打开时焦点进入抽屉，保留触发时的输入模态：指针/触摸打开不会自动显示键盘焦点框或按钮提示，键盘打开及后续 Tab 仍有焦点反馈和说明。Tab/Shift-Tab 在内部循环。Escape、遮罩左键分别由 `dismissal.closesOnEscape`、`dismissal.closesOnBackdrop` 控制；遮罩右键不关闭。头部前导侧提供 44pt 侧栏折叠图标，与 AdaptiveSidebar 的展开图标一致，不使用 X；`closeLabel` 默认 "Collapse navigation"，调用方提供本地化的收起名称，同时用于辅助功能与 tooltip。按钮暴露 `expanded=true`，始终可收起。标题过长时省略并保留完整名称与 tooltip。关闭后恢复原来仍有效的焦点及其输入模态。语义角色为 `dialog`，名称为完整标题。

`allowsSwipeDismissal` 默认开启：左滑超过 `max(32pt, 抽屉宽度 × 15%)` 后松手关闭，短滑、右滑和纵向意图不关闭。水平意图出现后取消子按钮的按下，避免松手又触发目的地；正在捕获输入的文本选择等不可取消控件保留自己的交互。关闭、禁用手势或卸载会释放捕获。当前使用按钮唤出，不提供屏幕边缘唤出手势。

## 生命周期与验证

进入/退出复用 Modal/Sheet 的 medium motion，遮罩淡变、面板按实际宽度移动；关闭立即阻断内容输入，退场完成后卸载，期间再次打开沿原节点反转。减少动画时立即完成。`isPresented` 和选择属于应用会话，不写入文档；旋转不会把它们重置。彻底关闭后，内容局部状态随 Portal 卸载；需要跨关闭保留的草稿由应用通过 binding 持有。

`NavigationDrawer` 提供覆盖层形态；expanded 常驻栏已有 `Sidebar`，紧凑轨道已有 [NavigationRail](navigation-rail.md)。[AdaptiveSidebar](sidebar.md#自适应壳层) 已统一按宽度切换三种形态，保留同一导航和页面节点，并提供可选的紧凑触摸边缘唤出。

`NavigationDrawerTests` 覆盖 280/390/720/1280pt、100%/200% 字号、明暗主题、三类输入、窗口变化时节点/草稿保留、焦点循环与恢复、选择显露、独立关闭策略、手势与按下取消、动画反转和卸载。Gallery 新增 `--component navigationDrawer`、三种输入/宽度预览；Sidebar 页的 “Open as drawer” 与原栏共享选择，`DrawerTests` 通过真实事件分发验证。

macOS 原生 DevTools 已通过实际窗口输入从关闭态打开抽屉，按 `dialog` 角色验证位置、320pt 宽度、满窗口高度及选中项完整可见，并用 mirror 检查标题、折叠按钮、导航与遮罩呈现。

DevTools AI 的 `query_ui_nodes` 支持 `input_enabled_only: true`，排除被当前模态阻挡的背景控件。输入权限取自节点所属场景的焦点作用域，查询在窗口帧之间执行也有效；支持嵌套模态与附属浮层，不读取私有草稿。设备触摸与读屏仍按[规范第 4 节](adaptive-spec.md)取样。

2026-10-19 通用导航交互回归：自身 DevTools 在 390×640 触摸、390×820 深色混合 200%、720×820 深色混合 200% 主壳层及 1280×820 指针独立抽屉中通过 `query_ui_nodes`、`input-ui`、`capture-ui --settle-ms 1000` 检查开合、外部点击、Escape、键盘导航和镜像。紧凑展开/收起均位于 (12,4) 的 44×44pt 区域，指针打开后没有默认提示/焦点框，外部点击后可见 dialog 数量为零；中性遮罩保留背景层次。`FocusChainTests` 覆盖自动/延后/嵌套焦点及无效还原目标的模态保留；`AdaptiveSidebarTests.togglePresentation`、`NavigationDrawerTests.pointerPresentation` 和三种输入的 Button tooltip 回归验证共同行为。
