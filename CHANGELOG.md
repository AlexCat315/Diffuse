# Changelog

## Unreleased

- 编辑器改名为 Diffuse，Cove SDK、模块、CLI、工作区配置、发布包与插件宿主名称同步迁移；固定依赖 Cove SDK 0.2.0。

- SDK 安装器按固定版本获取，不再依赖 Latest 中的安装脚本；显式本地 SDK 覆盖支持联调。
- 固定分辨率游戏预览生成有效区域内的 GPU mip 金字塔，UI 按显示像素选择 LOD，避免缩小时采入容量 padding；旧快照继续拥有各级纹理。

- 跟进 GuavaUI 0.1.13 SDK；窗口不可呈现时停止视口连续帧请求、跳过视口与 HUD 绘制，恢复时重新收敛 TAA；失效／更换的视口输出不再留在图像附件缓存中。
- 原生场景目标在大幅缩小并稳定一秒后回收过大容量，扩容仍立即进行；旧纹理快照的所有权保持有效，面板拖动期间避免反复分配。

- 去掉欢迎页与项目启动器（新建、打开、最近项目、示例项目），窗口可同时打开多个项目：每个项目各自保留编辑器、场景与 Agent，不在前台时 Agent 继续工作，只有前台项目运行场景与渲染。启动时 `--project-dir` 优先，否则恢复上次打开的项目列表与前台项目，都没有时不打开任何项目，窗口就是项目列表为空的 Agent 视图，由左侧“项目”旁的 + 或“文件 › 打开文件夹…”（⌘⇧O，⌘O 仍是打开场景）添加项目，添加前输入框不可用。窗口默认显示 Agent 视图，工作台在标题栏切换。任意文件夹都可作为项目打开，没有 `.guava` 的文件夹只新增 `.guava/project.json`，其余文件不变。Agent 视图左侧列出所有项目与前台项目的任务，后台项目显示工作中或待审阅数量，点击即切到前台；工作台标题栏的项目按钮改为项目菜单（切换、打开文件夹、关闭项目）。“关闭项目”只移除当前项目并切到下一个；退出时逐个询问各项目未保存的更改。打开的项目列表存为 `GuavaOpenProjects` / `GuavaActiveProject`，不再读取 `GuavaRecentProjects`。各项目的通知、工作台链接、Agent 视图状态与最近命令在关闭时释放。新增 `EditorProjectLifecycle.adopt(_:)`；`EditorLaunchContext` 改为持有多个项目（`openProject`、`activate`、`closeProject`、`restoreProjects`），`WelcomeView` 与 `RecentProjectsStore` 删除。`ProjectWorkspaceTests` 覆盖无项目时的空 Agent 视图、并行项目的切换关闭与重启恢复、普通文件夹打开，以及已编译可运行的项目在另一个项目在前台时保持状态。

- Windows 系统能力统一到 GuavaUI 的 `GuavaFileSystem`、`GuavaProcess`：插件宿主、LSP、工具发现、原子写入、权限和路径检查共用实现，移除 Engine 的重复进程运行库与 Editor 的本地替换器。测试辅助程序预先构建，不再在测试中临时调用编译器。CI 分开构建与执行、分开 XCTest 与 Swift Testing，缓存编译和原生依赖，并在 Windows 超时前保存事件与进程转储。跨仓库验证通过 `.github/sdk-revision` 固定完整 SDK 提交；版本仍由 `Editor/guava.json` 校验。

- GuavaUI 拆为独立 SDK：UI 与通用底层（NativeRHI、PlatformShell、日志、平台值、图像解码、CLI、DevTools）归 SDK 所有，场景与三维渲染（RenderBackend、SceneRuntime、物理、EngineCore）留在 Studio。`GuavaUI` 不再依赖任何 Studio 包，`Engine` 只消费 SDK 的通用底层产品，两侧通过图形结果交互——引擎输出 `ViewportSurfaceState` 纹理交给 UI 的图像绘制，UI 输出 `DrawListSnapshot` 由宿主通过 `InGameUIProviding` 在引擎的绘制位置录制。`boundaries` 新增两条断言：SDK 不 vend 引擎产品且不依赖 Studio 包，Engine 不引用 Compose / 运行时 / 窗口产品。引擎桥接与 NativeRHI、PlatformShell、日志、平台值迁入 `GuavaUI/`（`Engine/Logging`、`Engine/PlatformCore`、`Engine/Sources/NativeRHI`、`Engine/Sources/PlatformShell` 删除），CLI 迁到 `GuavaUI/Tools/Guava`，Android 契约迁到 `GuavaUI/Hosts/Android/Contract`；Studio 专有的 Android 导出与插件构建移入 `guava-dev`。根目录 `Tools/Guava` 删除，`./guava` 与 `guava.cmd` 委派给 SDK CLI，`./guava studio` 委派给 `guava-dev`。`guava.json` 的 `toolchain.enginePath` 由 `toolchain.sdkVersion` 取代，脚手架与示例模板同步。脚本编译器的 Clang modulemap 发现支持 `umbrella header` 形式，并能跨 `Engine/Sources/Bridge` 与 `GuavaUI/Runtime/Sources/Bridge` 两处桥接根。

- 一切皆插件：Swift 的语言服务、构建、测试与运行都由 Swift Support 插件声明和决定，编辑器只提供通用引擎。`plugin.json` 新增 `contributes.languages`（语言 id、扩展名、语言服务器的进程权限、`initializationOptions`、`settings` 与 `watchedFiles`）与 `contributes.tasks`（项目标记文件，如 `Package.swift`）；`PluginJSON` 承载任意 JSON。哪些文件走语言服务、`didOpen` 的语言 id、初始化参数（宿主只补充引擎模块搜索路径）、`workspace/configuration` 与外部改动监听都来自插件声明。Swift Support 新增 `package` 进程权限（`swift`）与 `tasks` 入口：插件决定 `describe`、`build`、`test`、`run`、`clean`、`resolve` 的命令，并自己读取编译器问题（去掉终端颜色码）与 XCTest / Swift Testing 结果；编辑器不再直接调用 `swift`。GuavaPluginKit 的步骤协议从 `VersionControl` 拆为通用的 `Steps`（新增 `stream`：编辑器实时显示输出、不限时，交给插件的输出包含按顺序合并的标准错误），编辑器侧对应的挂载与执行移到 `EditorCore/Contributions`（`StepPlugins`、`StepPlugin`），Git、Lore 与任务共用一个插件宿主。`SwiftPackageTaskTests` 用真实 Component 与录制的 SwiftPM 输出覆盖命令选择、`describe`、问题与测试结果，`ComponentBuildTests` 覆盖新贡献点的校验。

