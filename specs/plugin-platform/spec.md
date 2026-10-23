# Spec：插件平台（万物皆插件）

## 目标

把 GuavaStudio 从「WASM 能力运行时 + 若干硬编码贡献分支」升级为统一的插件平台：

- 所有用户可见功能都通过插件交付，内置功能与第三方使用同一套贡献契约。
- 一个插件可以组合多种贡献，不引入「主题插件类型」「AI 插件类型」这样的封闭分类。
- 声明式贡献不加载 WASM；只有需要执行的行为才进入能力运行时。
- 宿主统一负责生命周期、权限、挂载、激活与清理；各领域保留自己的描述类型和校验规则。
- 默认主题、默认语言包、默认 AI provider / agent 都以随包插件形式交付。

## 非目标

阶段 1 不做：

- 任意 SwiftUI / 原生代码插件。
- 插件市场、签名分发和远程安装。
- 自定义 AI harness 的完整循环。
- 插件间 UI 布局协商和任意视图嵌套。
- 兼容旧 manifest 双轨解码；迁移直接更新所有第一方插件。

## 核心原则

1. **Contribution 与 Capability 分离**
   - Contribution：静态声明，有命名空间、版本、schema、校验；不执行代码。
   - Capability：需要执行的行为，使用 WIT / WASM 或宿主代理；按需激活。
2. **声明不依赖运行时**
   - 主题、图标、语言 grammar / outline、命令元数据、菜单位置、AI 模型目录都可在插件未加载时注册。
3. **激活是按贡献的，不是按插件的**
   - 启用一个插件不等于加载它的全部行为。
4. **宿主拥有生命周期与权限**
   - 插件不能自行执行工具、读取凭据、访问网络或绕过提交管线。
5. **一个插件，多种贡献**
   - 不设计 `PluginKind`；插件是贡献的容器。
6. **领域拥有类型**
   - `guava.language/v1` 的 descriptor 与校验归语言领域；`guava.ai.provider/v1` 归 AI 领域。平台只负责注册、解析、生命周期。

## 包模型

### 必选文件

```text
plugin.json
```

### 可选运行时

```text
capabilities.wit
component.wasm
```

两者必须同时存在或同时不存在。没有运行时的包是**纯声明插件**。

### 可选资源

```text
resources/...
```

`plugin.json` 声明资源：

```json
{
  "resources": [
    { "id": "theme-default", "path": "resources/theme.json", "kind": "theme" }
  ]
}
```

资源路径必须位于包内、禁止符号链接、禁止 `..`，并按内容哈希参与授权。

### manifest 结构

```json
{
  "id": "studio.ai.anthropic",
  "version": 1,
  "name": "Anthropic",
  "description": "Anthropic models for GuavaStudio",
  "access": "read",
  "imports": [],
  "requires": [],
  "activation": ["onAIProvider:anthropic"],
  "contributes": {
    "guava.ai.provider/v1": [ ... ]
  },
  "runtime": {
    "component": "component.wasm",
    "wit": "capabilities.wit"
  }
}
```

`contributes` 的键是**贡献点 ID**，值为该贡献点的声明数组或对象。平台根据注册的 `ContributionPointSpec` 解码与校验，不再使用封闭的 `PluginContributions` 结构。

## 贡献点

### 命名与版本

格式：`guava.<domain>.<point>/v<major>`。

示例：

- `guava.theme/v1`
- `guava.language/v1`
- `guava.command/v1`
- `guava.ui.panel/v1`
- `guava.ui.menu/v1`
- `guava.ai.provider/v1`
- `guava.ai.agent/v1`
- `guava.ai.harness/v1`
- `guava.ai.tool/v1`
- `guava.ai.context/v1`

major 不同视为不同贡献点；平台拒绝未知 major，不猜测解码。

### ContributionPointSpec

每个领域注册：

```swift
public protocol ContributionPointSpec: Sendable {
    associatedtype Descriptor: Codable & Sendable
    static var id: String { get }
    static func validate(_ descriptor: Descriptor, host: PluginHostPermissions) throws
    static func register(_ descriptor: Descriptor, pluginID: String,
                         context: ContributionContext) throws -> Registration
}
```

