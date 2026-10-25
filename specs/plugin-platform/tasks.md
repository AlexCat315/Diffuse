# Tasks：插件平台（万物皆插件）

## 阶段 0：规格与契约

- [x] 0.1 写 `specs/plugin-platform/spec.md`，确定 package / contribution / activation / capability 边界。
- [x] 0.2 增加 `ContributionPointSpec`、`ContributionPointID`、`ContributionDescriptor` 与领域注册表骨架（`Engine/Sources/PluginRuntime/Contribution/`）。
- [x] 0.3 把 `contributes` 从封闭结构迁到「命名空间键 → 原始声明」，先保留领域解码器。
- [x] 0.4 manifest 增加可选 `runtime.compatibility`、`resources`、`activation`，校验资源路径与运行时文件成对存在。
- [x] 0.5 `PluginPackage` 支持无 WIT / component 的纯声明包；区分 `declarative` 与 `runtime` 校验结果。

## 阶段 1：纯资源包与默认主题

- [x] 1.1 `PluginPackageLoader` 允许纯声明包，资源哈希进入 inspection / authorization。
- [x] 1.2 `BundledPlugins` 增加 `.declarative` 宿主，按 manifest 与包内容分类，不经过 `GuavaPluginHost`。
- [x] 1.3 `enableBundledPlugins` / `setBundledPlugin` / `isBundledPluginEnabled` 支持声明式插件，不创建 host binding。
- [x] 1.4 定义 `guava.theme/v1` descriptor、资源 schema、领域校验与 `ThemeCatalog` 快照。
- [x] 1.5 把 `EditorVisualTheme.make` 的默认值迁移到 `Editor/Plugins/Themes/Default/theme.json`，生成随包 `DefaultTheme.guavaplugin`。
- [x] 1.6 `EditorThemeCatalog` 接入 `EditorLaunchRoot` / `EditorPresentationBoundary` / Settings；主题 ID 持久化，切换、停用、重载立即生效。
- [x] 1.7 测试：纯声明包加载、主题 JSON 与当前默认主题逐项一致、切换/停用/重载、FileIcon/EditorUI 构建。

## 阶段 2：通用贡献点与激活

- [x] 2.1 引入 `PluginManager`（安装/启用/停用/重载/卸载、激活事件、每插件 `DisposalScope`）。
- [x] 2.2 贡献注册返回 `Registration`；停用/重载/宿主失效按插件逆序清理。
- [x] 2.3 `enabled` 与 `activated` 分离；声明式贡献不加载运行时。
- [x] 2.4 实现 `onStartup` / `onLanguage` / `onCommand` / `onView` / `onAIProvider` / `onAgent` / `onAITool` / `onAIChat` 分发。
- [x] 2.5 把语言、VCS、tasks 的目录合并逻辑迁入各自领域注册器，移除重复扫描。
- [x] 2.6 `activatePluginExecutor` 去全局化：主题/语言/AI 变更只失效对应领域，不重建无关 AI Session。
- [x] 2.7 测试：激活事件、惰性加载、单插件停用不影响其他领域、清理顺序与失败回滚。

## 阶段 3：AI provider / agent 插件化

- [x] 3.1 定义 `guava.ai.provider/v1` / `guava.ai.agent/v1` / `guava.ai.tool/v1` / `guava.ai.context/v1` descriptor 与校验；capability 只有被 `guava.ai.tool/v1` 声明才提供给模型。
- [x] 3.2 新增 `AIProviderCatalog`，合并随包 provider 插件与已启用运行时插件，发布只读快照。
- [x] 3.3 删除 `EditorAIProvider` enum；`EditorAISettings` 改为 `providerID` / `modelID` / `agentID`。
- [x] 3.4 `AICredentialStore` 按 provider ID 与 auth field 存取；默认 provider 插件声明自己的认证字段。
- [x] 3.5 `makeSession` 从 provider descriptor 构造 `SessionConfig`；宿主代理 HTTP / 流式 / 超时 / 审计。
- [x] 3.6 新增随包 AI provider 插件（Anthropic / OpenAI / DeepSeek），只含 `plugin.json` 与声明资源。
- [x] 3.7 设置页 provider / model / agent 列表来自 catalog，不再遍历 enum。
- [ ] 3.8 测试：provider 目录合并、凭据往返、SessionConfig 构造、禁用 provider 后设置页与会话行为、无网络代码路径。

## 阶段 4：AI agent / harness / 面板

- [x] 4.1 默认 AI agent 迁移为随包 `guava.ai.agent/v1` 插件。
- [x] 4.2 宿主 `Session` 消费 agent profile：instructions / model policy / tool allowlist / context allowlist（宿主来源与 `guava.ai.context/v1`）。
- [x] 4.3 定义 `guava.ai.harness/v1` 输入输出；宿主执行 tool calls 与审批，harness 只返回建议。agent 用 `harness` 指定；示例 `examples/Plugins/CarefulAgent`。界面上的助手由 "Harness" 改名为 "Assistant"（助手）。
- [x] 4.4 默认 AI 面板迁移到 `guava.ui.panel/v1`（宿主视图 `agent`）；宿主渲染外壳，插件提供内容配置。
- [ ] 4.5 测试：agent profile 生效、工具白名单、harness 不能绕过审批、面板启用/停用。

