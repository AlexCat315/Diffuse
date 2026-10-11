# 图标、侧边栏与折叠容器的原生验证

验证日期：2026-10-11，macOS，逻辑窗口 1280×720，drawable 2560×1440，contentScaleFactor = 2。

图片来自 GuavaUI Demo 实际窗口的绘制列表，经应用选定的原生渲染器进行离屏重放，mirror 输出 1280×720 JPEG。它们不是系统合成器截图，也不是 HTML 重画的组件；鼠标、键盘、文字输入经 Demo 的 DevTools InputBridge 进入真实 EventDispatcher。此验证不提供 FPS、完整平台辅助功能或组件成熟度等价结论。

| 检查 | 100% | 200% |
| --- | --- | --- |
| icon.small / medium / large | 12 / 16 / 24 | 24 / 32 / 48 |
| 任意数值 31pt | 31 | 62 |
| 普通 IconButton | 32×32 | 46×46 |
| 加载中的 IconButton | 32×32 | 46×46 |
| 局部固定 IconButton | 32×32 | 32×32 |

`icons-100.jpg` 与 `icons-200.jpg` 来自同一进程中的动态切换。200% 时点击普通图标按钮，动作计数变为 1；加载指示替换图标，保留同样尺寸。

`sidebar-100.jpg`、`sidebar-200.jpg`、`sidebar-dark-200.jpg` 展示原生 SidebarItem 的混合图标项、徽标和主题状态。200% 使用 End 移动到 Settings，跳过禁用的 permissions，滚动显露目标，右侧内容更新为 Settings；键盘焦点环可见。头部换行和底部插槽拥有独立布局，没有覆盖滚动目的地列表。

`accordion-collapsed-200.jpg` 与 `accordion-reopened-200.jpg`：输入项目名称 `Guava Native 200%` 后收起，预览高度从 410 降到 194，输入框卸载；再展开回到 410，编辑内容保留。自动化测试另外覆盖动画反向、过程中内容高度改变、焦点/捕获立即清理、减少动态效果和卸载后的调度器清理。

`tree-200.jpg`：树的行高、缩进、箭头与命中区域使用统一缩放几何，示例在有界 ScrollView 内滚动；超出 250pt 视口的尾行被裁剪，不覆盖选择摘要。

各次截图的相关节点逻辑尺寸、验证命令与边界保存在 [validation.json](validation.json)。可以运行 `GuavaUI/.build/debug/GuavaUIDemo --component sidebar`，或使用 `--component icon / accordion / tree` 打开对应示例，再切换 Scale、主题和交互状态进行复核。

整包测试通过：Compose 576 项、Runtime 246 项；App XCTest 执行 24 项，其中 1 项需显式启用的 release benchmark 跳过，0 失败。最终 Tree 示例修改及跨页状态测试通过 Gallery 7 项回归。所改 Swift 文件使用仓库同一维护性检查器验证，无新增超限；全仓检查另有未暂存 AppDisplayHandle 字段增长，未混入本轮提交。
