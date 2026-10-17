# GuavaUI 通用 AI 底层

GuavaUI 拥有工具契约与校验、provider 工具描述、模型工具循环、MCP JSON-RPC 端点、skills，以及 UI 诊断查询。Editor 拥有场景、项目文件、播放、授权与事务业务。现有 Engine AIRuntime 的场景规划、场景会话和供应商 HTTP 请求适配仍属于领域集成；它使用同一份 GuavaUI 工具契约和 Schema。

## 模块边界

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| Portable / GuavaUIAgentCore | AgentTool、JSONSchema、AgentToolbox、AgentSession、AgentSkillLibrary、MCPServer | Foundation |
| Portable / GuavaUIAgentTransport | 有界、逐连接串行的 loopback JSON-lines 传输 | AgentCore、SwiftNIO |
| Portable / GuavaUIDevToolsScene / Diagnostics | 节点、重组、显式状态与 CPU Trace 查询 | Scene、DevToolsProtocol、AgentCore |
| GuavaUIAgent | 面向原生应用的显式导入产品 | 上述模块 |
| EditorCore / Diagnostics | 帧、渲染 Pass、粒子与工作台诊断分析；领域工具适配 | Engine 数据与 GuavaUIAgent |
| GuavaMcp | stdio 装配与 Editor 能力发现/草稿适配 | 通用 MCPServer 与 Editor 的本地服务 |

JSONSchema 和 SessionAPIFormat 已从 Engine 移入 AgentCore。上层模块重导出其唯一实现，没有旧类型别名或第二份 decoder。应用不需要继承、遵循额外协议、全局注册或传递节点句柄。

## 接入应用

`Application.run` 的可选 `onDiagnosticsReady` 回调提供主窗口的 `UIDiagnostics` facade，宿主退出时回调 nil。接入不要求开启 WebSocket Inspector。应用可将 `try diagnostics.toolbox()` 传给 `AgentSession` 或 `MCPServer`，也可调用 facade 的查询函数。应用自身的数据继续由自身函数提供。

```swift
import GuavaUI
import GuavaUIAgent

try Application.run(onDiagnosticsReady: { diagnostics in
    agentAdapter.setDiagnostics(diagnostics)
}) {
    MyRootView()
}
```

普通工具使用值和函数构建：

```swift
let toolbox = try AgentToolbox(tools: [
    AgentTool(name: "read_count", description: "Read the counter",
              schema: .object(properties: [:]))
]) { name, input in
    try await AgentToolResult.encode(model.readCount())
}

let agent = try AgentSession(toolbox: toolbox, model: modelAdapter.reply)
let result = try await agent.run(messages: [AgentMessage(role: .user, text: "当前计数是多少？")])
```

`modelAdapter.reply` 接收普通消息和工具描述，返回答案或工具调用；认证、网络和模型选择由适配器负责。`providerDefinition(format:)` 提供已有三种 wire format 的工具定义。默认最多八轮工具调用，输入与输出有字节上限，取消会传播，工具失败作为可观察结果交回模型。

`MCPServer.respond(to:)` 接收 JSON bytes、返回可选 response bytes；notification 没有 response。支持 initialize、ping、tools/list、tools/call、prompts/list/get。MCP 工具结果包含文本 JSON，object 结果同时包含 structuredContent。`AgentLocalServer` 仅绑定 127.0.0.1，默认端口 0；宿主可把 MCPServer 的 respond 函数接入传输。stdio 宿主直接读写这些 bytes。

## 诊断工具

| 工具 | 数据与边界 |
| --- | --- |
| get_diagnostics | Editor 的问题、证据、建议、帧趋势、渲染 Pass 和数据可用性；普通 GuavaUI toolbox 返回 UI 概览及无效布局几何 |
| query_ui_nodes | 扁平分页节点、parent ID、裁剪后可见几何、源码、组件归属、已声明的无障碍语义与实际输入权限；支持 ID/text/role/source、visible_only、input_enabled_only 筛选 |
| query_ui_recomposition | owning component 的重组次数、inclusive CPU 时间与触发原因，按 totalMs 排序 |
| query_ui_state | 默认只读注册元数据；仅显式 ids 求值，支持 scope 筛选，报告 missing IDs |
| capture_ui_trace | 50–5000 ms，默认 500 ms；记录真实 CPU spans，不强制刷新或输入 |
| get_ui_trace | 查询采集摘要与分页事件 |
| compare_ui_traces | 按 phase 比较 count、average、P95，缺失 phase 不被当成零耗时 |
| list_skills / read_skill | 指引元数据与正文 |

每页最多 100 项。Node 与 scope IDs 属于节点存活期，卸载后失效；单节点查询对过期 ID 报错。State 默认私有，只有显式注册的摘要可读。secure 控件的 value 被替换为 redacted；节点查询不求值 lazy accessibility providers。

普通 GuavaUI 的 `get_diagnostics.layoutIssues` 返回无效几何的 `total` 和至多 `limit`（上限 100）个 `items`：节点 ID、字符串形式的 `invalidValues`、可用的源码位置。NaN、无穷值及负尺寸不会使概览 JSON 编码失败；可见节点查询排除无效几何子树，按 ID 查询异常节点则明确报告节点 ID 并指向该诊断入口。隐藏布局保留状态但不暴露可交互节点。`DiagnosticsTests` 覆盖异常值、来源、样本上限和即时 wire 错误信息。

`presentation.inputEnabled` 包含祖先状态、可见几何和所属场景的模态输入许可。打开 dialog 后，仍绘制的背景可保持 `isVisible = true`，但 `inputEnabled = false`；使用 `input_enabled_only: true` 排除它们。模态权限从本场景已绑定的焦点资源读取，不依赖查询发生时的全局 current window，支持嵌套模态及附属浮层。作用域发现采用一次线性扫描，深层组合节点不会反复扫描子树。

