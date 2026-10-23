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

- [ ] 2.1 引入 `PluginManager`（安装/启用/停用/重载/卸载、激活事件、每插件 `DisposalScope`）。
- [ ] 2.2 贡献注册返回 `Registration`；停用/重载/宿主失效按插件逆序清理。
- [ ] 2.3 `enabled` 与 `activated` 分离；声明式贡献不加载运行时。
- [ ] 2.4 实现 `onStartup` / `onLanguage` / `onCommand` / `onView` / `onAIProvider` / `onAgent` / `onAITool` / `onAIChat` 分发。
- [ ] 2.5 把语言、VCS、tasks 的目录合并逻辑迁入各自领域注册器，移除重复扫描。
- [ ] 2.6 `activatePluginExecutor` 去全局化：主题/语言/AI 变更只失效对应领域，不重建无关 AI Session。
- [ ] 2.7 测试：激活事件、惰性加载、单插件停用不影响其他领域、清理顺序与失败回滚。

## 阶段 3：AI provider / agent 插件化

- [ ] 3.1 定义 `guava.ai.provider/v1` / `guava.ai.agent/v1` / `guava.ai.tool/v1` / `guava.ai.context/v1` descriptor 与校验。
- [ ] 3.2 新增 `AIProviderCatalog`，合并随包 provider 插件与已启用运行时插件，发布只读快照。
- [ ] 3.3 删除 `EditorAIProvider` enum；`EditorAISettings` 改为 `providerID` / `modelID` / `agentID`。
- [ ] 3.4 `AICredentialStore` 按 provider ID 与 auth field 存取；默认 provider 插件声明自己的认证字段。
- [ ] 3.5 `makeSession` 从 provider descriptor 构造 `SessionConfig`；宿主代理 HTTP / 流式 / 超时 / 审计。
- [ ] 3.6 新增随包 AI provider 插件（Anthropic / OpenAI / DeepSeek），只含 `plugin.json` 与声明资源。
- [ ] 3.7 设置页 provider / model / agent 列表来自 catalog，不再遍历 enum。
- [ ] 3.8 测试：provider 目录合并、凭据往返、SessionConfig 构造、禁用 provider 后设置页与会话行为、无网络代码路径。

## 阶段 4：AI agent / harness / 面板

- [ ] 4.1 默认 AI agent 迁移为随包 `guava.ai.agent/v1` 插件。
- [ ] 4.2 宿主 `Session` 消费 agent profile：instructions / model policy / tool allowlist / context allowlist。
- [ ] 4.3 定义 `guava.ai.harness/v1` 输入输出；宿主执行 tool calls 与审批，harness 只返回建议。
- [ ] 4.4 默认 AI 面板迁移到 `guava.ui.panel/v1`；宿主渲染外壳，插件提供内容配置。
- [ ] 4.5 测试：agent profile 生效、工具白名单、harness 不能绕过审批、面板启用/停用。

## 阶段 5：UI 与内置功能迁移

- [ ] 5.1 定义 `guava.command/v1` / `guava.ui.menu/v1` / `guava.ui.toolbar/v1` / `guava.ui.panel/v1` / `guava.ui.documentView/v1`。
- [x] 5.2 把 Git / Swift Support / Languages 的 manifest 迁到新贡献点键。
- [ ] 5.3 把默认主题、默认 AI provider、默认 agent、AI 面板纳入同一 `BundledPlugins` 目录。
- [x] 5.4 移除 `EditorVisualTheme.make` 中的默认主题硬编码，只保留回退值。
- [ ] 5.5 管理面板显示插件贡献点、激活状态、资源哈希与失败原因。
- [x] 5.6 文档：更新 `docs/architecture/plugin-execution.md` 与 `extension-lifecycle.md`。

## 验证

- [x] `./guava build Editor --debug`
- [x] `./guava build GuavaUI/Examples --debug`
- [x] `./guava test Editor --filter PluginPlatformTests`
- [x] `./guava test Editor --filter BundledLanguagesTests`
- [x] `./guava test Editor --filter FileIconTests`
- [ ] 手动：纯资源主题安装/切换/停用/重载；AI provider 切换；`.tex` 着色/提纲/格式化不回退。

## 本轮落地

阶段 0 / 1 已实现：版本化的通用贡献描述与领域解码器、可选运行时、资源路径与哈希校验、完整 manifest 授权、纯声明包 CLI 打包、默认主题资源、每会话主题目录与偏好持久化、声明式插件检查/启用/停用/重载及资源监视。Git、Lore、Swift Support、Languages、AI Providers 已直接迁移贡献键。

主题 schema 当前覆盖颜色、字体、间距、圆角、动效、输入框、文本强调、阴影和语法色；图标替换仍待后续契约。ContributionPointRegistry 当前负责解码与验证；注册释放句柄、统一 PluginManager 和 activation 事件的实际调度仍属于阶段 2，尚未实现。

验证使用上述过滤器的合并正则并加 `--no-parallel`；同时覆盖默认主题逐项一致、主题原位重绘、现有运行时授权/重载、AI 设置与设置页工作流。Engine 插件相关 37 项、Web 6 项回归通过。

已通过 `./guava run Editor --devtools --no-open -- --project-dir <临时项目> --settings` 启动真实编辑器，核对默认主题列表、深浅切换、停用与重新启用；手动验收中的外部主题安装和 AI provider 切换仍未标记完成。