- “任务”面板（项目带有某个插件声明的标记文件时出现在活动栏）：工具栏只有构建、运行测试、运行、停止、清理五个图标；下方是测试树与插件描述的项目内容（产品、目标、依赖）。测试由语言服务从索引中发现（`workspace/tests`），无需构建，语言服务就绪、索引完成、保存文件与每次任务结束后自动刷新；每个测试可单独运行，失败显示第一条问题。任务输出在终端面板的任务标签中显示（`TerminalSession.display()` 只显示交给它的输出，保留颜色），编译器问题并入“问题”列表与状态栏计数，任务状态只在状态栏显示。命令面板与“运行”菜单新增“运行构建任务”“运行测试”（⌘U），仅在写作与游戏 Space 中出现。

- 语言服务在打开项目时即启动：项目中有插件声明的语言的文件时，不必先打开某个文件，后台索引立即开始；关闭最后一个文件也不再停止服务。

- 代码编辑器新增小地图（`TextFieldCodeEditing.showsMinimap`）：右侧按语法着色的缩略全文，标出可见区域，点击或拖动即可滚动，长文件随正文按比例滚动；显示小地图时不再绘制纵向滚动条。

- Swift 支持补齐：补全列表显示选中项的文档，缺失时通过 `completionItem/resolve` 按需获取；悬停按 Markdown 渲染（代码块、列表、链接）；光标所在符号的其他出现处高亮（`documentHighlight`，`TextFieldCodeEditing.occurrences`）；命令面板搜索整个工作区的符号（`workspace/symbol`），可直接打开项目中的任意 Swift 文件；有选区时“格式化”只格式化选区（`rangeFormatting`），设置 › 编辑器 › Swift 可开启保存时格式化；诊断保留 `tags` 与 `relatedInformation`，未使用的代码变淡、已弃用的名称加删除线，问题面板列出关联位置并可跳转；代码操作按快速修复、重构、源代码操作分组。语言服务在保存时发送 `didSave`，每 2 秒检查项目内 Swift 文件与 `Package.resolved` 的外部改动并发送 `workspace/didChangeWatchedFiles`，`workspace/configuration` 按 section 返回真实设置。参数提示只显示文档首段，不再遮住代码。`AssistanceReplyTests` 覆盖。

- Swift 语言服务覆盖项目里的所有 Swift 文件：打开任意 `.swift` 标签即获得补全、悬停、跳转、大纲与诊断，不再只限于 `Scripts/`；这些文件原地分析、原地保存，不会编译进游戏。SourceKit-LSP 以项目目录为第二个工作区根，Swift 包使用自身的模块与后台索引（`.build/index-build`，跨会话保留）。脚本分析用的影子包移到项目 `.guava/sourcekit-lsp`（自带 `.gitignore`，不再在没有脚本的项目里生成 `Scripts/`），其 scratch 路径写入该包自己的 `.sourcekit-lsp/config.json`。`ScriptLanguageWorkspaceTests` 覆盖。

- 内置插件改为目录驱动：编辑器列出 `Resources/Plugins` 中的全部包，由 manifest 决定运行位置（共享插件宿主或版本控制宿主），设置 › 扩展统一列出并开关 Git、Lore、Swift Support；版本控制标记冲突时按 `contributes.versionControl.priority` 决定。

- 源代码管理：差异改为在编辑器中以单独标签打开（双侧行号、增删着色、虚拟化滚动，可暂存、取消暂存、放弃），随文件在暂存区与工作区之间移动；活动栏更改数徽标移到图标右下角；状态栏只显示编辑器自身的警告。语言服务状态改为卡片：状态、原因、分析范围与日志、工具链分页。

- AI 服务商密钥不再存入钥匙串，改存 `~/Library/Application Support/GuavaStudio/Credentials/ai-providers.json`（文件 0600、目录 0700，仅当前用户可读，原子替换写入），开发构建重新编译后不再弹出钥匙串授权；未保存密钥的服务商仍读取 `ANTHROPIC_API_KEY` 等环境变量。`AIKeychain` 更名为 `AICredentialStore`，凭据来源 `.operatingSystemStore` 改为 `.credentialFile`；开发构建恢复普通 ad-hoc 签名。旧钥匙串条目不会读取，需要重新输入一次密钥。

