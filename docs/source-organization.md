# 源码目录与初始化约定

这次重构保持 Swift 模块、公开类型名和既有调用接口不变，按职责拆分原来的五个大文件。
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

字段多和 `self.field = field` 本身不是错误。Swift 的公开结构体需要显式的公开初始化器；
序列化 DTO 也需要逐项映射字段、兼容旧版本和执行校验。保留这些初始化器可维持现有 API 和文件格式。

需要避免的是把多个领域的状态混在同一对象中、重复维护默认值，或者让新调用方依赖一个包含上百个参数的初始化器。
这次作了两处状态封装，并增加了已有配置模型的初始化入口：

- `EditorSceneEditHistory` 封装撤销与重做的快照、分组状态和容量限制。
- `ParticleEmitterRuntimeState` 封装粒子池、帧反馈、发射计时和随机数状态，在声明处给出默认值。
  发射器初始化只需传入随机种子；清空统一由状态对象执行，保留编辑配置、随机数序列位置和数组容量。
- 新代码可以使用 `ParticleEmitter(moduleStack: stack)`，通过已有的领域模块配置建立独立的新模拟。
  旧的参数初始化器继续提供默认参数、数值校验和向后兼容。

新增字段时，先判断它是编辑配置、运行状态还是序列化数据，再加入对应类型。
不要为了省略几行赋值而引入反射、字典或失去静态类型的通用初始化器。
