---
path: /zh/docs/source-organization
title: 源码组织
description: Guava Engine 源码目录和模块职责。
locale: zh
translationKey: docs.source-organization
category: 开发指南
order: 88
kind: doc
---

# 源码目录与初始化约定

源码按职责拆分文件和配置类型；调用接口随结构调整同步更新。
Swift Package 会递归收集 target 目录中的 Swift 源码，因此这些子目录不需要在 Package.swift 中逐项注册。

## 编辑器应用

`Editor/Sources/EditorCore/Application/EditorApplication.swift` 保存应用装配、共享服务和主循环。
其他功能放在对应子目录：

- `Persistence/`：游戏存档、播放快照、场景保存和自动恢复。
- `Projects/`：新建与关闭场景、导出和启动播放器。
- `Editing/`：应用层 Undo/Redo 命令。
- `Assets/`、`Scripting/`、`Viewport/`、`Diagnostics/`：各自的应用协调逻辑。
- `AI/`：会话设置、请求、意图执行和上下文记忆。
- `Plugins/`、`Bridge/`：插件授权与隔离宿主、MCP 调用边界。

## 编辑器场景

`Editor/Sources/EditorCore/Scene/` 按以下层次组织：

- `Models/`：层级树、实体摘要和编辑器专用锁组件。
- `Manifest/`：场景清单与各组件的 Codable 模型；物理模型继续分入 `Physics/`。
- `Adapter/`：场景适配器及层级、序列化、事务、资源生成和视口等扩展。
- `Adapter/Inspector/`：检查器 schema 与绑定，物理和粒子使用各自子目录。
- `Adapter/Support/`：变换数学和 JSON 提交辅助函数。
- `History/`：独立的场景历史对象，封装快照栈、嵌套分组和交互取消。

适配器持有历史对象，历史对象返回需要恢复的快照；场景替换、粒子反馈失效和修订通知仍由适配器执行。
跨文件扩展需要访问的实现使用模块内访问权限；公开接口之外的调用仍不暴露给其他模块。

## 物理与粒子

`Engine/Sources/SceneRuntime/Physics/` 包含刚体、碰撞体、角色控制器、设置、事件与调试数据。
车辆、关节、软体、查询、回放和后端分别放入 `Vehicles/`、`Joints/`、`SoftBodies/`、`Queries/`、`Replay/` 和 `Backend/`。
Jolt 后端和已有查询实现也一并归入这些目录。

`Engine/Sources/SceneRuntime/Particles/` 包含粒子类型、曲线、统计、事件、可扩展性策略和模块配置。
`Emitter/` 按模拟、生成、受力、随机采样、外观和渲染边界拆分发射器实现。

## 开发者工具

`Editor/Sources/EditorApp/Panels/DeveloperTools/` 的入口是 `DeveloperToolsPanel.swift`。
`Models/` 保存诊断与追踪模型；`Diagnostics/` 保存诊断计算；`Debugger/` 保存调试视图。
`Particles/`、`Trace/`、`Profiler/` 按工具领域组织；`Shared/` 保存格式化和通用视图组件。

## 字段与 init

配置和状态按职责组成，避免上百个字段和参数集中在同一类型里。每个类型最多 20 个存储属性，初始化器最多 16 个参数、最多逐项赋值或解码 20 个属性；历史大类型由可维护性基线约束，禁止继续增长。

- `ParticleEmitterSettings` 直接组合 11 个领域模块，每组拥有自己的默认值和校验。发射器通过 `ParticleEmitter(settings: .init { ... })` 创建；也可以从模块栈创建独立的新模拟。
- `ParticleEmitterRuntimeState` 单独持有粒子池、帧反馈、计时和随机数状态。清空模拟保留编辑配置、随机数序列位置和数组容量。
- `EditorState` 组合选择、文档、计时、工作区、窗口、视口、阴影、吸附、助手、输出、导航、呈现和垂直同步状态；相关字段由各组维护。
- 场景直接序列化分组配置。项目处于早期开发，修改类型时同步修改调用方和格式，不引入旧初始化器、字段转发别名或旧存档迁移层。

运行 `python3 scripts/check-swift-maintainability.py` 检查结构，使用 `--report` 查看尚未拆分的历史类型。完整规则见根目录 `AGENTS.md`。