原生 Inspector 的 `NodeSummary.semanticRole` 优先保留显式诊断角色，否则取节点的辅助功能角色；普通按钮、输入框和 dialog 不必额外写 debug metadata 才能按角色发现。

开启原生 DevTools 后，`hello.capabilities` 中的 `diagnostics` 表示支持实际窗口的 AI 查询。`diagnostics.tools` 返回当前可调用的 MCP 工具定义；`diagnostics.call` 接收 `{name, arguments}`，返回同一 toolbox 的 `{ok, data}`。当前即时查询包括 `get_diagnostics`、`query_ui_nodes`、`query_ui_recomposition`、`query_ui_state`、`list_skills`、`read_skill`。参数 Schema、分页、脱敏与 SDK 共用；输入最多 256 KiB，结果最多 512 KiB，错误通过标准 `.err` envelope 返回。这些读取不占用 Inspector 的编辑租约。

原生 SDL 循环通过宿主的帧 inbox 执行这些同步读取，连接断开或服务重启后丢弃旧请求。异步 Trace 采集仍通过进程内 toolbox 或已有 `timeline.*` 流使用，不在即时查询列表中承诺可用。

可以在仓库根目录直接查询已启动的原生窗口：

```sh
swift run --package-path Tools/Developer guava-dev devtools query-ui 9229 --list
swift run --package-path Tools/Developer guava-dev devtools query-ui 9229 query_ui_nodes '{"role":"heading","visible_only":true}'
swift run --package-path Tools/Developer guava-dev devtools query-ui 9229 query_ui_nodes '{"text":"More actions","input_enabled_only":true}'
```

端口取实际 DevTools 启动输出。脚本也接受 `@参数文件.json`；需要启动令牌时通过 `GUAVA_DEVTOOLS_TOKEN` 环境变量提供，不把令牌放进命令行。脚本仅连接 loopback，10 秒超时；具体能力以 `--list` 返回值为准。

### 操作与画面闭环

原生 DevTools 的 `mirror.input` 把指针、滚轮、键盘和文本送入宿主输入分发器；`mirror.frame` 从当前窗口真实 DrawList 经已选择的渲染后端重放并读回画面。它们与上述只读诊断工具共用同一服务，`hello.capabilities` 必须同时声明 `mirror` 和 `diagnostics`。不需要操作系统自动化权限。

```sh
swift run --package-path Tools/Developer guava-dev devtools input-ui 9229 --click-node NODE_ID
swift run --package-path Tools/Developer guava-dev devtools input-ui 9229 --input '[{"kind":"keyDown","key":"End"},{"kind":"keyUp","key":"End"}]'
swift run --package-path Tools/Developer guava-dev devtools capture-ui 9229 /tmp/guava-window.jpg
```

先通过 `query_ui_nodes` 的可见/输入过滤拿到当前节点 ID；点击入口重新查询节点的裁剪后命中区域，拒绝过期、隐藏或不可交互目标。原始输入接收 1–256 个事件的 JSON 数组（也可 `@文件`），坐标是窗口内容区逻辑点，不含桌面坐标或标题栏；输入确认代表送达宿主，操作后必须用 AI 查询核对状态，再截图检查实际画面。截图同时输出同名 JSON，包含逻辑/像素尺寸、帧序号和来源；不包含系统窗口 chrome、遮挡或合成器内容。两个入口仅连接 loopback，支持相同令牌环境变量并有 15 秒超时。当前图片校验使用 macOS ImageIO；支持范围以宿主的 mirror capability 为准。

Gallery 可用 `--component tabs --width 390 --height 820` 在指定逻辑窗口尺寸启动，再通过这组入口验证窄窗、菜单及标题截断。布局与输入的场景回归仍覆盖尺寸动态往返和物理输入形态，截图不能代替 GPU 耗时或真机触摸测量。

时间线为有界环形缓冲，每个 facade 最多保留八份采集。采集只统计自身窗口内遗漏的 spans，报告 dropped。与 Inspector 同时采集时共同使用 recorder，任何一方结束不会停止另一方。取消或 session reset 不发布未完成采集。空闲采集可为零事件。父子 CPU spans 重叠，不可求和当作帧耗时；CPU draw/present 指标不代表 GPU 执行时间。编译时源码位置需要重建才能跟随源码移动。

## Skills

`AgentSkillLibrary(skills:)` 接收明确的值；`load(directory:)` 只读取配置目录的直接子目录中的 SKILL.md，拒绝越界 symlink。第一版 frontmatter 支持标量 name/description，正文最大 64 KiB，库最多 64 个 skill；不支持完整 YAML、自动读取引用文件或执行脚本。

内置 ui-diagnostics 指引与 AI 的 list/read 工具、MCP prompts 共用一份来源。AgentSession 只注入 enabledSkills 指定的内容。读取 skill 不授予工具或写权限；宿主仍拥有实际授权与业务校验。

## 验证

```sh
swift test --package-path GuavaUI/Portable
swift test --package-path Editor --filter 'EditorDiagnosticsTests|DeveloperParticleDiagnosticsTests|EditorProjectToolsTests'
swift build --package-path GuavaMcp
swift run --package-path Tools/Developer guava-dev validate mcp-protocol
swift run --package-path Tools/Developer guava-dev validate agent-diagnostics
```

Portable 核心无需 SDL 或 GPU。当前本机验收为 macOS；NIO 传输的 Linux/Windows 实现路径没有平台 no-op，其他平台仍需各自运行验收。