平台负责：

- 从 manifest 取出该点的原始 JSON
- 调用 descriptor 解码
- 调用领域校验
- 在插件启用时注册
- 在停用、重载、宿主失效时按逆序释放

领域负责：

- descriptor 的字段和默认值
- 领域不变量校验
- 从 descriptor 到运行时对象的转换
- 向该领域的只读目录发布快照

### 领域快照

UI 只读取领域快照，不直接访问 plugin session：

```swift
public struct LanguageCatalogSnapshot: Sendable { ... }
public struct ThemeCatalogSnapshot: Sendable { ... }
public struct AIProviderCatalogSnapshot: Sendable { ... }
```

快照由领域在注册/释放时原子替换；UI 观察 `revision` 或订阅领域更新。

## 激活模型

状态：

```text
installed → enabled → activated → deactivated → uninstalled
```

- `enabled`：manifest 校验通过、贡献已注册、授权记录有效。
- `activated`：运行时已加载，能力可调用。
- 纯声明插件可以永远停在 `enabled`。
- 有运行时的插件默认惰性激活，除非贡献点声明必须在启动时激活。

激活事件：

```text
onStartup
onLanguage:<id>
onCommand:<id>
onView:<id>
onAIProvider:<id>
onAgent:<id>
onAITool:<id>
onAIChat
onWorkspaceContains:<glob>
onURI:<scheme>
```

规则：

- 一个插件可以有多个激活事件。
- 声明式贡献不因激活事件而加载运行时。
- 首次命中事件时，平台加载运行时并把已注册的贡献绑定到能力入口。
- 停用/重载只影响该插件及其依赖方，不重建无关领域的会话。

## 生命周期与清理

`PluginManager` 是唯一生命周期所有者：

- 安装 / 启用 / 停用 / 重载 / 卸载
- 授权记录与内容哈希
- 依赖解析
- 运行时挂载与卸载
- 激活事件分发
- 每插件 `DisposalScope`
- 每贡献 `Registration`

领域不持有插件生命周期。领域只接收注册请求并返回 `Registration`。

`activatePluginExecutor` 不再全量重建 AI Session。AI provider/agent 变化只失效 AI 域；主题变化只替换主题快照；语言变化只刷新语言目录。

## 主题贡献

```json
{
  "id": "studio.theme.default",
  "title": "Guava Default",
  "appearance": "dual",
  "path": "resources/theme.json"
}
```

`theme.json` 描述：

- colors：语义色槽（surface、onSurface、accent、status、border…）
- typography：editor、ui、mono
- spacing / radius / motion
- syntax：keyword、type、function、string、number、comment、attribute、directive
- icons：file icon theme 与 product icon 覆盖

默认主题 `EditorVisualTheme` 迁移为随包纯声明插件。主题切换只替换 `Theme` 快照和持久化主题 ID。

## 语言贡献

沿用阶段 1/2 的字段，但拆分为：

```json
{
  "id": "latex",
  "title": "LaTeX",
  "extensions": ["tex"],
  "icon": "latex",
  "grammar": { "rules": [...] },
  "outline": { "rules": [...] },
  "format": { "entryPoint": "format" },
  "server": { "process": "language-server" }
}
```

- grammar / outline / 文件识别：声明式，启用即注册。
- format / server：能力，首次使用时激活运行时。
- 没有 format/server 的语言包不需要 WIT 或 component。

## AI 贡献

AI 不是单一插件类型，而是一组贡献点。

### `guava.ai.provider/v1`

声明：

- id、title
- `apiFormat`：`anthropic` / `openai-responses` / `openai-compatible`
- `baseURL`
- `models`：id、title、context window、max output、是否支持 tools / vision
- `auth`：字段描述，secret 字段由宿主凭据库保存
- `defaultModel`

阶段 1 的 provider 不直接访问网络。宿主按 `apiFormat` 执行 HTTP、注入凭据、流式读取、超时和审计。自定义协议以后通过受控的 provider capability 或独立 provider host 开放。

### `guava.ai.agent/v1`

声明：

