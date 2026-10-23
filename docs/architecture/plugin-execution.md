---
path: /zh/docs/architecture/plugin-execution
title: '跨平台插件执行'
description: '跨平台插件执行 — GuavaStudio documentation'
locale: zh
translationKey: architecture/plugin-execution
category: architecture
order: 100
kind: doc
---

# 跨平台插件执行

Guava 插件以 `plugin.json` 为必选文件。纯声明插件只包含 manifest 和已声明的 `resources/` 资源，不创建插件宿主；需要执行代码时，`capabilities.wit` 与 `component.wasm` 必须成对提供。WIT 声明函数输入类型，WASM 承载 Component Model 代码，权限与 schema 不由运行结果决定。

## 声明式贡献与资源

`contributes` 使用有版本的命名空间键，每个值是该贡献点的声明数组：`guava.language/v1`、`guava.vcs/v1`、`guava.tasks/v1`、`guava.ai.provider/v1`、`guava.theme/v1`。`ContributionPointSpec` 由领域定义描述类型和验证规则，`ContributionPointRegistry` 执行解码与校验；未知贡献点、未知 major、重复声明 ID 会被拒绝。所有第一方 manifest 已直接迁移，不解码旧贡献键。

`resources` 为数组，每项包含 `id`、`path`、`kind`。路径必须位于 `resources/`，禁止绝对路径、空路径段、`..` 与任一级符号链接；禁止未声明的资源文件，单包资源总量限制为 16 MiB。资源按相对路径计算 SHA-256，读取时重新比对；完整 manifest、资源哈希以及可选的 WIT / component 哈希都绑定进授权记录和 authority digest。任何声明、资源或代码变化都需要重新授权。

运行时包可声明 `runtime`（`component`、`wit`、`compatibility: 1`）以及 `activation` 事件。当前阶段校验事件格式；按事件惰性激活和统一生命周期管理将在下一阶段接入，运行时插件仍沿用现有加载流程。

`./guava plugin build <source> --output <package.guavaplugin>` 同时支持声明式与运行时插件。纯声明源码无需 `Sources/` 或 WIT，打包不调用 Swift guest 编译器或插件宿主。

## 主题

`studio.theme.default` 从 `Editor/Plugins/Themes/Default` 打包为 `DefaultTheme.guavaplugin`，没有 WASM。`guava.theme/v1` 声明主题 ID、标题、`light/dark/dual` 外观以及主题资源路径。资源 `version: 1` 的 light / dark 分组支持语义色、字体、间距、圆角、动效、输入框、文本强调、阴影和语法配色；颜色支持 `#RRGGBB` / `#RRGGBBAA` 或四个 0...1 浮点通道，未知色槽及越界值拒绝注册。图标替换契约尚未开放。

每个编辑器会话拥有自己的主题目录，UI 读取只读快照。主题 ID 保存在 shell 偏好中，目录 revision 与刷新 revision 不进入持久化。切换、停用、重载只更新主题环境，保留面板节点和 AI 对话。主题不可用时使用 GuavaUI 的基础主题回退；修改资源后重载会进入现有重新授权流程。

声明式插件支持与运行时插件相同的检查、授权、启用、停用、重载和可选开发监视入口；监视包含已声明资源。当前 Web 导出仍面向运行时插件，并携带经过校验的静态资源。

