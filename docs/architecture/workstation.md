---
path: /zh/docs/architecture/workstation
title: 'GuavaStudio 工作站边界'
description: 'GuavaStudio 工作站边界 — GuavaStudio documentation'
locale: zh
translationKey: architecture/workstation
category: architecture
order: 100
kind: doc
---

# GuavaStudio 工作站边界

GuavaStudio 是产品；`Engine/` 是场景、物理、渲染、脚本和 AI 等可复用运行库的实现目录。根 SwiftPM 工作区名为 GuavaStudioWorkspace，启动产品为 `GuavaStudio`。Editor 的包名为 GuavaStudioEditor，运行库包名为 GuavaStudioRuntime；资源 bundle、安装校验、发行包和官网使用对应的新标识。

## 生产领域

Editor 使用统一工作台。场景、脚本、大纲、属性与 Agent 共用文档、选择和布局；不再区分 Agent/manual 界面或持久化交互模式。工作流由 EditorWorkspaceProfile 定义面板与授权工具范围：

| 工作流 | 文档/操作 | 主要入口 |
| --- | --- | --- |
| Text and Code | 项目中的普通 UTF-8 文件，不隐式编译或执行 | DocumentsPanel、list/read/write_file |
| Video Editing | 视频源、顺序 cuts、裁剪、排序、预览/播放与 MP4 导出 | MediaTimelinePanel、媒体项目工具 |
| Game Development | 场景、游戏脚本、模拟和游戏构建 | 原有场景/脚本能力 |
| 3D Creation / Animation | 模型、渲染与动画组件 | 原有创作面板和能力 |

## 工作台界面

标题栏集中项目、当前选择、意图入口、五个 Space 和播放控制。写作、玩法、动画、剪辑、渲染依次使用 ⌘/Ctrl+1–5；脚本开发仍可从工作区菜单进入。macOS 和 Windows 使用同一命令树生成的原生菜单，Linux 保留该命令树的应用内菜单。

左侧 44pt 活动栏直接打开大纲、搜索、Agent、会话日志、资源和控制台。默认布局将大纲和资源放在左侧，场景与脚本放在中央，控制台等工具放在中央下方；右侧只有属性、Agent、日志三个标签。待确认操作直接显示在 Agent 对话顶部，审阅命令也打开 Agent，切换面板不丢失草稿或确认状态。面板继续支持拖拽、分屏、折叠和恢复。保存过的自定义布局继续保留，使用“重置布局”应用新的默认分布。

场景标签使用顶部选中线，侧栏和底部使用紧凑选中块。各组的面板选择、最大化和收起统一放在尾部菜单中，避免右侧标签被工具按钮挤掉。控制台在筛选行切换日志、问题、构建输出，保留现有输出状态与问题导航；属性网格使用平整分节，普通 GuavaUI 应用继续使用默认卡片样式。

Editor 使用连续面板与 1pt 分隔线；通用 Workspace 的卡片外观保持为默认值。工作台颜色、12pt 正文/11pt 辅助文字、5–9pt 控件圆角由 EditorVisualTheme 管理，深浅主题共享语义样式。叶绿表示选择与编辑动作，粉色表示 Agent 入口。场景编辑采用深色 studio 背景，试玩采用天空；此设置属于渲染呈现，不进入场景文件。

⌘/Ctrl+K 是统一意图入口：普通文本交给 Agent，`>` 搜命令，`@` 搜资源，`#` 搜场景实体；命令与资源搜索不依赖 AI 服务。Agent 使用现有任务与确认管线，草稿由当前项目的面板注册表持有，切换属性/Agent 标签不丢失输入。日志显示真实的任务、操作和控制台活动。风险四级、跨系统窗口的镜头撕出、统一时间轴和配方属于独立的运行时架构阶段。

界面回归覆盖标题栏密度、连续缩放后的控件顺序、右侧上下文切换、文档与选择保持、草稿保留、五个快捷键以及紧凑属性栏三轴输入。Space 导航用稳定的布局槽承载标签、图标与菜单三种呈现，切换时不改变标题栏顺序。原生验收通过 DevTools 的 query → input → query → capture，调整最大化窗口时先恢复窗口再设置逻辑尺寸。

`EditorWorkstation` 组合三个服务：scripts、documents、media。普通文档的路径、UTF-8 和磁盘冲突规则由独立 `Editor/Documents` 包管理；UI 模型只是边界适配器。媒体解码/剪辑来自独立 `Engine/Media` 包。已有 EditorApplication 不再新增并行脚本/文档字段。

Agent 与 MCP 共用 executeProjectTool，不把文件操作伪装为 scene mutation。文本工作流不暴露场景变更能力；媒体工作流提供读取时间线、添加/裁剪/移除 cuts、保存和导出。现有文件写入要求 read_file 返回的完整 expected_text，并拒绝覆盖未保存缓冲区或磁盘外部变更。

## 文档与会话

原始文本文件是持久内容。视频剪辑保存到 `.guava/media.json`，解码器、图像、设备和播放/导出任务是 session 状态。关闭项目和退出窗口会检查并保存所有三类文档，切换领域不丢弃缓冲区。文件和媒体服务只接受工程范围内的路径。媒体导出生成新的 Exports 文件，不覆盖原始素材。

当前视频工作流是可执行的顺序剪辑基础；多轨编辑、转场、媒体代理、通用语言 LSP 和跨设备完整工作站 UI 属于后续扩展。平台 SDK 的 iOS 应用宿主与桌面工作站的全部功能是两个独立支持范围。
