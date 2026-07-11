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

默认深色主题使用接近 `#1E1F22` 的窗口背景、`#3574F0` 蓝色交互强调和紫色辅助强调。网站采用独立的番石榴霓虹品牌色，但保留相同的层级思想。

## 组件约定

- 可点击控件最小命中高度为 32pt，并提供明确 focus ring。
- 文本输入默认垂直居中、裁剪内容，并使用主题间距作为 inset。
- hover、press、selected 和 focused 使用状态层合成。
- Box、Row 与 Column 默认不参与命中测试。

## 组件参考

完整的结构、尺寸、Token、状态矩阵、键盘行为和 Authoring rules 见[组件索引](components/README.md)。
