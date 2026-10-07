---
path: /zh/docs/guava-ui
title: GuavaUI 设计系统
description: GuavaUI 的表面层级、颜色、间距、动效和组件契约。
locale: zh
translationKey: docs.guava-ui
category: 参考
order: 60
kind: doc
---

# GuavaUI 设计系统

GuavaUI 是 SwiftUI 风格的声明式界面系统。设计系统不只定义视觉值，还定义组件在布局、输入、焦点和动画中的默认行为。

## 表面层级

`ColorScheme` 把背景组织为 `background`、`surface`、`surfaceVariant`、`surfaceSunken`、`surfaceRaised`、`surfaceFloating` 和 `surfaceOverlay`。组件应消费语义颜色，不在调用处临时计算亮暗色。

GuavaUI 通用默认主题使用接近 `#1E1F22` 的窗口背景、蓝色交互强调和紫色辅助强调。Editor 通过 `EditorVisualTheme` 提供独立的中性炭灰表面和绿色强调：深色 `#5FAF82`、浅色 `#277B50`。悬停、按压、焦点、选择与输入边框使用配套语义色，代码编辑器使用同一表面层级。网站保留独立的品牌色。

框架的结构为声明式 View → ViewGraph／Node 重组与状态订阅 → Yoga 布局 → DrawList／GPU 绘制。事件分发、焦点和浮层由 Runtime 管理；Workspace 模块管理面板、分组、分割和折叠；App 模块负责窗口与应用桥接。Editor 在这些公共能力之上定义领域、面板内容与视觉主题。框架提供机制，编辑器仍需统一信息层级和组件用法。

## 组件约定

- 编辑器标题栏与工具条统一为 32pt，常规输入框和按钮 28pt，视口内小控件 24pt；圆角使用 4／6pt，间距使用 6／8／12pt，并提供 focus ring。
- 文本输入默认垂直居中、裁剪内容，并使用主题间距作为 inset。
- hover、press、selected 和 focused 使用状态层合成。
- Box、Row 与 Column 默认不参与命中测试。

编辑器面板还遵循以下工作台约定：工具条使用统一水平 inset；搜索行必须提供清除能力与结果计数；图标按钮必须提供 tooltip；无数据、无选择和无搜索结果必须使用解释原因的空状态，而不是留下空白区域。

## 组件参考

完整的结构、尺寸、Token、状态矩阵、键盘行为和 Authoring rules 见[组件索引](components/README.md)。

密集工具条采用 `ToolbarToggleButtonStyle`：选中使用灰阶表面与绿色图标，不使用整块主按钮填充。主按钮才使用强调色实底。面板标题只出现一次，工具切换放在停靠栏；`WorkspaceTheme.tabBarHeight` 控制标题高度，手动编辑与 Agent 共用折叠、展开和最大化机制。


## Editor 的工业主题与动效

| 角色 | 深色值 |
| --- | --- |
| App 背景／输入凹槽 | `#111515` |
| Panel 内容 | `#171C1B` |
| Toolbar／Header | `#1D2321` |
| Active／选中列表 | `#252D2A` |
| 主文字／次要文字 | `#E6EAE8`／`#A6AEAA` |
| 占位符／禁用文字 | `#717976`／`#505653` |
| 强调／hover 强调 | `#5FAF82`／`#69B98B` |

绿色用于当前工具、页签指示、主操作、开启的开关、成功状态与焦点；列表和资源选中只使用灰阶。边框是白色 6%／10%，输入 hover 边框 14%。`TextEmphasis` 独立管理占位符与禁用文字，避免靠反复叠加 opacity 得到不可控的对比度。

`surfaceFinish()` 从主题读取浅阴影与边框，为面板、菜单和视口浮动工具条画出约 2.4% 的顶部高光及低位阴影。浮层使用约 94% 不透明的中性表面，不使用背景模糊或大面积玻璃效果。

Editor 使用 120ms 控件反馈、220ms 面板与浮层切换、280ms 强调动效。按钮、页签、列表、输入框 hover／focus、开关滑块与勾选标记共享 `AnimatorScheduler`。输入表面不重置样式正在插值的颜色；分隔条拖动仍即时跟手。

`WorkspaceTheme.animatesLayout` 为编辑器启用面板份额与折叠栏尺寸的连续变化，通用宿主可保持即时布局。关闭／收起时文档状态立即改变，退出内容暂时保留绘制并立即禁用输入；结束后卸载，反向操作从当前尺寸继续并复用面板状态。这些呈现数据不写入工作区文档。

Popover 与 ContextMenu 的逻辑关闭同样即时完成，PortalHost 只保留退出中的非交互绘制。快速重开取消旧退出并复用同一个 portal；拥有者卸载时同步清理。分组已有 `AnimatedVisibility` 的高度收拢，Modal 复用其进入和退出生命周期。
