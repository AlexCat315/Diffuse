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

GuavaUI 通用默认主题使用接近 `#1E1F22` 的窗口背景、蓝色交互强调和紫色辅助强调。Editor 通过 `EditorVisualTheme` 提供独立的中性炭灰表面和绿色强调：深色 `#62B488`、浅色 `#277B50`。悬停、按压、焦点、选择与输入边框使用配套语义色，代码编辑器使用同一表面层级。网站保留独立的品牌色。

框架的结构为声明式 View → ViewGraph／Node 重组与状态订阅 → Yoga 布局 → DrawList／GPU 绘制。事件分发、焦点和浮层由 Runtime 管理；Workspace 模块管理面板、分组、分割和折叠；App 模块负责窗口与应用桥接。Editor 在这些公共能力之上定义领域、面板内容与视觉主题。框架提供机制，编辑器仍需统一信息层级和组件用法。

## 组件约定

- 常规操作控件使用至少 32pt 命中高度并提供 focus ring；密集编辑工具条使用 26pt 控件、30pt 面板标题与统一状态反馈。
- 文本输入默认垂直居中、裁剪内容，并使用主题间距作为 inset。
- hover、press、selected 和 focused 使用状态层合成。
- Box、Row 与 Column 默认不参与命中测试。

编辑器面板还遵循以下工作台约定：工具条使用统一水平 inset；搜索行必须提供清除能力与结果计数；图标按钮必须提供 tooltip；无数据、无选择和无搜索结果必须使用解释原因的空状态，而不是留下空白区域。

## 组件参考

完整的结构、尺寸、Token、状态矩阵、键盘行为和 Authoring rules 见[组件索引](components/README.md)。

密集工具条采用 `ToolbarToggleButtonStyle`：选中使用浅绿色状态层与绿色图标，不使用整块主按钮填充。主按钮才使用强调色实底。面板标题只出现一次，工具切换放在停靠栏；`WorkspaceTheme.tabBarHeight` 控制标题高度，手动编辑与 Agent 共用折叠、展开和最大化机制。