设计参考：[VS Code 贡献点](https://code.visualstudio.com/api/references/contribution-points)、[激活事件](https://code.visualstudio.com/api/references/activation-events)及 [Zed 主题扩展](https://zed.dev/docs/extensions/themes)。

## 语言注册

编辑器的语言名称、文件图标与语言标识来自插件贡献，而不是内置扩展名表。随包分发的每个插件与当前已启用插件都会把 `contributes["guava.language/v1"]` 登记到同一张注册表；同 `id` 只保留先登记的一份。`icon` 可覆盖默认的图标键（默认使用语言 `id`，`plaintext` 用 `text` 图标）。`.tex` 由随包 `Plugins/Languages.guavaplugin`（`studio.languages`）登记为 LaTeX。已分布但未启用的随包插件仍参与识别，停用只影响其语言服务等运行时能力。

`grammar` 与 `outline` 是 `plugin.json` 中的静态数据，不是能力调用。宿主按数组顺序在整个文档上执行正则，已占用的字符不会被后续规则覆盖；`^`/`$` 按行匹配。语法规则只返回 `keyword`、`type`、`function`、`string`、`number`、`comment`、`attribute`、`directive` 八种 token，由宿主映射到统一调色板，插件不能贡献颜色。提纲规则要求第 1 个捕获组是标题，`level` 为 1…6，同一起点保留先出现的规则。两者都在编辑进程内执行，按键路径不进入 WASM，因此随包语言即使未启用也能着色和列提纲。

`format` 是唯一需要插件挂载的语言贡献：`format.entryPoint` 必须指向 WIT 中一个输入为 `record { text: string }` 的能力。编辑器在 `Option+Shift+F` 时调用它，单次最多 64 KiB 文本；返回结果是 JSON 字符串（读取类能力的通用结果格式），宿主解码后作为整篇文本一次替换。未声明、插件未启用或调用失败时文档保持不变，失败写入控制台。`studio.languages` 的 `format` 能力实现 LaTeX 的统一换行、行尾空白清理与连续空行压缩。

## Swift Support 捆绑插件

编辑器随资源包分发 `Plugins/SwiftSupport.guavaplugin`（`studio.swift-support`）。工作站启动时，仅从构建资源中的固定位置检查和授权该插件；项目目录、插件搜索路径和环境变量不能替换捆绑包。第三方插件仍走显式检查和授权流程。

`language-server` 导出通过 `guava:process/host` 转发有界的进程请求。宿主解析 `sourcekit-lsp`（显式工具链覆盖、PATH、macOS xcrun），拒绝项目目录内的可执行文件，再按已授权 manifest 校验参数和环境。SourceKit-LSP 运行在 PluginHost 管理的进程中，文档镜像、版本和语义查询由编辑器维护。语言服务入口不会暴露给 AI 能力规划器。

LSP 传输将大文档按 8 KiB 分块写入并轮询排空输出，保持原始 UTF-8 字节和 Content-Length 帧。停用、重载、宿主失效及项目关闭会停止语言服务并撤销旧句柄。`.guava/disabled_bundled_plugins.json` 只记录用户停用选择，临时进程句柄、LSP 状态和传输任务不持久化；设置页可以重新检查并启用 Swift Support。

插件源码位于 `Editor/Plugins/SwiftSupport`（`plugin.json`、`capabilities.wit` 与 Swift 源码，用 GuavaPluginKit 编写；guest 只把进程请求原样转给 `guava:process/host`）。修改后运行 `./guava plugin build Editor/Plugins/SwiftSupport --output Editor/Sources/EditorCore/Resources/Plugins/SwiftSupport.guavaplugin`，生成的包随资源提交；Git 与 Lore 插件同理。`BundledSwiftSupportTests` 验证捆绑包与源码的 manifest 和契约一致、真实 Component 契约、AI 隐藏、偏好往返，以及隔离宿主中的大文档传输与卸载。

本机安装 SourceKit-LSP 后，可运行 `GUAVA_TEST_REAL_SOURCEKIT=1 ./guava test Editor --filter BundledSwiftSupportTests`，额外验证通过真实插件和隔离宿主获得 String 成员补全及类型悬浮提示。

底栏“语言服务”显示当前 Swift 服务状态，SourceKit-LSP 子菜单提供日志、启动/重启和停止操作。停止只暂停当前会话，不撤销插件授权或修改持久化启用选择；文件刷新不会自动恢复，用户可以显式启动，重新启用/重载插件也会重建服务。

底栏另行区分进程状态与语义分析健康度。服务初始化成功只表示传输就绪；收到诊断或有效语义响应后才显示分析正常，标准库、SDK、模块加载错误会单独显示为分析不可用。面板保留有界的独立服务日志，显示服务端索引进度、实际工具链版本与路径、SDK 路径及可获取的进程 RSS；获取不到内存信息时不显示估计值。

工具链检测、安装、安全边界及编辑器语义操作见 [Swift 语言支持](../components/swift-language-support.md)。

`guava build/run Editor` 根据 `targets.desktopHelpers` 构建和捆绑 GuavaPluginHost；macOS 放在 `Contents/Helpers` 并单独签名，Windows/Linux 放在 `Tools`。Swift 工具链需要单独安装，插件不携带编译器或 SourceKit-LSP 二进制。

`guava run` 通过宿主环境 `GUAVA_BUILD_PRODUCTS_PATH` 传递本次构建产物位置，让打包后的编辑器仍能发现脚本分析所需的 Swift 模块和 Clang module map。显式 `GUAVA_ENGINE_*` 覆盖仍优先；安装后的 SDK 需要提供对应模块路径，项目文件不能配置这些宿主路径。

## 跨平台宿主

| 宿主 | 运行库 / 执行方式 | 生命周期与隔离 |
| --- | --- | --- |
| macOS、Windows、Linux 桌面 Editor | 静态链接 Wasmtime 49.0.2 | `GuavaPluginHost` 独立进程、带长度帧 RPC |
| Android 应用 | 同版本 Wasmtime C API | `EmbeddedPluginSession`，应用进程内的 fresh Store |
| iOS 16+ 应用 | 同版本 Wasmtime + Pulley | 强制解释执行，应用进程内的 fresh Store，不要求 guest JIT |
| Web | 经原生校验的 Component + Jco | 每次调用独立 Worker / Wasm 实例，超时终止 Worker |

原生包的版本与校验值来自 [Wasmtime catalog](../../Engine/third-party/wasmtime/catalog.json)。交付方式与构建步骤见 [构建说明](../../Engine/third-party/wasmtime/README.md)。所有原生目标使用 `Wasmtime.artifactbundle`，支持一次保存多个 variant，不依赖本地 Wasmtime CLI。原有无法调用强类型 ABI 的 CLI 适配器和动态 XCFramework 路径已移除。

桌面继续使用进程宿主的检查、授权、加载、准备、卸载流程。静态链接消除了发行包额外寻找 Wasmtime 动态库的要求。移动应用通过异步入口使用相同的授权校验和结果验证：

```swift
import Foundation
import PluginRuntime
import PluginWasmtimeRuntime

let inspection = try await EmbeddedPluginSession.inspect(at: packageURL)
// 应用展示身份、imports、access、contracts，取得用户授权后保存这份精确记录。
let authorization = try PluginAuthorizationRecord(inspection: inspection)
let plugin = try await EmbeddedPluginSession.open(at: packageURL, authorization: authorization)
let result = try await plugin.prepare(
    capabilityID: "safe.reader.inspect",
    input: Data(#"{"enabled":true}"#.utf8)
)
```

`open` 创建宿主私有执行副本并重新核对 code/WIT/manifest/契约；用户修改来源目录不会改变已经打开的会话。会话使用 actor 串行执行，昂贵工作不要求调用方安排主线程以外的线程。每次调用重新创建 Store，应用不需要传递 Wasmtime 内部上下文或句柄。自定义宿主写入能力的应用可传入自己的 `CapabilityRegistry`，返回的 host calls 必须由该应用现有的授权执行入口提交。

## 依赖声明（`requires`）

`plugin.json` 可以用结构化条目声明依赖，缺省为空：

```json
"requires": [
  { "kind": "plugin", "id": "studio.core", "minimum_version": 2 },
  { "kind": "capability", "id": "studio.core.draw" }
]
```

- **校验**：`PluginManifestValidator` 拒绝格式错误、重复（同 kind+id）和自引用（plugin 自指、capability 指向自身单个 WIT 导出；不同嵌套插件 ID 允许引用）。
- **解析与顺序**：启用是增量的——新插件的每条依赖都必须指向已启用插件或已注册能力（内置或先前插件的契约）。启用顺序是拓扑序；组合注册表还会对整个绑定集独立检查缺失、最低版本与依赖环，不能仅依赖 UI 的启用顺序。
- **权限**：`requires` 不授予任何权限：不改变 `access` / `imports`，不自动启用或自动授权依赖方；被依赖插件仍需自己的授权记录。依赖列表绑定进 `PluginAuthorizationRecord`（参与 `isStillValid` 与 `authorityDigest`），改动依赖必须重新授权；授权记录缺少该字段时直接拒绝解码，要求重新授权；不维护旧记录解码层。
- **停用**：存在 plugin 依赖或指向该插件实际契约的 capability 依赖时，`disablePlugin` 拒绝并列出依赖方；正常停用不级联卸载。重载在卸载后失败时，为保持依赖不变量，会撤下目标及递归依赖方。
- **解析器**：`PluginRequirementResolver.unmet(_:requiredBy:enabledPlugins:providedCapabilities:)` 与 `dependents(of:providing:among:)` 是纯函数，Editor 用已挂载版本表调用解析器。嵌入式与 Web 的单包 Session 不管理插件集合，宿主应用须在 open 前解析依赖，并在停用时维护依赖；仅传入 CapabilityRegistry 不代表依赖已挂载。

## 重挂载与失效范围

已启用的插件可以经 `EditorApplication.reloadPlugin(id:)` 在同一宿主代际内 `unload + load` 重挂载。package 必须仍满足其存储授权（`PluginAuthorizationRecord.isStillValid`）；不满足时以 `pluginAuthorizationStale` 拒绝且**在卸载之前**抛出，旧绑定保留（源包变化后的 prepare 仍被宿主拒绝）。卸载开始后失败撤下目标及依赖方，返回显式错误；启用、停用、重载互斥执行，防止跨 await 覆盖绑定。管理面板重新授权后可替换已启用版本；仍被其他插件依赖时须先停用依赖方。

暴露会话的失效按插件的 authority 收窄：snapshot 引用了 authority 变化 / 被停用 / 被移除的插件的会话被丢弃；authority、契约和非插件策略身份均未变化的会话保留；保留的草案使用本次注册表验证，且每次跨 actor 操作后重查会话是否仍有效。非插件策略身份变化（域名、发布阶段、能力上限）仍整体失效。

重挂载有三个入口：管理面板的 "Reload" 按钮、dev 目录监视（`--watch-plugins` / `GUAVA_WATCH_PLUGINS=1`，默认关闭；同 authority 自动重挂载，变化则提示重新授权）、MCP 工具 `reload_plugin`。

宿主每次故障都推进 `hostGeneration` 并通知失效，包括用尽首次立即重启机会后的故障；显式停止也推进代际。Editor 清除旧绑定与组件声明，待确认计划在使用点重查 authority。

原生保留 fuel、Store memory/table/instance 限制、epoch interruption 和 wall-clock deadline。iOS 使用的 Pulley 保留这些 API，但执行性能不能按原生机器码估算。移动进程内隔离无法提供桌面独立进程对运行库崩溃的隔离；组件编译也不具备可抢占的 epoch 中断。

`host.processes[].entryPoints` 声明的入口只由编辑器调用、不暴露给 AI，用来传递整段工具输出：宿主对它们不施加 WIT 派生的长度上限（字符串 64 Ki、列表 4096），输入输出上限 256 MiB、内存 256 MiB、燃料实际不限，只保留每次调用的 wall-clock deadline。AI 能力保持 1 MiB 输入输出与原有燃料。RPC 帧上限为 512 MiB，只是传输边界。版本控制插件按窗口分页读取命令输出，每次调用都很短。

运行库按路径与完整字节缓存编译后的 Component：每次调用仍重新读取文件并逐字节比较，内容一变就重新编译；未变时直接复用，避免每次调用都用 Cranelift 编译。

Web 构建阶段复用 Swift 宿主的真实 Component 类型检查和权限校验，运行时消费其导出的 WIT 类型、inspection 和 host contracts。应用可信目录固定转换产物的哈希；用户授权再绑定精确版本。Worker 只链接获准的三个 Guava 查询接口，使用本次 revision-bound JSON 快照。浏览器无法提供 Wasmtime fuel/epoch，采用 Worker wall-clock deadline 并在 core Wasm 中编码 memory/table 上限。完整步骤、API 和边界见 [Web 插件目标](../../Platforms/Web/Plugins/README.md)。

验证分两层：`PluginRuntimeTests` 检查 Swift 授权、immutable staging、typed input、进程 RPC、查询和中断；`Engine/Validation/Plugins` 的同一组 Component fixture 可在本机、Android 真机和 iOS Simulator 执行。Web 的浏览器 gate 再复用这些 fixture 检查转换与 Worker 路径。Windows/Linux 运行库由各自 CI runner 执行，Mac 上的交叉构建不能代替这两种系统的实际运行验证。