- 版本控制（捆绑插件）：新增 EditorCore `VersionControl` 模块，`EditorVersionControl` 统一驱动 Git 与 [Lore](https://github.com/EpicGames/lore)。两者都是用 Swift 编写的捆绑插件（`Editor/Plugins/Git`、`Editor/Plugins/Lore`，产物在 `Resources/Plugins/*.guavaplugin`）：插件决定运行哪条命令、怎样解析输出，编辑器按 manifest 的进程权限执行命令、异步等待，再把输出交回插件，直到插件返回结果，插件宿主不会被长命令卡住；放弃新文件时插件返回 `trash`，编辑器检查路径在仓库内后移到废纸篓。`plugin.json` 新增 `contributes.versionControl`（系统 id、显示名、标记 `.git` / `.lore` 与忽略文件），WIT 只导出 `provider: func(input: { request: string, stdout: string }) -> string`，进程请求沿用 `guava:process/host`，插件不解析、原样转发；版本控制插件运行在单独的插件宿主进程里，轮询不会排在 AI 插件或语言服务之后。从项目目录向上查找标记（同一目录两者都有时 Lore 优先），无 shell、不提示凭据、限时限量地调用命令行工具；GUI 进程 PATH 之外还会查找 Homebrew 与 `~/.local/bin`（Lore 安装位置）。Git 使用 `status --porcelain=v2 -z`，路径列表经标准输入传递（`--pathspec-from-file`）并按字面匹配；Lore 使用隐藏的 `--json` 事件流读取状态、分支与文件锁，`history --oneline` 读取历史，长路径列表分批执行。命令输出按 1 MiB 窗口分页交给插件：插件每页返回结果片段和已读字节数，编辑器拼接片段，需要整段输出的解析（如 Lore 分支去重）读不到内容时编辑器自动加宽窗口，输出大小不再受限（测试覆盖 5 万条变更）。命令串行执行，执行后重新读取工作区；拉取、放弃更改与切换分支后，未修改的已打开文档会自动重新载入。新增“源代码管理”面板（分支菜单与新建分支、拉取/同步与推送及领先/落后计数、提交框 ⌘↩、AI 生成提交信息、暂存/未暂存分组、行内差异、Lore 文件锁、历史），未初始化时可一键初始化 Git 或在 Lore 服务器上创建仓库。活动栏显示更改数，状态栏显示分支与同步状态，“文件”树按工作区状态为文件着色并标记含更改的文件夹。Agent 新增 `vcs_status`、`vcs_diff`、`vcs_log`、`vcs_commit` 工具。`VersionControlTests` 用真实组件解析 Git porcelain 与 Lore 事件流的录制输出，并在真实 git 仓库上端到端覆盖初始化、暂存、取消暂存、提交、差异、放弃与建分支。

- 插件 SDK：新增 `Engine/PluginKit`（GuavaPluginKit），用 Embedded Swift 编写插件：分配器与 `cabi_realloc`、规范 ABI 字符串输入输出、`guava:process/host` 调用，以及替代 Codable 的小型 JSON 库。新增 `guava plugin build <目录> [--output PATH.guavaplugin]`：把 SDK 与插件源码编译成 `wasm32-unknown-none-wasm` 核心模块，由 `GuavaPluginHost --component-shell` 按 WIT 生成组件外壳与导出绑定，`--link-component` 编译外壳并替换其中的占位核心模块，不需要手写 WAT。每个能力对应插件里的普通 Swift 函数。`ComponentBuildTests` 覆盖贡献点校验、外壳与绑定生成，以及链接后的组件在 Wasmtime 中运行。`guava test` 对应用工程先构建 `targets.desktopHelpers`，依赖 GuavaPluginHost 的测试不再用到旧的宿主。

- 插件宿主：`host.processes[].entryPoints` 声明的编辑器入口（不暴露给 AI）不再受 WIT 派生的长度上限（字符串 64 Ki、列表 4096）约束，输入输出与内存上限提高到 256 MiB，燃料实际不限，只保留每次调用的墙钟时限；AI 能力仍为 1 MiB 与原燃料。RPC 帧上限提高到 512 MiB，进程每次轮询最多返回 4 MiB。运行库按路径与完整字节缓存编译后的 Component，内容不变时不再每次调用都重新编译，真实 git 端到端测试从约 12 秒降到约 4.6 秒。Swift Support 插件改用 GuavaPluginKit 以 Swift 编写（`Editor/Plugins/SwiftSupport`），删除手写的 `component.wat`；`BundledSwiftSupportTests` 改为校验捆绑包与源码的 manifest 和契约一致。


- 写作模式：所有文本文件共用同一个编辑面（13/20 等宽、行号、小地图）与同一条写作栏（路径、自动换行、AI、专注模式），不再按代码 / Markdown / 纯文本分流，也没有源码 / 分栏 / 预览切换；Markdown 源码在该编辑面中直接编辑，`MarkdownView` 只负责渲染，格式命令仍由 ⌘B / ⌘I / ⌘K 触发。编辑区底部显示字数（中日韩字符按字计）、字符数、阅读时间、选中字数和行列位置。新增“文档大纲”面板：标题列表、筛选、统计，点击标题跳转光标（`EditorDocumentWorkspace.reveal`）。“文件”面板支持新建文件、重命名与移到废纸篓（`DocumentWorkspace.create/move/remove`）。`WritingTests` 覆盖格式化、统计与标题解析。

- AI：`Session.complete(instructions:prompt:)` 提供不带工具和场景上下文的单次文本补全（Anthropic、OpenAI Chat 与 Responses 三种格式）。写作栏新增“AI 写作助手”：对选中内容或整篇文档润色、纠错、精简、扩写、改写语气、中英互译、总结、续写、生成大纲或按自定义指令修改，结果先预览，再选择替换、插入或复制。Agent 回复按 Markdown 渲染并可复制，写作 Space 新增“润色这篇文档”“审查我未提交的更改”等起点。`CompletionTests` 覆盖三种响应格式。

- 布局：工作区面板区域改为 CSS `overflow: auto` 语义：面板按区域高度布局并放入纵向 ScrollView，放不下的刚性内容可以滚动查看，自带滚动的面板（控制台等）仍只滚动自己；开发者工具“概览”不再被截掉底部（概览保持自然高度）。修复控制台与构建输出在输出面板中不收缩的问题：它们原来按完整内容高度布局，日志末尾约 300pt 被区域裁掉、无法滚到。Tree、List 与菜单行的宿主统一用 `LayoutNode.rowSlot`（纵向居中），修复比行矮的内容贴在行顶部、悬停和选中底色与文字不居中的问题；`RowSlotTests` 覆盖。`get_diagnostics.layoutIssues` 分为 `invalidGeometry` 与新增的 `clippedOverflow`（被非滚动裁切截掉的纵向内容，含 `hiddenHeight` 与源码位置），`Node.isScrollViewport` 标记纵向 ScrollView；`AccessibilityModifier` 把 `tabPanel` 与 group、list 等一样视为容器角色，留在容器上而不转给唯一的子控件（面板区域的 ScrollView）；`DiagnosticsTests`、`WorkspaceViewTests` 覆盖。

- 写作 Space 细节对照原型修正：`WorkspacePanel.hidesTabBarWhenAlone` 让自带标签的面板（编辑器的文件标签）在独占分组时不再叠一行“编辑器”面板标签，与其他面板合组时标签条恢复；`WorkspaceViewTests` 覆盖两种情况。所有文本（含 Markdown 源码）统一使用 13/20 等宽字体、行号与小地图。标题栏意图框的上下文芯片改为末尾省略号截断并显示完整提示。GuavaUICore 新增 `LineBreaks`（由富文本的 `RichTextBreaks` 移入），`TextLayout` 也按它在汉字之间换行，并遵守避头尾规则，“。”“，”等不再单独落到行首；`TextLayoutRegressionTests` 覆盖。SourceKit-LSP 生命周期测试的假服务器改用 `read(2)` 读取标准输入：`FileHandle.read(upToCount:)` 会等满整个缓冲区或 EOF，导致 initialize 一直无回复。

- 写作 Space 重做：左侧新增“文件”面板（文件夹树、打开与未保存标记、右键操作），中间“编辑器”改为文件标签、路径栏和编辑区，关闭未保存的标签先询问是否保存，Swift 文件使用脚本编辑器的着色与折叠，空状态居中并提供“打开文件 ⌘P”；去掉原来的路径输入框与按钮行。文本 Space 中 ⌘S 保存当前文件，新增“放弃修改”和 ⌘W“关闭文件”，场景命令不再出现；⌘P 可搜索项目文件。系统菜单新增“选择”“世界”。标题栏按原型重做：项目首字母（真实的叶绿到番石榴粉渐变）、git 分支、随 Space 变化的面包屑（文件路径或场景 › 实体）、带上下文芯片的意图框、你与 Guava 的在线头像，以及运行目标、实心构建图标和按状态显示的试玩控制组成的运行区。修复活动栏和状态栏在切换 Space、切换面板后不刷新，以及切换到已打开文件时编辑器和标题栏停在旧文件的问题。`DocumentEditingTests`、`CommandCatalogTests` 与工作台测试覆盖文件树、标签关闭、文本 Space 命令和活动栏刷新。

- 新增两色线性渐变 `UILinearGradient` 与 `.background(_:)` 渐变重载：`DrawList.addLinearGradient` 复用圆角矩形几何及其一像素覆盖边缘，按位置给每个顶点着色（两色线性渐变在三角形内插值是精确的），`Node.backgroundGradient` 由两种渲染器在实心背景的位置绘制，并随节点透明度变化。`LinearGradientTests` 覆盖 CSS 角度、圆角边缘与顶点颜色。修复 `UIIcons.Editor.hammer` 缺少锤头路径的问题（原来看起来像一支笔），恢复完整的 Lucide 锤子。

- `WorkspaceController` 遵循 `_ObservableObject`，工作区外的视图可用 `Observed(\.version, on: controller)` 观察布局变化。

- 设置改为带分类导航、全局中英文搜索和窄屏分类菜单的独立工作台。重构外观预览、语言、选择、垂直同步、Agent 服务商与凭据、执行审阅、能力门控及插件管理，加入来自同一命令目录的快捷键参考和诊断信息复制。普通偏好即时保存，Agent 更改显式应用或放弃；窗口会话保留草稿，跨分类、搜索、主题与语言更新不丢失输入。支持 `./guava run Editor -- --settings --project-dir PATH` 直接打开设置主窗口。

- 编辑器命令改为单一目录 `EditorCommandCatalog`：macOS 菜单栏、Windows/Linux 标题栏菜单、⌘/Ctrl+K 命令面板与窗口内快捷键都由它生成，移除原来平行维护的菜单模型、面板命令表和快捷键表。顶级菜单为文件、编辑、视图（Space 与布局子菜单）、Agent、运行、窗口、帮助；工作区不授权的命令不再显示为灰色项。新增 ⌘P 打开资源、⇧⌘P 命令、⌘↩ 试玩/暂停、⌘0 重置布局。Windows 不再没有菜单：沉浸式标题栏最左侧提供同一棵命令树。状态栏改为错误/警告计数、Space、未保存、后台活动与 Agent 状态，计数与控制台“问题”共用 `EditorProblemSummary`；窄窗口播放控制收成试玩/暂停与停止。`CommandCatalogTests`、`ShortcutHandlerTests`、`EditorNativeMenuTests` 与工作台标题栏宽度测试覆盖两种菜单呈现。见 [工作站边界](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture/workstation.md)。

- `NativeMenuItem` 新增 `.submenu`，`NativeMenuBar` 新增 `applicationItems` 与可本地化的 `NativeApplicationMenuTitles`：macOS 应用菜单依次放入调用方的关于/设置项、隐藏、隐藏其他、全部显示与退出。`UIIcons.Navigation.menu` 新增菜单图标。

- `Toggle` / `Checkbox` 新增 label 槽：`Toggle("Notifications", isOn:)` / `Checkbox("Accept the terms", isOn:)` 将文本放在控件 trailing，控件辅助功能 label 使用该文本且不新增可聚焦节点。`BoolControlLabelTests` 覆盖 label、单一 toggle/checkbox 语义与激活；Gallery Toggle/Checkbox 页改为带标签设置行。补齐 `adaptive-spec.md`、`gaps.md`、[Toggle](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/toggle.md) 与 [Checkbox](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/checkbox.md)。

- `CommandPalette` 新增 `footer` `@ViewBuilder` 初始化器：自定义 footer 替换默认快捷键提示，保留顶部 1pt 分隔线、搜索/排序/最近使用/执行路径与面板几何。`CommandPaletteFooterTests` 覆盖自定义/默认 footer；Gallery Command Palette 页新增 “Open with project footer” 与 Aurora workspace footer。补齐 [CommandPalette](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/commandpalette.md)、`adaptive-spec.md` 与 `gaps.md`。

- `StatusBarText` 文本/detail 单行截断，leading 让位给 trailing 连接状态，完整内容保留在辅助功能 label/value；`DefaultPanelStyle` 标题单行截断并为 accessory 留位。`StatusBarPanelTruncationTests` 在 320pt 状态栏与 240/600pt 面板上验证截断行数、宽度与 a11y；Gallery StatusBar/Panel 页新增长分支与长标题示例，DevTools 720×820 实测状态文字单行截断、面板标题 203pt 且 accessory/连接状态完整可见。补齐 `adaptive-spec.md`、`gaps.md` 与 [Panel](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/panel.md)。

- 新增 `ChartLegend`：`ChartSeries.title` 为序列提供图例名称，图例在宽容器单行、窄容器按整项折行；色块为装饰，完整标题作为辅助功能名称。`ChartLegendTests` 3/3 覆盖折行、空标题过滤、投影与 RTL；Gallery `chart` 页新增多序列图、宽/窄图例与 “Show signups” 开关，DevTools 实测窄图例换行、点击开关后图例项减少。补齐 [Chart](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/chart.md)、`adaptive-spec.md` 与 `gaps.md`。

- 新增 P2 `Masonry` / `MasonryLayout`：按最短列放置的平衡瀑布流，列数由 `minimumColumnWidth`、`maximumColumns` 与实际宽度决定（窄宽自动单列，RTL 镜像列顺序），支持列间距、项间距与列内水平对齐。高度由子视图自然测量，不二次缩放字号；不虚拟化，大集合仍用 `LazyGrid`/`VirtualStack`。`MasonryTests` 4/4 覆盖最短列、单列退化、列数上限与 RTL；Gallery 新增 `masonry` 页与 390/720/1280 预览，DevTools 实测 720pt 两列、390pt 单列、Add card 后计数 8→9。补齐 [Masonry](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/masonry.md)、`layout.md`、`adaptive-spec.md` 与 `gaps.md`。

- `NavigationRail` / `Sidebar` 的纯图标轨改为居中的 40×40 圆角选择块：移除 2pt accent 侧条和铺满整行的选择/悬停底，选中态用 `surfaceVariant`，hover/press 只叠中性 state layer 并把图标从 `onSurfaceVariant` 提亮到 `onSurface`。带文字形态保留整行胶囊，但同样去掉 accent 侧条并改为对称内边距。`NavigationRailTests` 断言选择块与图标双向居中、无 accent 侧条及 hover 颜色；Gallery 窄宽壳层同步生效。

- 新增 P2 `ActionSheet`：所有宽度统一为底部操作抽屉；compact 全宽贴底并带顶部拖拽柄，支持下拉/高速释放与外部点击关闭，短拖回弹，不显示关闭图标；medium/expanded 为最大 560pt 的居中抽屉，右上提供 44×44pt 关闭图标。头部固定、操作列表独立滚动并保留底部安全区；操作行之间使用 1pt 分隔线，hover/键盘焦点只叠中性 state layer，移除突兀的 accent 焦点边框。移除底部 Cancel，`closeLabel` 由调用方必填并用于 wide 关闭图标的辅助功能名称/tooltip，组件不硬编码英文文案。稳定 ID 操作、图标/危险/禁用、键盘导航与一次回调；跨宽度切换保留触发器与打开状态。Gallery 新增项目操作、长列表和三档预览，补齐两份规范及组件文档。

- 新增 P2 `Popconfirm`，与 `Popover` 共用不透明卡片、箭头、焦点和十二向定位。指定方向保持不变，空间不足时限制视口并滚动；菜单/选择器显式选择 `.content` 表面与 `.flip` 避让。Cancel/Confirm 使用真实 Button，普通文字按钮取消默认重复 tooltip，额外提示通过 `tooltip:` 提供。危险操作仅确认按钮使用红色实底。Gallery 改为紧凑定位面板与窄屏单锚点预览；测试覆盖方向/RTL、主题/字号/输入矩阵、确认一次与焦点/清理，DevTools 实测取消、Escape、删除/归档及十二个指定方向。
- 新增 P2 `TimePicker`：复用 WheelPicker 组成 12/24 小时、可选秒与 AM/PM 列，`TimeOfDay?` 绑定、min/max 夹紧、minuteStep；`TimePickerTests` 2/2，Gallery `timePicker` 与 390/720/1280 预览。WheelPicker 行文本改为行容器双向居中，自适应预览固定 240pt 居中，音量卡在窄宽纵向堆叠，修复右侧裁切与直角边界。
- 新增 P2 `WheelPicker`：五行视口、中央选中 band、按距离淡出、pointer 拖拽/点击、wheel、方向键/Home/End 与 slider a11y increment/decrement/setValue；disabled 行跳过。Gallery 新增 `wheelPicker` 三列时间 + 音量示例，`WheelPickerTests` 4 tests / 2 suites。DevTools 通过 keyboard/wheel 实测 value 逐格变化并截图验收 390/720/1280。
- 新增可选 `GuavaUIWebView` 产品：`WebView` 在 Compose 树中承载平台原生网页视图，负责 frame、裁剪交集、隐藏/滚出视口、`NodeResource` 生命周期和状态回调；macOS 提供 `AppleWebKitHost`（`WKWebView`，含标题/加载/前进后退状态与文件/HTML 加载）。Demo 新增 `--component web` 页，提供离线 HTML、example.com、仓库页面与导航控件；非 macOS 平台显示后端缺失提示。`GuavaUIWebViewTests` 11/11 覆盖裁剪/隐藏/滚出/零尺寸、surface 创建/复用/重载/卸载与 handle 绑定；DevTools 实测本地 HTML、example.com、Reload 与前进后退状态。其他平台仍需实现 `WebViewHost`。
- Text Editor 补齐 IDE 行级能力：按 `indentationWidth` 绘制的缩进参考线、光标括号匹配（跳过字符串/注释、±64 KiB 窗口）、当前行 accent 边框。移除 gutter、文档头和状态栏的分隔线，改用列宽、背景层级与留白分区。TextField 测试 50/50，DevTools 聚焦第 7 行验证边框/行号/括号高亮。
- Text Editor 增加 IDE 式辅助：当前行低对比度 band、当前行号提亮、行号与文本共用 `resolvedLineHeight`；Gallery 默认使用轻量 Swift lexer 给关键字/类型/字符串/数字/注释着色，并保持 30 万字节以上压力样例关闭高亮。DevTools 聚焦第 7 行验证 band/行号/状态栏同步，TextField 测试 50/50。
- Gallery 的 “Code Editor” 更名为 **Text Editor**，明确 `TextField` 是通用多行编辑器（`codeEditing` 只是可选能力）。示例增加整合式编辑器外壳：文件名/语言 badge、Code mode 切换、Ln/Col + Spaces/Wrap + UTF-8 状态栏；plain 模式软换行并移除行号/诊断。代码行号 gutter 默认透明并增加 8pt 垂直内边距，不再出现整块灰色空槽和贴边首行。TextField/JsonField 测试 50/50，DevTools 复核 code/plain 两种状态。
- Sidebar 选择高亮改用新的 `.sidebar` source-list 角色：`fill = surfaceVariant`，hover/press 只叠中性 `stateLayer`，不再把 accent 蓝叠成淡紫色 Material 选中态。`SidebarContentTests` 断言 sidebar 与 navigation 角色颜色分离；DevTools 1000×760 hover 选中项为中性灰、整行 220pt。
- `DrawList.addLine` 加入单物理像素 alpha fringe 与圆角端帽：Checkbox 勾、Spinner 弧线、图表折线不再出现阶梯锯齿；新增 `DrawListTests.lineCoverage` 断言不透明核心、透明 fringe 和索引边界。DevTools 4× 裁图复核勾选标记边缘。
- Sidebar 行命中区与 hover/selection 背景改为整栏宽度：`destinationButton` 在行 Box 中占满主轴，不再按标题 intrinsic width 收缩；短项（Alert）与长项（Progress / Spinner）胶囊等宽。`SidebarHierarchyTests.fullWidthRows` 断言 Overview 与 Settings 行宽一致且 ≥250pt，DevTools 1000×760 hover 两项均宽 220pt。
- Alert 文本列重排：图标进入标题行并垂直居中，正文与操作通过同一 `textInset` 对齐到标题 leading edge；修复 `.padding(leading:)` 作用于 Text 时未产生缩进的问题。`ProductComponentTests.alertTextAlignment` 断言 title/message `minX` 相等，DevTools 两者均为 x=323。
- Calendar 日期格改为 iOS 圆形形态：选中日期实心 accent 圆、今天 accent 圆环，hover/focus 同样保持圆形；替换原来的小圆角方形。Calendar 键盘导航测试通过，DevTools 选中 10 月 6 日后截图确认实心圆与今天 18 日圆环。
- Alert 的默认 `.soft` 从 Material tonal 色块改为 iOS 中性状态卡：`surfaceRaised` + hairline，tone 只保留在图标；标题/正文恢复常规对比度。新增 `alert.md` 并加入组件索引，DevTools 截图复核四种 tone。
- iOS 风格收口：Sheet 默认改为距窗口 12pt、圆角 14pt 的浮动面板（新增 `SheetOptions.inset/cornerRadius`），不再贴边方形；Toast 自动位置改为所有宽度右上，圆角 14pt 并加轻阴影，compact 不再使用底部 Snackbar 形态。SheetTests/ProductComponentTests 22/22，DevTools 实测 sheet 260×736 @ (728,12)、toast 右上带阴影。
- `ScrollView` 新增 `.scrollAnchor()`：记录视口顶部完整 anchor 的相对位置与 contentSize，布局增长时按 anchor 位移修正 offset；顶部插入历史消息保持当前阅读行，普通滚动刷新基线，anchor 消失时重新选择。`ScrollOffsetBindingTests.scrollAnchor` 覆盖 prepend +120pt；Gallery ScrollView 提供 Load older，DevTools 实测 offset 0→220 且 Scrollable line 1 保持顶部。
- `ScrollView` 新增 `ScrollRequest(offset:duration:)`：按新 identity 启动带时长缓动，目标夹到当前范围，滚轮/拖动/绑定写入/新 request 取消旧动画，duration 0 与 reducedMotion 直接吸附。`ScrollOffsetBindingTests.timedScroll` 覆盖动画中途、输入取消、夹紧与 reducedMotion；Gallery ScrollView 提供 Top/Middle/End，DevTools 实测 End 后 offset 1476。
- `Sidebar` 新增项级操作：`SidebarItem.contextMenu` 支持 macOS 右键/Control-click 与 expanded 行尾 “….” 触发器，触摸/键盘可达，rail 保留右键；菜单使用不透明浮层避免穿透。`SidebarHierarchyTests` 8/8 覆盖 ellipsis、右键、42/44pt 触摸目标；Gallery Nested navigation 的 Audit log 提供 Archive/Duplicate，DevTools 实测执行后显示 Last action: Archive。
- Success / Warning / Info 按钮从 Material tonal 色块改为 iOS tinted-bordered：浅色调、同色 hairline 和 tone 文本，hover/press 只叠加大约 10–16% 色调。Gallery Button/Notification 截图复验不再出现整块 pastel 按钮。
- 视觉基线切换并参考为 iOS / macOS：规范移除 Material 3 命名、48dp 密度、FAB 计划项与 Material 参考行；组件文档的 References 收敛并参考到 Apple HIG/SwiftUI。已完成 UI 的全大写分组标题改为 title case（CommandPalette/Sidebar/SectionedList/Gallery MetricCard），CommandPalette 截图复验后保持 40pt 行高与 560pt 面板。
- 修正 CommandPalette 视觉：桌面行高 36→40、header 28→24，桌面面板 440→560，8 条命令完整显示且点击区更宽松；快捷键改为单个紧凑 shortcut chip，选中行水平内缩 8pt 且去掉边缘描边，footer 移除整块边框改为 1pt 分隔线。Modal 的 `inset` 现在作为四边实际外边距，顶部放置保留 72pt，面板四角不再被窗口/内容裁坏。
- `Sidebar` / `AdaptiveSidebar` 支持递归嵌套导航：`SidebarItem.children` + 可选 `expanded` binding；分支只切换展开，Right/Left 展开/收起并进入/返回，选中深层项只展开祖先一次、仅精确叶子高亮。`SidebarHierarchyTests` 6/6 覆盖键盘、RTL、数据移除、390/720/1280 矩阵与 AI 查询；Gallery Sidebar 页新增 Nested navigation，DevTools 实测展开 Design team、选择 Audit log。
- `CommandPalette` 新增 session 级最近使用：执行命令后记录最多 3 条，query 为空时置于 "RECENT" 分组并从原分组去重；`showsRecentCommands` 与 `recentCommandLimit` 可配置。`FeedbackComponentTests` 覆盖投影，DevTools 实测 Toggle Theme 二次打开后位于 RECENT。
- Breadcrumb / Pagination 触摸验收补齐：`TouchDensityTests` 将两者纳入 44pt 触摸族；DevTools 390 touch 预览测得链接 44×88、前后按钮 44×78、页码 44×44。adaptive-spec 对应行改为 `[已实现]`。
- `ColorField` 弹层宽度改为自适应：`min(280, max(176, viewport − 24))`，390/720 为 280、200 为 176，hex 与通道行不因窄而隐藏。`ControlDensityTests` 覆盖宽度档位；DevTools 实测 `color-picker-panel` 280×184，并补齐 `colorfield.md`。
- `Slider` 补齐刻度与 Page 键：`showsTicks` 在每个离散 step 位置绘制 1pt 刻度（最多 40 段）；PageUp/PageDown 移动 10 个 step 并夹紧。`SliderTests` 覆盖 Page 键与刻度渲染；Gallery `slider` 页的 Stepped 示例展示刻度，DevTools PageUp 将 3.0 移到 5.0。
- `RangeSlider` 补齐 P1 双 thumb 语义：两个 thumb 各有独立 Tab 停靠、`Range start`/`Range end` slider 角色与独立 value，父节点为 group；焦点/指针各自移动对应 thumb，focus ring 只画在聚焦 thumb 上。`RangeSliderTests` 5/5 覆盖指针、minSpan、键盘、双 Tab 与焦点环；DevTools 查询到每个实例的两条 slider 语义。
- `SplitButton` 补齐 P1 交互：单一 Tab 停靠进入整体，左右方向键在主按钮与箭头之间移动并同步 roving Tab stop；两区之间新增共享 1px `.border` 分隔线。`SplitButtonTests` 3/3 覆盖双区动作、禁用与 roving 焦点；DevTools 在 390/720 自适应预览确认主按钮 333/663pt、箭头 56pt。
- `NavigationStack` 补齐 P1 边界：新增 `.navigationTitle`，新顶页布局后自动聚焦 heading（无可见键盘环）；过渡 settle 前的第二次 path 变化被拒绝并写回上一次接受的栈。`NavigationStackTests` 5/5 覆盖标题焦点与去重；Gallery 标题改为 heading，DevTools 查询 `Details` 得到 `role=heading`。平台返回仍由宿主处理。
- 移除 wgpu-native、RHIWGPU、旧 WGSL 渲染路径与 Rust 构建要求；Engine、Editor、Player 和 GuavaUI 统一使用 NativeRHI。
- 增加原生场景 GPU 回归、着色器产物一致性校验与编译失败保护，修复共享 UI 绘制器的多窗口 MSAA 状态覆盖，并复用固定环境光的 CPU 烘焙结果。
- Android 显示帧时钟断言移入平台无关的 `GuavaAndroidContract` 测试；MCP stdio 协议契约成为 CI 门禁；`guava-dev` 命令标明 CI / Manual / Dev gate。
- `guava-dev` 的 DevTools 客户端从 `validate` 移到 `devtools`：`query-ui`、`input-ui`、`capture-ui`、`record-timings`、`session`。
- Toast 支持最多两个内联操作、四角定位与 `.automatic`（compact 底部、其余右上）并计入安全区；补齐 `toast.md`、单元测试与 DevTools 真实点击/截图验收。
- 诊断工具收进 `UIDiagnosticTool` 单一注册表：name/schema/即时读取标记同源，handler 使用类型化入参；DevTools 与 MCP 共用同一份定义。
- 新增 `ZStack` / `ZStackLayout`：按声明顺序层叠、测量到最大子视图、后声明优先命中、RTL 逻辑边；补齐 `zstack.md`、单元测试、Gallery 页与 DevTools 点击/截图验收。
- 新增 `View.overlay(alignment:)` / `OverlayLayout`：overlay 以 base 尺寸为准、不改变父级布局并优先命中；ZStack Gallery 卡片改用 overlay，避免并列 Text + padding 的偏移问题。
- 新增 `SearchField`：TextField chrome + 前导搜索图标 + clear，联想列表支持过滤、方向键/Return/Escape 与指针选择；补齐 `searchfield.md`、单元测试、Gallery 页与 DevTools 输入/截图验收。
- 新增 `BottomSheet`：44pt 拖拽柄、detent 展开/退档/关闭、compact 贴底与 expanded 居中退化；复用 Modal 焦点/Escape/backdrop，补齐 `bottom-sheet.md`、单元测试、Gallery 页与 DevTools 拖拽/截图验收。
- 新增 `MenuButton` 与 `Popover.triggerStyle`：常规按钮触发器 + Portal 菜单，保留 expanded 语义、Escape/外部点击关闭与菜单键盘导航；补齐 `menubutton.md`、单元测试、Gallery 页与 DevTools 打开/选择/截图验收。
- 新增 `RangeSlider`：双 thumb、就近 active thumb、`minimumSpan` 夹紧、键盘/Home/End 与组合 a11y 值；补齐 `rangeslider.md`、单元测试、Gallery 页与 DevTools 拖动/截图验收。两个 thumb 的独立 Tab/双 slider 语义仍待补。
- 新增 `SplitButton`：主按钮 + MenuButton 箭头，主/备两区独立命中与禁用同步；补齐 `splitbutton.md`、单元测试、Gallery 页与 DevTools 主/备动作验收。单一 Tab + 左右分区与共享 1px 分隔 chrome 仍待补。
- 新增 `DateRangePicker`：真实 Calendar 两击区间、端点/区间高亮、反向点击交换、触发器显示起止日期；补齐 `daterangepicker.md`、单元测试、Gallery 页与 DevTools 选择/截图验收。区间预设与最大长度由应用层负责。
- `ScrollView` 补齐触摸拖动/惯性、4pt 拖动阈值与指针捕获，以及聚焦后的 Arrow/Page/Home/End 键盘滚动；新增 `ScrollViewInputTests`，Gallery `scrollView` 页补充键盘/触摸提示，DevTools 实测 PageDown 偏移。滚动条辅助功能、锚定与带时长程序滚动仍待补。
- `CommandPalette` 结果改用 `VariableVirtualStack`：仅挂载视口 + overscan 行，键盘 highlight 通过 `scrollToIndex` 自动显露；1000 条命令挂载行 <60，行宽/选中背景铺满。补齐 `commandpalette.md`、虚拟化测试与 DevTools 搜索/执行验收。固定 440 的移动端高度与最近使用记录仍待补。
- 新增 `MultiSelectList`：稳定 ID 集合、普通点击/Shift 区间/Cmd-Ctrl 切换、Shift+Arrow、Cmd/Ctrl+A、Space 切换与 Return 激活；复用 `List` 的虚拟化/行 host/style。补齐 `MultiSelectListTests`、Gallery `multiSelectList` 页与 DevTools Shift 区间验收。区块/重排/swipe/下拉刷新仍待补。
- 新增 `SectionedList`：平面 section header/footer、跨区段键盘选择、`VirtualStack` 虚拟化与单行选中；header/footer 不进入焦点。补齐 `SectionedListTests`、Gallery `sectionedList` 页与 DevTools 行选择验收。重排/swipe/下拉刷新仍待补。
- `SectionedList` 增加 `stickyHeaders`：当前区段标题随滚动固定在视口顶部，下一标题上推并在到达顶部后接替；固定条覆盖行内容区、保留稳定滚动条槽并以 1pt 底部分隔线收边，固定副本不参与焦点、命中与语义，列表外层裁剪。`VirtualStack` 增加内部滚动 offset 观察入口，固定标题与 `scrollToIndex`/触摸行高/字号缩放共用同一几何。补齐 sticky 单元测试（含仅一份语义断言）、Gallery 三段可滚动示例、自适应预览与 DevTools 滚动条拖动/截图验收。重排/swipe/下拉刷新仍待补。
- 窄宽重排：`Stepper` 按每步 148pt 预算在宽/窄 retained 分支间切换，窄宽纵向堆叠并改用 Up/Down；`StepperOptions.minimumHorizontalStepWidth` 可提高长标题预算。`ButtonGroup` 段改为可换行且不压缩；`Vec3Field` 以 96pt 基准/88pt 最小宽换行，窄宽 X/Y 一行、Z 下一行。补齐 `NarrowReflowTests`（390/720、触摸、轴感知键盘）、三个 Gallery 页与自适应预览；DevTools 实测 390pt 三步骤为 56pt 纵向行、720pt 单行，并截图确认 ButtonGroup/Vec3 换行。原地切换同一 `Box` 方向曾把步骤压成 0pt，改用 retained 宽/窄树后修复。
- `CommandPalette` compact 自适应：`SurfaceReader` 读取表面尺寸与输入，<600pt 时使用 `viewport − 16` 宽、`min(560, viewport − 16)` 高、8pt inset 居中，触摸结果行 ≥44、header 36；桌面保持 640×440 顶部与 36/28 行高。补齐 `CommandPaletteAdaptiveTests` 与 Gallery/DevTools 390pt 实测；软键盘收缩仍由宿主 IME 处理。
- 验证并记录 Select 弹层窄宽行为：复用 Menu 的行高与 Portal 夹紧，390pt 下触发器 286pt、弹层 346pt（x=32，右边界 378），指针行高 32、触摸 ≥44；补充 `adaptive-spec.md` / `menu.md` 验收，无需新增兼容层。
- 焦点环统一为仅键盘焦点可见：Toggle 的开关/复选框自绘路径与 Slider/RangeSlider 的 style 快照改用 `focused && isFocusVisible`；`FocusRingTests` 渲染 DrawList 验证指针无 `focusRing` 顶点、键盘有，DevTools 720pt 点击 Toggle 后数值翻转但截图与点击前一致（无环）。
- 新增 `ReorderableList`：44pt 拖拽 handle、2pt 放置线、Escape 取消、一次 `onMove`；聚焦 handle 后 Up/Down 与辅助功能 increment/decrement 移动同一行，触摸行高/handle ≥44。补齐 `ReorderableListTests`、Gallery `reorderableList` 页与自适应预览；当前为非虚拟列表，视口边缘自动滚动仍待补。
- 新增 `NavigationStack`：caller-owned `[Route]` 栈、root/path 页面 retained 挂载、push/pop move+opacity、深链首帧恢复与容器尺寸填充；隐藏页不参与输入/焦点/语义但保留草稿。补齐 `NavigationStackTests`、Gallery `navigationStack` 页与自适应预览；平台返回手势、新页标题焦点与重复入栈去重仍待补。
- 新增 `SwipeList`：仅触摸面左滑露出最多两个 74pt 操作，行尾 44pt Actions 按钮与右键上下文菜单提供非滑动入口；行高触摸 ≥44，纵向手势交给 ScrollView。`ScrollView` 触摸拖动改为轴感知阈值。补齐 `SwipeListTests`、Gallery `swipeList` 页与自适应预览；当前非虚拟化，RTL 仍待补。
- 新增 `List`/`VirtualStack` 下拉刷新：`RefreshOptions` 以触摸 overscroll 阈值触发一次、`isRefreshing` 保持指示器并预留 36pt inset，Cmd+R/Ctrl+R 为键盘入口，`Spinner` 在 reducedMotion 下冻结。补齐 `RefreshTests`、Gallery `refreshableList` 页与自适应预览；异步生命周期由调用方持有。
- 既有控件标题统一单行省略：`Button`/`Link` 默认以完整标题作为 tooltip，`MenuButton` 可显式传 `tooltip:`，`DatePicker` 触发标题附加完整 tooltip；`Select`/`Combobox` 沿用 trigger description。补齐 `TruncationTests`、Gallery Button “Long labels” 分区与 DevTools 悬停全文验收。
- 新增 viewport 高度类与方向：`UIEnvironment.Viewport.heightClass`/`orientation`（600/1000 阈值，方形归 landscape）与 `HeightClassReader`/`OrientationReader`。补齐 `ViewportTraitsTests`、Gallery `viewportTraits` 页与 DevTools 720/390/1200 实测；`ViewThatFits` 内在拟合仍待补。
- 辅助功能补齐：`ScrollView` 暴露 `.scrollArea` 角色、可命名 label、实时百分比 value、键盘 help 与按页 increment/decrement；`Select`/`Combobox` 触发器改为 `.comboBox` 角色并保留当前值/展开态。补齐 `AccessibilitySemanticsTests` 与 DevTools scrollView/select 查询；`described-by` 与可聚焦滚动条 thumb 仍待补。
- 浮层自适应验收完成：`BottomSheet` 在 390×800 为 390×280 贴底、1280×840 为 560×280 居中；`MenuHierarchyTests.touchSubmenu` 覆盖触摸面点击父行展开子菜单并执行叶子。补齐菜单触摸文档与 DevTools 截图。
- 新增通用拖放协议：`DragScope` 持有类型化会话，`Draggable` 在 6pt 后开始拖动并投射 Portal 预览，`DropTarget` 只接受匹配 payload 并回调目标高亮；外部释放与类型不匹配不 drop。补齐 `DragAndDropTests`、Gallery `dragAndDrop` 页与 DevTools 720×820 实测（Camera → Lane A 得到 `A: Camera · B: empty`）。无自动滚动与键盘重排，集合重排仍用 `ReorderableList`。
- `ViewThatFits` 新增 `fitting: .intrinsic`：在 unspecified 宽高下测量 wide 分支，自然宽高都放得下才选 wide，否则选 compact；两套分支保留节点与状态，隐藏分支停止绘制/输入/语义。补齐 intrinsic 单元测试、Gallery `viewThatFits` 页与 DevTools 520/180pt 实测。
- 辅助功能新增 `describedBy`：`AccessibilitySemantics.describedBy` + `accessibilityDescribedBy(_:)`，由 `AccessibilityTree` 与 DevTools 查询把引用目标的 label/value 追加到 help；缺失目标不改写。补齐单元测试、Gallery Button “Described by” 示例与 DevTools 实测。
- 新增独立 `Scrollbar`：可聚焦 slider thumb、拖动/方向键/Page/Home/End、辅助功能 increment/decrement 与 `setValue`、focus ring，并与 ScrollView offset 绑定。补齐 `ScrollbarTests`、Gallery `scrollbar` 页与 DevTools 拖动/键盘实测；ScrollView 内建 chrome 不自动叠加该 companion。
- 自适应预览覆盖从 35 页扩至 92 页：新增全部剩余页面的三档预览与逐页高度，包括编辑器、覆盖层、工作区、媒体与通知页；DevTools 验证 scrollbar/timeline/tree/colorField/dialog 等页面的三档容器。

## 0.0.9 — 2026-10-06

- 编辑器加入启动页项目管理、Crystal Rush 示例模板、场景和脚本并排工作区、统一深浅色主题及性能分析视图。
- Swift 脚本支持语法高亮、LSP 提示、编译诊断、文本撤销重做，以及随游戏导出后由 Player 直接运行。
- 渲染加入正交视图、地面网格与坐标轴、精确网格拾取、透明和双面材质、大场景剔除与实例化，以及真实 GPU 回归测试。
- 完善物理、粒子、AI/MCP 项目工具、脚本生命周期和 GuavaUI 交互。
- 本地与 CI 工具链统一使用 Swift 6.4.0、Rust 1.99.0、CMake 4.4.4、Ninja 1.13.2、Python 3.14.8；官网使用 Node.js 26.10.0 和 npm 12.2.0。
- 原生依赖更新为 SDL 3.4.18、Imath 3.2.3、OpenEXR 3.5.2、Jolt 5.6.0、FreeType 2.14.3、HarfBuzz 14.5.1、wgpu-native 29.0.1.1、Wasmtime 49.0.2、plutovg 1.3.3；swift-log 更新为 1.15.1。
- Lunasvg 3.5.0、libwebp 1.6.0、Yoga 3.2.1 和 stb_image 2.30 已是各自最新稳定版。
- 官网依赖升级到最新兼容版本。TypeScript 使用 6.0.3（typescript-eslint 8.71.1 要求 <6.1.0）；Unhead 使用 2.1.17、Beasties 使用 0.3.5（vite-ssg 28.3.0 的兼容版本）。
- 适配 OpenEXR 3.5 的静态打包与 Jolt 5.6 / Wasmtime 49 的桥接 API，并修复原生强制重建缓存失效。
- 修复 Linux 物理基准编译、静态库链接和重复的 CGRect 兼容扩展；修复 Windows 动态库加载和内存统计；完善 macOS SDK 与跨平台 C 模块映射发现。
- 修复无界面编辑器计时器的主 actor 隔离、跨平台 JSON 数字与布尔值区分、脚本编译取消超时、CI 并发测试线程调度，以及文档元数据缺失。
- 适配 Swift 6.4 带平台后缀的构建目录及 `.build/debug` 符号链接，修复 Windows LSP 可执行文件发现和跨平台脚本测试；Windows JSON 校验不再依赖 SDK 未公开的 CoreFoundation 模块。
- 适配新版 WinSDK 的布尔返回值，并从 Swift 独立运行时目录收集 Windows 发布包所需 DLL。
- 修复 Windows 短路径、路径大小写及尾部分隔符造成的脚本目录误判和音频导出遗漏；可执行文件查找验证候选文件确实存在，资产重新导入使用 Windows 原子替换 API。
- 修复 DevTools WebSocket 测试提前断开连接的竞争，并使用可控帧时钟验证事件驱动模式的时间步长。
- 规避 Windows Foundation 跳过目录后停止遍历其他子目录的问题，修复资产与音频扫描；脚本更新按实际文件位置匹配，保留稳定标识与未保存文本保护。
- 插件超时先终止宿主再关闭管道；完善渲染回调同步、UI 测试共享字体和动画调度器隔离，以及场景导出时间戳的测试处理。
- 编辑器项目生命周期测试覆盖三平台；完整 Swift ScriptBehavior 编译和导出运行沿用 macOS/Linux 支持范围，Windows 保留预置场景播放。
- 修复脚本库卸载后 Swift 运行时访问失效元数据的崩溃。热重载释放旧脚本实例，但已加载的 Swift 代码保留到进程退出。
- CI 更新到新版 GitHub Actions 和 Xcode 27.0 / Visual Studio 2026 runner，macOS 使用 `xcode-27` 镜像，避免回退到 Xcode 26.6。发布包通过安装与启动验证后，才公开 Release 草稿。
- macOS CI 使用 Xcode 27 自带的 Swift 6.4，避免独立开源工具链缺失 Apple 平台导致 Swift 构建失败；Linux 和 Windows 使用独立 Swift 6.4 工具链。

发布产物：macOS arm64、Windows x86_64、Linux x86_64 编辑器包，包含 Player 和 MCP 工具。