## 阶段 5：UI 与内置功能迁移

- [x] 5.1 定义 `guava.command/v1` 与 `guava.ui.panel/v1`；面板内容采用宿主渲染的声明式 view model（宿主视图或入口返回的 `PanelModel`）。
- [x] 5.1b 定义 `guava.ui.menu/v1` / `guava.ui.toolbar/v1` / `guava.ui.documentView/v1`。
- [x] 5.2 把 Git / Swift Support / Languages 的 manifest 迁到新贡献点键。
- [x] 5.3 把默认主题、默认 AI provider、默认 agent、AI 面板纳入同一 `BundledPlugins` 目录。
- [x] 5.4 移除 `EditorVisualTheme.make` 中的默认主题硬编码，只保留回退值。
- [x] 5.5 管理面板显示插件贡献点、激活状态、资源哈希与失败原因。
- [x] 5.6 文档：更新 `docs/architecture/plugin-execution.md` 与 `extension-lifecycle.md`。
- [x] 5.7 插件界面改为通用组件树 + 状态往返的视图协议（面板与文档视图共用），命令改为返回效果；`GuavaPluginKit` 提供 `UI` 构造与事件解析；示例 `examples/Plugins/Checklist`。

## 验证

- [x] `./guava build Editor --debug`
- [x] `./guava build GuavaUI/Examples --debug`
- [x] `./guava test Editor --filter PluginPlatformTests`
- [x] `./guava test Editor --filter BundledLanguagesTests`
- [x] `./guava test Editor --filter FileIconTests`
- [x] `./guava test Engine --filter WorkbenchContributionTests`
- [x] `./guava test Editor --filter "WorkbenchContributionsTests|PluginPanelTests"`
- [x] 端到端：`GUAVA_CHECKLIST_PLUGIN=<Checklist.guavaplugin> ./guava test Editor --filter PluginViewEndToEndTests`
- [x] 端到端：`GUAVA_CAREFUL_AGENT_PLUGIN=<CarefulAgent.guavaplugin> ./guava test Editor --filter HarnessEndToEndTests`
- [ ] 手动：纯资源主题安装/切换/停用/重载；AI provider 切换；`.tex` 着色/提纲/格式化不回退。

## 本轮落地

阶段 0 / 1 已实现：版本化的通用贡献描述与领域解码器、可选运行时、资源路径与哈希校验、完整 manifest 授权、纯声明包 CLI 打包、默认主题资源、每会话主题目录与偏好持久化、声明式插件检查/启用/停用/重载及资源监视。Git、Lore、Swift Support、Languages、AI Providers 已直接迁移贡献键。

主题 schema 当前覆盖颜色、字体、间距、圆角、动效、输入框、文本强调、阴影和语法色；图标替换仍待后续契约。

阶段 2 已接入：`PluginManager` 是安装、启用、惰性激活、重载、停用与卸载的统一所有者；并发请求排队，依赖先激活，注册与运行时组件通过 `Registration` / `DisposalScope` 逆序释放。注册、激活或重载失败会撤回受影响插件与依赖者；宿主失效保留无关声明贡献。

语言、主题、provider、VCS 与 tasks 使用会话内领域目录，移除了语言/provider 的全局可变注册表及 step 驱动的独立授权/挂载。语言服务、格式化、任务与版本控制在请求时激活；AI 聊天/选中 provider 分发事件。`onView` / `onAgent` / `onAITool` 等可通过统一事件入口分发，实际 agent/UI 贡献点与消费者仍在阶段 3–5；本轮不把这些扩展算作已实现。

插件设置新增按贡献点推导的分类筛选，一个插件可以属于多个分类；显示启用、运行、失败与关闭状态，外部插件关闭后在当前会话保留条目，可重新启用或卸载。格式化与进程入口不会因使用 WIT 而暴露给 AI；主题/语言变化保留 AI 会话和聊天，AI 工具变化只替换会话能力与待执行草案，选中 provider 变化才重建模型会话。

新增覆盖：分类筛选、混合贡献、声明注册回滚、逆序清理、并发需求只激活一次、退出期间激活不能复活、依赖激活/失效、关闭后重新启用/卸载、格式化惰性激活与聊天保留。验证均通过 `./guava` 执行；agent profile、harness 与插件化 UI 面板保持待办。

本轮验证：Engine 插件/能力相关 70 项测试通过；Editor 的插件生命周期、分类筛选、主题重绘、格式化、任务/VCS、MCP 与工具策略回归通过。已用 `./guava run Editor --devtools --no-open` 启动真实编辑器，实际切换到主题分类并核对结果。