- id、title
- instructions
- model policy：preferred / fallback / temperature / max tokens
- tool allowlist
- context source allowlist
- approval defaults（宿主策略只能更严格，不能被插件放宽）

Agent 是声明式配置；宿主 `Session` 消费它。

### `guava.ai.harness/v1`

可选行为贡献：

```json
{ "id": "studio.agent.loop", "entryPoint": "agent-turn" }
```

输入：受限的对话、上下文摘要、可用工具列表。  
输出：助手消息 + 建议的 tool calls + 上下文请求。

宿主负责执行 tool calls、审批、事务和撤销。Harness 不能直接执行工具或访问文件系统。

### `guava.ai.tool/v1`

```json
{
  "id": "studio.git.status",
  "title": "Git Status",
  "description": "Read working tree status",
  "inputSchema": { ... },
  "capability": "studio.git.status"
}
```

工具元数据是声明式；调用走 capability 与现有权限/审批管线。

### `guava.ai.context/v1`

上下文来源：

- id、title
- 读取范围声明：workspace / selection / git / docs / memory
- capability 入口
- 最大返回字节、是否允许外发

宿主负责读取权限、脱敏和大小限制。

### AI 面板

AI 聊天面板通过通用 `guava.ui.panel/v1` 贡献：

```json
{
  "id": "studio.ai.chat",
  "title": "AI",
  "location": "right",
  "contentKind": "ai.chat",
  "icon": "sparkles"
}
```

宿主拥有面板外壳、焦点、布局和消息渲染；插件只提供内容类型和配置。

## UI 贡献

阶段 1 只开放窄的、宿主可渲染的描述：

- `guava.command/v1`
- `guava.ui.menu/v1`
- `guava.ui.toolbar/v1`
- `guava.ui.panel/v1`
- `guava.ui.documentView/v1`

不允许插件直接持有 SwiftUI / GuavaUI 视图树。内容视图后续从以下方案中选择：

1. 宿主渲染的声明式 view model
2. 隔离 webview
3. 受限的 WASM view protocol

## 授权与安全

- 纯声明插件：授权绑定 manifest + 资源哈希。
- 运行时插件：授权继续绑定 component / WIT / manifest / resources。
- 凭据由宿主凭据库保存，插件只能拿到“已认证”状态，不读取明文密钥。
- AI provider 的网络访问由宿主代理；自定义网络能力必须单独授权域名。
- 工具执行、提交管线、审批、审计永远在宿主。
- 停用/卸载必须释放该插件的所有注册；失败时 fail-closed。
- 宿主重启、authority 变化、依赖失效按领域收窄失效，不全局清空无关会话。

## 迁移

1. `EditorVisualTheme` → `studio.theme.default` 随包插件。
2. `EditorAIProvider` enum → `AIProviderCatalog` + 随包 provider 插件。
3. `EditorAISettings.provider` → provider ID，`model` → model ID。
4. 默认 Anthropic / OpenAI / DeepSeek 变为随包 AI provider 插件。
5. `studio.languages` 保持运行时（format），但 grammar/outline 仍为声明。
6. Git / Swift Support 迁移到 `guava.vcs/v1` / `guava.tasks/v1`；`contributes` 键更新为新格式。
7. AI 面板迁移到 `guava.ui.panel/v1`。

## 验证

阶段 1：

- 纯资源包只含 `plugin.json` + resources，可被扫描、启用、停用、重载。
- 默认主题插件与代码构造的当前主题逐项一致。
- 主题切换、停用、重载后 UI 立即更新。
- 语言包无运行时也能识别、着色、列提纲。
- 现有 Editor / Gallery 构建通过。

阶段 2：

- AI provider 目录来自插件，设置页不再枚举固定 enum。
- 切换 provider 仅重建 AI 域。
- 默认 provider 插件与第三方 provider 使用同一 manifest 契约。
- AI provider 变更不会清空无关编辑器状态。

## 审批

本文是平台级规格。批准后按 `tasks.md` 顺序实施，先打通纯资源包 → 默认主题 → 激活/清理，再迁 AI provider / agent，最后开放 UI。
