# Diffuse：Swift → Rust 迁移

本文是 Diffuse 迁移的唯一操作手册，读者是执行迁移的 AI agent。动手前通读一遍；每个批次结束时更新第 9、10 节。

- 起点：2026-10-31，1,337 个 Swift 文件，208,269 行，规划为 34 个 crate 加 `xtask`；各 crate 的文件数与行数用 `python3 Tools/Migration/inventory.py --status` 查看。
- 逐文件清单：[Docs/rust-migration-files.json](Docs/rust-migration-files.json)（由 `Tools/Migration/inventory.py` 生成，**目标路径以它为准**）与 [Docs/rust-migration-files.md](Docs/rust-migration-files.md)。
- 参考：Natsel 的迁移已完成，见 `../Natsel/MIGRATION.md`；本文的批次规模、并发上限和“不许桩代码”规则直接沿用它的教训。

## 1. 依赖现状（先读）

| 依赖 | 状态 | Diffuse 如何使用 |
|---|---|---|
| **Cove**（`../Cove`，`CoveUI` 是指向它的符号链接） | 生产源码已全部写成 Rust，**测试迁移与完整验证仍在另一个 agent 手里进行**；Cove 的 Swift 树之后会被删除，目录结构也会调整为 Cargo 惯例（`rust/` → `src/`） | 只依赖 **crate 名与公开路径**，绝不依赖 Cove 内部文件路径。开发期用 path 依赖，发布前改为 git tag |
| **Natsel**（`../Natsel`） | 已完成 Rust 迁移，530 个测试通过，与 Swift 版逐帧哈希一致 | crate `natsel`。公开 API 保持 Swift 形状，只做 camelCase → snake_case |
| Cove Swift SDK 0.2.12（`~/.cove/versions/0.2.12`） | 已安装，Diffuse 的 Swift 构建解析到它，而不是 `../Cove` | 只用于第 7.1 节采集 Swift 基线；Cove 删除 Swift 不影响它 |

规则：

- **不得修改 `../Cove` 或 `../Natsel`。** 缺什么、坏什么，写进 [.migration/cove-gaps.md](.migration/cove-gaps.md)（格式见该文件），然后按计划的 API 名继续写，在批次报告中标出。
- 2026-11-04 用户明确授权补齐上游 Natsel API，本批次可修改 `../Natsel` 的 G8 相关实现；Cove 仍只读。
- Cove 的 Rust 代码未经完整验证。Diffuse 测试失败时，先判断根因在 Diffuse 还是 Cove；属于 Cove 的写进 gaps，不要在 Diffuse 里绕过。

## 2. 目标结构

符合 Cargo 惯例的单一 workspace：

```
Cargo.toml                 # [workspace]，members = ["crates/*", "xtask"]
rust-toolchain.toml        # 与 Cove 完全一致：channel = "1.99.1"
.cargo/config.toml         # [alias] xtask = "run --quiet --package xtask --"
crates/<crate>/
  Cargo.toml
  build.rs                 # 仅当 crate 有 C/C++ 原生代码
  native/                  # C/C++ 源码（原 Sources/Bridge/*、CFFmpegBridge）
  src/lib.rs | src/main.rs
  src/tests/<suite>/       # 使用 @testable 的 Swift 测试套件（crate 内 #[cfg(test)]）
  tests/<suite>/main.rs    # 不用 @testable 的套件：每个 Swift 测试 target 一个测试二进制
  benches/ examples/ src/bin/
xtask/                     # 原 Tools/Developer（cove-dev）+ 原 cove CLI 中的 Diffuse 命令
Tools/Migration/           # 迁移清单脚本
```

workspace 公共设置：`edition = "2024"`、`rust-version = "1.90"`（与 Cove 相同）、`license = "Apache-2.0"`；`[workspace.lints]` 照抄 Cove（`unsafe_op_in_unsafe_fn = "deny"`、`clippy::undocumented_unsafe_blocks = "deny"`）。

### 2.1 crate 映射

依赖按 Swift `Package.swift` 的 target 依赖一一照搬，不新增、不删减；表中只列 Cove/Natsel 一侧。

| Swift target | crate | 额外依赖（Cove / Natsel / 原生） |
|---|---|---|
| SIMDCompat + EngineMath | `diffuse-math` | — |
| EngineKernel | `diffuse-kernel` | cove-platform |
| ObservationBus | `diffuse-observation` | — |
| SequenceRuntime | `diffuse-sequence` | — |
| ColorPipeline | `diffuse-color` | — |
| CardBattleRuntime | `diffuse-card-battle` | — |
| CapabilityRuntime | `diffuse-capability` | cove-agent（`pub use cove_agent as agent;`，等同 Swift 的 `@_exported import CoveUIAgentCore`） |
| StudioDocuments | `diffuse-documents` | — |
| MediaRuntime + CFFmpegBridge | `diffuse-media` | 原生：FFmpeg（C） |
| EXRIO + COpenEXRBridge | `diffuse-exr` | 原生：OpenEXR/Imath 子模块（C++17） |
| SceneRuntime | `diffuse-scene` | natsel |
| AssetPipeline | `diffuse-assets` | cove-system、cove-imaging、cove-logging |
| CinematicRenderer | `diffuse-cinematic` | — |
| AudioRuntime | `diffuse-audio` | cove-logging、cove-shell（SDL3 音频） |
| PluginRuntime | `diffuse-plugin` | cove-system、cove-logging；资源 `Resources/` |
| LanguageServerRuntime | `diffuse-lsp` | cove-system、cove-logging |
| （新建） | `diffuse-script-api` | 无依赖，std-only；用户脚本唯一依赖的 crate，见 §4 D1 |
| ScriptRuntime | `diffuse-script` | cove-system、diffuse-script-api；脚本编译与加载按 D1 改写 |
| RenderBackend | `diffuse-render` | cove-graphics、cove-logging；资源：着色器、`.obj`、`.gltf` |
| IntentRuntime | `diffuse-intent` | — |
| NativeRendererValidation + NativeRHIPassProbe + RenderBackendBenchmarks | `diffuse-render-validation` | cove-graphics |
| EngineCore + CEngineBridge + tree-sitter | `diffuse-engine` | cove-logging、cove-graphics；原生：`engine_bridge.c`、tree-sitter + tree-sitter-rust（替换 tree-sitter-swift） |
| ContextMemory | `diffuse-context-memory` | cove-system |
| PerceptionRuntime | `diffuse-perception` | cove-system；macOS 用 Vision/CoreImage（Objective-C/C 桥接，同 Cove 的 `apple.m` 做法） |
| SemanticPipeline | `diffuse-semantic` | cove-system |
| AIRuntime | `diffuse-ai` | cove-agent、cove-http（G4） |
| DiffusePluginHost | `diffuse-plugin-host`（bin） | cove-system、cove-logging |
| DiffuseMCP | `diffuse-mcp`（bin） | cove-agent（`McpServer::with_provider` + `serve_stdio`），到编辑器的转发用 `std::net::TcpStream` |
| EditorCore + LanguageServerFixture | `diffuse-editor-core` | cove-system、cove-logging、cove-runtime、cove-ui-compose、cove-graphics、cove-agent（MCP 桥接的本地 TCP 服务）、cove-http |
| GameRuntime | `diffuse-game-runtime` | cove-system、cove-logging、cove-graphics |
| CoveProjectExport | `diffuse-export`（bin） | cove-logging |
| EditorUI | `diffuse-editor-ui` | cove-ui（含 hosts、addons::workspace、terminal）、cove-ui-compose、cove-runtime、cove-graphics |
| EditorApp | `diffuse-editor`（bin `diffuse`） | 用 `cove_ui::application!` 声明根视图 |
| CovePlayer | `diffuse-player`（bin） | cove-ui、cove-ui-compose、cove-runtime、cove-graphics |
| Platforms/Android CoveAndroidApp | `diffuse-android`（cdylib） | cove-hosts；**原 `CAndroidHost/*.c` 删除**，JNI 已在 `cove_hosts::android::jni` |
| Tools/Developer（cove-dev） | `xtask` | cove-system、cove-logging、cove-package；`ToolSupport` 见 G1 |

保持不变、无需迁移：`PluginSDK/`（TypeScript/Bun）、内置插件里的 `plugin.js`、`Website/`、着色器 `.slang`、Java 源码（改为复用 Cove 的 `Hosts/Android`，见 2.3）。

### 2.2 workspace 依赖写法

```toml
[workspace.dependencies]
cove-ui = { path = "../Cove" }
cove-core = { path = "../Cove/Core" }
# …每个用到的 Cove crate 一行；路径以 Cove 当时的 Cargo.toml 为准，Cove 重构目录后只改这里
natsel = { path = "../Natsel" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
```

第三方 crate 只允许 Cove 或 Natsel 已经在用的（serde、serde_json、thiserror、libc、cc、tempfile、unicode-segmentation 等）。确需新依赖时，写进第 10 节并说明理由，由用户确认；不要为了省事引入 tokio、glam、anyhow 之类。

release profile：`overflow-checks = true`，与 Swift 溢出即陷入的语义一致；`[profile.release.package.natsel] overflow-checks = false` 保持 Natsel 自己的设置。

### 2.3 原生代码与平台工程

- C/C++ 桥接保持 C/C++（AGENTS.md：性能关键路径用 C），移到 `crates/<crate>/native/`，由 `build.rs` 用 `cc` 编译，CMake 项目照 Cove `Text/rust/build.rs` 的写法调用 cmake。
- FFmpeg、OpenEXR/OCIO 的获取原来在 `cove studio native-bootstrap`（已随 Cove CLI 删除）和 `Tools/Developer/Sources/Build/NativeBootstrap`。迁移后由 `cargo xtask native-bootstrap` 把产物放进 `vendor/`；`build.rs` 从 `DIFFUSE_NATIVE_ROOT`（默认 `vendor/`）链接，缺失时报明确错误、不静默跳过。FFmpeg 源码镜像沿用最近几次提交里的已验证镜像逻辑。
- Android：删除 `Platforms/Android` 里的 `CAndroidHost`、Java 副本与 `Runtime/build.gradle.kts`，改用 Cove 的 `Templates/app/Platforms/Android` 结构（Gradle 引用 Cove 的 `Hosts/Android/Runtime`），由 `cargo xtask package android` 出 APK。Diffuse 玩家内容走 `SceneLaunchMode::Game`，Cove 目前只开放 `Application` 模式的内容注册，见 G2。
- 平台全覆盖：每个 `#if os(...)` / `#if canImport(...)` 分支都翻译成对应的 `#[cfg(...)]`，macOS、iOS、Windows、Linux、Android 一个都不能少。Swift 原本缺失的平台实现（例如非 Apple 平台的感知 worker）照原样保留“不可用”行为，并写进第 10 节报告，不要伪造实现。

## 3. Cove / Natsel API 映射

| Swift 模块 | Rust crate（路径） |
|---|---|
| CoveUI | `cove-ui`（伞形 crate，`cove_ui::{hosts, compose, composition, core, …}`） |
| CoveUIRuntime | `cove-runtime` |
| CoveUICompose | `cove-ui-compose` |
| CoveUIComposeCore | `cove-composition` |
| CoveUICore、CoveUIScene | `cove-core`（场景在 `cove_core::scene`） |
| NativeRHI、CoveUIGraphics | `cove-graphics`（`cove_graphics::rhi`、`cove_graphics::ui`） |
| CoveUIText | `cove-text` |
| CoveUIImaging、CImageDecodeBridge | `cove-imaging` |
| PlatformShell、CoveUIShell | `cove-shell` |
| CovePlatformCore | `cove-platform` |
| CoveFileSystem、CoveProcess | `cove-system` |
| CoveLogging、CCoveLog | `cove-logging` |
| CoveUIWorkspace | `cove-ui-addons`（`workspace`） |
| CoveUITerminal | `cove-terminal` |
| CoveUIAgentCore、CoveUIAgent（传输）、CoveUIInspection 的工具注册表与 skill | `cove-agent`（`../Cove/Agent`，G6 已关闭） |
| CoveUIDevTools、CoveUIInspection 的 UI 处理器 | `cove-devtools`（`inspection`、`server`） |
| URLSession（HTTP 客户端） | `cove-http`（`../Cove/Http`，G4 已关闭） |
| CoveUIDevToolsProtocol | `cove-devtools-protocol` |
| CoveAndroidContract、CoveUIAndroid | `cove-hosts`（`cove_hosts::android`） |
| ToolSupport | Cove 已删除，见 G1 |
| Natsel | `natsel` |

查找某个 Cove Swift API 的 Rust 实现：

1. 查 [.migration/cove-api-map.json](.migration/cove-api-map.json)：Cove 每个 Swift 文件 → Rust 文件，快照于 Cove `aa23e432`。
2. 路径不存在了（Cove 已重构），就在 `../Cove` 里按类型名搜索 `struct|enum|trait|fn <Name>`。
3. 改名规则与 Natsel 相同：类型名保持 PascalCase，成员 snake_case，`init` → `new`。Cove 少数类型去掉了 `UI` 前缀（`UIRect` → `Rect`、`UIVertex` → `Vertex`），清单里有记录。
4. 确实没有 → 写 gap，不要在 Diffuse 里重新实现一份 Cove 的功能。

## 4. 已定决策

### D1：用户游戏脚本改为 Rust（2026-10-31 定）

用户脚本是 Rust cdylib，引擎通过 C ABI 调用；编辑器用 `cargo` 构建、rust-analyzer 提供语言服务、tree-sitter-rust 做高亮与结构分析。

**为什么不是“沿用现有 C ABI”这么简单。** Swift 版的 C 部分只有 9 个函数（`cove_delta_time`、`cove_input_*`、`cove_character_*`、`cove_submit_character_command`）。脚本其余能力是直接 `import EngineKernel, SceneRuntime, ScriptRuntime`，通过编辑器 `-export_dynamic` 导出的 Swift 符号调用 `ScriptContext`；`coveCreateScript` 返回的是 Swift 对象。Rust 没有稳定 ABI，脚本 cdylib 不能共享引擎的 Rust 类型，所以 **脚本能碰到的全部能力都要进入 C ABI**。

**`diffuse-script-api`（新 crate，std-only，无引擎依赖，单独版本号）**

- `#[repr(C)] pub struct HostApi { abi_version: u32, … }`：引擎在创建脚本时传入的函数表。条目覆盖 `ScriptContext` 的全部公开成员（Swift 端 61 个 func/var）以及原有 9 个 `cove_*` 函数，语义逐个保持。按 CrystalRush 与模板的实际用法，至少包括：`delta_time`、输入（`axis`/`held`/`just_pressed`/`just_released`）、实体（`entity`、`create_entity`、`destroy_entity`、`set_parent`）、变换（`local_transform`/`set_local_transform`，`#[repr(C)]` 的 `Transform3`）、组件（`component`/`set_component`）、参数（`float_parameter`/`double_parameter`/`string_parameter`…）、`set_resource`、`report_state`、`draw_ui`、角色控制器。
- 组件以 **组件类型名 + JSON 字节** 过 ABI，JSON 格式就是组件注册表的落盘格式（§5.4），所以脚本与场景文件共用同一套编码；高频的变换、输入、时间走类型化的 `#[repr(C)]` 参数，不走 JSON。
- 字符串与字节一律 `(ptr, len)`，返回值由宿主分配、由 `HostApi.free` 释放；所有 `#[repr(C)]` 类型的布局有编译期断言。
- 安全封装：`ScriptContext`（包着 `*const HostApi` 和不透明句柄）、`trait ScriptBehavior { fn on_start / on_pre_physics / on_update / on_destroy }`（与 Swift `ScriptBehavior` 一一对应，默认空实现与 Swift 扩展一致）、`ScriptDefinition` / `ScriptProperty` / `ScriptPropertyOption` 构建器（对应 `ScriptAuthoring`）。
- 导出宏 `diffuse_scripts!(GameScript, OtherScript)` 生成：`diffuse_script_abi_version() -> u32`、`diffuse_script_catalog(host)`（JSON：名字 + `ScriptDefinition`；传宿主表用于分配目录缓冲区）、`diffuse_script_create(name, host) -> *mut c_void`、四个生命周期入口、`diffuse_script_destroy`。每个入口用 `catch_unwind` 包住，panic 转成脚本错误上报并停用该脚本实例，绝不跨 FFI 展开。
- ABI 版本：宿主只加载 `abi_version` 相同的库，不同时给出明确错误。

**引擎与编辑器侧（标 `"d1": "rewrite"` 的 58 个文件，见清单）**

- `diffuse-script`：`DynamicScript/` 改写为 `script_compiler.rs`（调用 `cargo build --release --message-format=json`，`CARGO_TARGET_DIR` 放在项目缓存目录，从 JSON 消息里取产物路径与诊断，保留 Swift 版的取消令牌与超时语义）、`script_loader.rs`（`dlopen`/`LoadLibraryW`、校验 ABI 版本、`HostApi` 实现）、`ScriptCBridge*` → `HostApi` 的条目实现。
- `diffuse-editor-core`：`Scripting/SourceKitLSP/**` → `scripting/rust_analyzer/**`，通用 LSP 交互逻辑照译，sourcekit 专有的部分（可执行文件定位、能力协商、`InheritanceClause` 对 `ScriptBehavior` 继承子句的识别）改为 rust-analyzer 与 `impl ScriptBehavior for X` 的识别；`Scripting/Toolchain/**` 改为定位与校验 rustup/cargo（安装引导指向 rustup）；`Dynamic/` 与 `Static/` 中调用 swiftc 的部分改为 cargo。用户脚本工程是项目里的 `Scripts/` cdylib crate，依赖 `diffuse-script-api`，粒度沿用 `ProjectCompiledScripts` 的现有划分。
- 语法：`Engine/third-party/tree-sitter-swift` 换成固定版本的 tree-sitter-rust（同样以子目录 vendored，只编译 `parser.c`/`scanner.c`）；`TreeSitterBridge`、`TreeSitterHighlighter` 按 Rust 语法改写，测试用例改成 Rust 源码。
- 插件：内置 `SwiftSupport.coveplugin` 换成 `RustSupport.coveplugin`（rust-analyzer 进程，cargo build/test/run，权限与环境变量白名单按 Rust 工具链重写）。编辑器对 Swift **文档**的通用编辑支持（`panels/documents/swift.rs`、SwiftPM 任务）是面向用户项目的功能，不属于脚本管线，照常翻译。
- 内容：模板 `crystal-rush.swift.txt` → `crystal-rush.rs.txt`，`crystal-rush.script-assets.json` 中的脚本路径同步；`examples/CrystalRush/Scripts/` 改为 Rust crate（`src/lib.rs`），玩法、参数与默认值逐项保持，`README.md` 改写。
- 标 `"d1": "adjust"` 的 12 个文件只是提到 Swift 工具链，照常翻译并替换这些引用。
- 改写的测试保留原测试的意图与断言强度，只把被测输入换成 Rust 源码与 cargo 输出。

### D2：HTTPS 用 OpenSSL C 绑定（2026-10-31 定）

URLSession 的调用点（AIRuntime `Session.swift`、PluginRuntime `Network/Transfers.swift`、工具链下载、Tools/Developer 的验证工具）改用 Cove 的通用 HTTP 客户端 `cove-http`。它由 Cove 新建（G4）：Apple 用 Foundation，Windows 用 WinHTTP，**Linux 与 Android 用 OpenSSL**，TLS 部分是 C（AGENTS.md：性能与平台关键路径用 C）。Diffuse 不自带 HTTP 栈；API 见 `.migration/cove-gaps.md` G4。

### MCP 与 agent 层（2026-10-31 定）

Swift 版中 Diffuse 已经复用 Cove 的公共层：`CapabilityRuntime` 以 `@_exported import CoveUIAgentCore` 重新导出工具 schema，`DiffuseMCP` 就是 Cove 的 `MCPServer` 加一个到编辑器的 TCP 转发，编辑器侧的 MCP 桥接用 Cove 的本地传输。迁移后保持这一边界：

- Cove 把 agent 层抽成独立的、不依赖 UI 栈的 `cove-agent`（G6），并恢复 Swift 版的动态工具列表（`listChanged`）与可跨线程的执行器。
- Diffuse 里 **不写任何 JSON-RPC、MCP 协议或 JSON Schema 校验代码**：`diffuse-capability` 重新导出 `cove_agent`；`diffuse-mcp` = `McpServer::with_provider` + `serve_stdio` + TCP 转发；`diffuse-editor-core` 的 `MCPIntegration` 用 `cove_agent` 的本地服务；`diffuse-ai` 的工具定义与 provider 格式用 `cove_agent` 根下的 `AgentTool::provider_definition`、`SessionApiFormat`。
- Diffuse 自己的工具（项目工具、能力检索/提交/调用、插件重载）只定义 `AgentTool` 与执行逻辑。

## 5. 翻译规范

### 5.1 文件与模块

- 目标路径一律取自清单的 `rust` 字段，不要自己起名。一个 Swift 文件对应一个 Rust 文件；`extension Type` 写成同一 Rust 文件里的 `impl` 块，不跨文件合并。
- 每个目录一个 `mod.rs`，按 Swift 文件顺序声明子模块，`lib.rs` 做 `pub use`。`Foo.swift` 与 `Foo/` 并存时，清单已把它规划为 `foo/mod.rs`。
- 文件名是 Rust 关键字时清单加 `_` 后缀（`type_.rs`）。

### 5.2 命名与类型

- 函数、变量、模块用 snake_case，类型保持 Swift 的 PascalCase；`init` → `new`（多个 init 用描述性名字：`from_json`、`with_capacity`）。
- `struct` → `#[derive(Clone, Debug, PartialEq)] pub struct`，字段顺序不变。`class` → 由所有者持有的 struct；只有 Swift 依赖共享可变引用时才用 `Rc<RefCell<_>>`（单线程）或 `Arc<Mutex<_>>`（跨线程），并在类型上用一行注释说明原因。
- `protocol` → trait；`Sendable` 去掉，由 Rust 的 Send/Sync 推导；`some P` → 泛型，`any P` → `Box<dyn P>` / `Arc<dyn P>`。
- `T?` → `Option<T>`；`throws` → `Result<T, E>`，每个 crate 一个 `thiserror` 错误枚举，case 与 Swift 的 Error 一一对应；不要 `unwrap()` 引擎路径，Swift 的 `try!`、`!` 解包才对应 `expect("原因")`。
- `inout` → `&mut`。值语义（Swift Array/Dictionary 的写时复制）在 Rust 需要显式 `clone()`；不要让两个所有者共享同一个 `Vec`。
- Swift `Dictionary` 迭代顺序本身是随机的：Swift 代码先排序再用的，Rust 同样排序；输出顺序进入文件或哈希的，用 `BTreeMap`。
- 字符串：Swift `count`、`Index`、`Character` 是字形簇语义，Rust `len()` 是字节数。凡是 Swift 用到计数、下标、截断的地方，用 `unicode-segmentation` 保持字形簇语义。
- 整数：Swift `&+`、`&*` → `wrapping_*`；普通算术溢出在 Swift 里会陷入，release 已开启 `overflow-checks`，不要改成 `wrapping`。

### 5.3 SIMD 与 GPU 布局（硬性要求）

- `SIMDCompat` 与 `simd` 在 `diffuse-math` 里用自定义 `#[repr(C)]` 类型实现，**大小与对齐必须等于 [.migration/simd-layout.json](.migration/simd-layout.json) 里实测的 Swift 值**。例如 `SIMD3<Float>` 是 16 字节、16 对齐（不是 12），`SIMD3<Double>` 是 32 字节、16 对齐，`simd_float3x3` 是 48 字节。用 `#[repr(C, align(16))]` 加显式填充字段。
- `diffuse-math` 必须带编译期断言：`const _: () = assert!(size_of::<Float3>() == 16 && align_of::<Float3>() == 16);`，覆盖清单里的每个类型。
- 29 个文件用到 `MemoryLayout<…>`（光照 uniform、可变形网格顶点流、阴影 pass、GLTF 导入、媒体解码、SDL 音频等），全部改成 `size_of`/`align_of`，并保证与着色器（`.slang`）里的结构一致。
- 浮点运算保持 Swift 的运算顺序与结合方式，不要合并或重排表达式（场景模拟依赖 Natsel 的确定性）。

### 5.4 持久化格式（硬性要求）

项目、场景、组件注册表、插件清单都是 Swift `Codable` 写出的 JSON（168 个文件用到 Codable）。用户的现有文件必须能原样读入，写出的格式要与 Swift 一致：

- 键名逐个对齐：`#[serde(rename_all = "camelCase")]`，自定义 `CodingKeys` 逐个 `#[serde(rename = "…")]`。
- `decodeIfPresent` 加默认值 → `#[serde(default = "…")]`，默认值与 Swift 完全相同；自定义 `init(from:)` 的兼容逻辑（旧版本字段、版本号分支）逐行翻译成手写的 `Deserialize`。
- 枚举：Swift 合成的带关联值枚举编码为 `{"caseName": {"_0": …}}` 或 `{"caseName": {"label": …}}`，无关联值的编码为字符串，`RawRepresentable` 编码为原始值。逐个对照，必要时手写 serde 实现。
- `Date` 默认编码为 2001-01-01 起的秒数（Double），`UUID` 为大写带连字符字符串，`URL` 为绝对字符串，`Data` 为 base64。
- `JSONEncoder` 的 `outputFormatting`（`.prettyPrinted`、`.sortedKeys`、`.withoutEscapingSlashes`）决定落盘字节，用 serde_json 的格式化器复现（Swift 的 pretty 输出是两空格缩进，键与值之间是 `" : "`，空数组/空对象写成中间带一个空行的 `[\n\n  ]`，见 `component-registry-v3.json`），需要时写自定义 `Formatter`。
- 每种落盘格式都要有往返测试：用 Swift 写出的真实文件（`Engine/Tests/SceneRuntimeTests/Fixtures/component-registry-v3.json` 以及第 7.1 节采集的黄金文件）解码再编码，与原字节逐字节比较。

### 5.5 并发与系统

- 不引入异步运行时。`actor`（18 个文件）→ 拥有状态的 struct 放在 `Mutex` 后，或者一个专用线程加 `std::sync::mpsc` 通道；`async` 函数（133 个文件）→ 同步阻塞函数，或在线程上运行并通过通道返回；`Task {}` → `std::thread::spawn`，按 Swift 语义保留取消（用 `AtomicBool` 令牌）。
- `@MainActor` 的 UI 状态只在 Cove 运行时的主线程访问，照 Cove `Rc<RefCell>` 的做法。
- `NSLock`/`Mutex`（71 个文件）→ `std::sync::Mutex`；`DispatchQueue` → 线程或 Cove 已有的调度。
- `Process()` → `cove_system` 的进程 API；`FileManager` → `cove_system` 文件 API 或 `std::fs`；日志一律走 `cove_logging`，不要 `println!`。
- `#if DEBUG` → `#[cfg(debug_assertions)]`；`precondition`/`assert` → `assert!`/`debug_assert!`，保持同样的触发条件。

### 5.6 测试

- 每个 Swift 测试 target 是一个套件。清单规划的位置：用了 `@testable import` 的套件放 `src/tests/<suite>/`（`lib.rs` 加 `#[cfg(test)] mod tests;`），其余放 `tests/<suite>/main.rs`，套件内一个 Swift 文件对应一个子模块。
- Swift Testing / XCTest → 内置测试框架：`@Test func f()` → `#[test] fn f()`，显示名写在上一行注释里；`#expect(a == b)` → `assert_eq!`；`#require` → `expect`；参数化测试展开成循环，失败信息里带上参数。
- 容差、夹具、断言一个不少。不许为了通过而放宽断言或删用例；语义确实变了，就保留断言、标 `#[ignore = "原因"]`，并写进第 10 节。
- 需要 GPU 的测试（NativeRendererTests、EngineCoreTests 里的回读）在无设备时按 Swift 的跳过条件跳过，不要改成永远跳过。

### 5.7 禁止

- `todo!()`、`unimplemented!()`、空函数体、“简化版”实现、`#[allow(dead_code)]` 掩盖未接线的代码。`inventory.py --check` 会扫描前两项。
- 修改 `../Cove`、`../Natsel`。
- 在 Diffuse 里实现 JSON-RPC/MCP 协议、JSON Schema 校验或 HTTP/TLS 栈（分别属于 `cove-agent`、`cove-http`）。
- 新增 Swift 代码。

## 6. 流程

### 6.1 阶段 0：准备（一个 agent，串行，最先做）

1. 采集 Swift 基线（第 7.1 节），**必须在任何 Swift 文件被删除之前完成**。
2. 建立 workspace：根 `Cargo.toml`、`rust-toolchain.toml`、`.cargo/config.toml`、全部 crate 的 `Cargo.toml`（依赖照 2.1），以及按清单生成的 `lib.rs`/`mod.rs` 模块树（只有 `mod` 声明，没有实现）。
3. 把 Diffuse 的 `AGENTS.md` 改为 Rust 版（照 Cove 的 AGENTS.md：Rust 2024、不新增 Swift、性能关键路径用 C）。
4. 把 Cove `703fb10c:Tools/Support/rust/` 恢复为 `xtask/src/support/`（G1）。
5. `cargo metadata` 能解析，即完成阶段 0。

### 6.2 阶段 1…N：按 crate 迁移

- crate 顺序见清单的 `crate_order`（即 2.1 表的顺序）。一个 crate 的所有依赖都到达 `compiled` 后，它才能开工。互不依赖的 crate 可以并行。
- 每个批次：`python3 Tools/Migration/inventory.py --next <crate>` 给出下一批（默认不超过 900 行 Swift）。单个文件超过 700 行时独占一个批次。先做生产代码，后做测试。
- **同时运行的 agent 不超过 4 个**（Natsel 的教训：再多会排队失败，整批作废）。一个 agent 大约能稳定完成 900–1,500 行忠实翻译。
- 批次结束：被翻译文件的 `status` 改为 `written`，追加第 9 节批次日志，运行 `inventory.py --check`。
- **crate 门禁**（与 Natsel、Cove 不同：它们到最后才统一编译，结果 Cove 留下了大量未验证代码）：
  1. crate 的生产文件全部 `written` 后，运行 `cargo check -p <crate> --all-targets` 与 `cargo clippy -p <crate> --all-targets -- -D warnings`，修编译错误时不得改变算法语义；通过后把这些行标为 `compiled`。
  2. 测试文件翻译完成后运行 `cargo test -p <crate> -- --test-threads=1`；全部通过（或带理由 `#[ignore]` 并登记）后标为 `tested`。
  3. 下游 crate 只依赖已 `compiled` 的上游。
- 体量最大的三个 crate 需要拆成多波次：`diffuse-editor-core`（339 个文件、48k 行）、`diffuse-editor-ui`（229 个文件、37k 行）、`diffuse-scene`（145 个文件、34k 行）。先翻译被大量引用的“锚点”文件（核心状态类型、Store、World/Scene 根类型），并把锚点暴露的类型与签名记在第 8 节，后续批次只用这些名字。

### 6.3 收尾

1. 全部 crate `tested`，`cargo test --workspace` 与 `cargo clippy --workspace --all-targets -- -D warnings` 通过。
2. 第 7 节的对等性检查全部通过。
3. 删除 Swift：所有 `Package.swift`、`Package.resolved`、`Sources/`、`Tests/`、`cove`、`cove.cmd`、`Editor/cove.json`、`Platforms/Android/Sources`，以及 `CoveUI` 符号链接（改为 Cargo 依赖）。清单行标为 `removed` 并注明原因。
4. CI（`.github/workflows/*.yml`）改为 `cargo` 与 `cargo xtask`；README（中英）、Website、CHANGELOG 同步更新。

## 7. 对等性验证

### 7.1 Swift 基线（阶段 0 采集，存入 `.migration/baseline/`）

- Swift 测试全量结果：`./cove test Engine`、`./cove test Editor`、`./cove test Engine/Media` 等，记录每个测试的通过/失败/跳过，存成 `swift-tests.json`。迁移前就失败的测试单独列出，Rust 端不要求它通过，但要说明。
- 模拟哈希：`SceneRuntimeBenchmarks`、`PhysicsRuntimeBenchmarks` 以 release 运行，记录每个场景的最终状态哈希（参照 Natsel 的 `NATSEL_HASH=1` 做法；Swift 端没有哈希输出时，先在 Swift 侧加只读的哈希打印，这是唯一允许改动 Swift 的场合，基线采集完立即还原）。
- 黄金文件：用 Swift 版本为每种 `Codable` 落盘格式（项目、场景、组件注册表、序列、插件清单、脚本资产、编辑器布局等）生成样本，存入 `.migration/baseline/formats/`。
- 渲染回读：NativeRendererTests 的回读结果（像素哈希）在本机 Metal 上记录一份。

### 7.2 Rust 端

- 测试结果与 Swift 基线逐项对照。
- 模拟哈希与 Swift 逐场景一致；不一致时用二分定位（Natsel 第 5 批次的做法），常见原因是浮点结合顺序、`Float.pi` 与 `remainder` 的语义、容器迭代顺序。
- 黄金文件往返字节一致。
- 着色器 uniform 结构的布局断言通过。

## 8. 共享词汇（随锚点批次补充）

翻译依赖尚未落地的类型时，引用这里登记的路径与签名；锚点文件必须恰好定义这些名字。

### `diffuse-math`（已 `tested`）

路径前缀均为 `diffuse_math::`。

- `simd::simd_compat`：`Float2`(8/8)、`Float3`(16/16)、`Float4`(16/16)、`Double2`(16/16)、`Double3`(32/16)、`Double4`(32/16)、`Int2`/`Int3`/`Int4`、`UInt2`/`UInt4`/`UInt8x4`/`UInt16x4`；常量 `ZERO`/`ONE`/`INFINITY`/`NEG_INFINITY`；构造函数 `new` 在**所有**向量类型上都有（含整数向量），另有 `Float3::splat/sum`、`Float4::xyz()`。整数向量不实现 `Debug` 派生而是手写，填充 lane 不出现在 `Debug`/JSON 里。
- 矩阵与四元数：`Float4x4`(64/16，`columns: [Float4; 4]`、`new/from_columns/new_with_columns/diagonal/from_scalar/from_rows/column/set_column/from_quatf/transpose/inverse`)、`Float3x3`(48/16，`new` 是零矩阵、`from_columns/new_with_columns/diagonal/from_scalar/from_float4x4/from_quatf/column/set_column`)、`Quatf`(16/16，`IDENTITY`、`from_vector/from_real_imag/from_parts/from_angle_axis/from_to/from_float3x3/from_float4x4/act/real/imag`)。
- 常量：`MATRIX_IDENTITY_FLOAT4X4`、`MATRIX_IDENTITY_FLOAT3X3`。
- 自由函数（带类型后缀以免 Rust 无重载）：`simd_min`/`simd_max`（Float3）、`simd_min2`/`simd_max2`、`simd_min4`/`simd_max4`、`simd_clamp`、`simd_clamp2`/`simd_clamp4`、`simd_clamp_scalar`、`simd_clamp_double`、`simd_mix3`/`simd_mix2`/`simd_mix4`/`simd_mix_scalar`、`simd_dot`/`simd_dot2`/`simd_dot4`/`simd_dot_f64_*`、`simd_length`/`simd_length2`/`simd_length4`、`length`、`simd_length_squared*`、`simd_distance*`、`distance`、`simd_distance_squared*`、`simd_normalize*`、`simd_cross`、`simd_abs`、`simd_transpose`、`simd_transpose3`、`simd_inverse`、`simd_inverse3`、`simd_determinant`、`simd_determinant3`、`cove_slerp`。
- `bounds::bounds_3d::Bounds3D`（`EMPTY`、`new/from_points/is_empty/center/extent/half_extent/include/contains/closest_point/union/intersection/intersects/expanded/expanded_scalar/transformed`）。
- `geometry::ray_3d::Ray3D`（`new/normalized/point_at/distance_to_bounds`）、`geometry::plane_3d::Plane3D`（`new/normalized/from_point/signed_distance/max_signed_distance/min_signed_distance`）、`geometry::frustum_3d::Frustum3D`（`new/from_view_projection/contains_sphere/intersects`）。
- `camera::camera_matrices::CameraMatrices`（`orthographic_rh_zo/perspective_rh_zo/look_at_rh`）。
- `transforms::transform_3d::Transform3D`（`new/identity/matrix/inverse_matrix/transform_point`）、`transforms::matrix_transforms::MatrixTransforms`（`translation/scale/rotation`）。
- `utility::easing::Easing`（31 个变体 + `evaluate/interpolate/interpolate_vector`）、`utility::float_comparisons::FloatComparisons`（`DEFAULT_TOLERANCE`、`nearly_equal_scalar*`、`nearly_equal*`）。

### `diffuse-kernel`（原已 `tested`；`JobSystem` 新增复制支持后为 `written`）

- `engine_kernel::{EngineKernelPhase, EngineKernelPhaseContext, EngineKernelFrameReport, EngineKernel}`。
- `in_game_canvas::{InGameUIColor, InGameCanvasCommand, InGameCanvas}`。
- `job_system::{JobDispatchReport, JobSystem}`（`parallel_for/parallel_compact_map/parallel_map/chunk_ranges`）。
- `input_event`、`window_id`：重新导出 `cove_platform` 的输入类型，另有 `WindowID = WindowId`。

### 落盘浮点格式（跨 crate 共用）

`diffuse_kernel::codable`：`format_double(f64) -> Option<String>`、`serialize_double`、`serialize_optional_double`。凡落盘 JSON 含 `Double` 的字段，都要用 `#[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]`，否则 serde_json 会写出与 Swift 不同的文本（见 §10）。已实测对齐的样例见该模块的单元测试。

### `diffuse-observation`（已 `tested`）

- `cold_log::{ColdLog, ObservationBusError}`。
- `event_envelope::{EventEnvelope, EventPayloadRef, EventPayloadHandle, EventPayloadRecord, EventValue, EventOrigin, EventOriginProcessKind, EventProvenance}`。
- `event_kind_registry::{EventKindId, EventKindSpec, EventKindRegistry, EventDomain, EventPayloadSchemaId, EventCardinality, EventOrdering, EventRetentionClass, EventCoalesceReducer, EventCoalesceHint}`。
- `publisher::{ObservationBus, ObservationSubscription, SubscriptionSpec, SubscriptionStartFrom, SubscriptionBufferPolicy, SubscriptionAckMode, SubscriptionDeliveryGuarantee, EventFilter, StreamCursor, SnapshotProvider, EventDraft}`。
- `subscriber::SubscriberToken`（`sink`/`events_stream`，基于线程与通道）。
- `event_symbolic_view::{EventSymbolicView, EventSymbolicViewWindow, SymbolicEvent}`。

### `diffuse-sequence`（已 `tested`）

- `sequence_document`：`SequenceDocument`、`Shot`、`Track`、`Clip`、`Binding`、`ShotOverride`、`Cut`、`Marker`、`SequenceCache`、`SequenceRevision`、`SceneTargetReference`、`FrameRange`、`TimeBase`、`SmpteTimecode`、`SequenceValue`、`SequenceResolution`、`AspectRatio`、`MotionBlurSettings`、`ClipPayload`、`ClipEase`、`TrackKind`、`ShotStatus`、`SequenceCacheKind`、`SwiftDate`、`new_uuid`。
- `clip_scheduler::{ClipScheduler, ScheduledClip, SequenceEvaluationOptions, SequenceFPSRemapMode}`。
- `shot_evaluator::{ShotEvaluator, EvaluatedSequenceFrame, EvaluatedShot, EvaluatedCut}`、`override_resolver::{OverrideResolver, ResolvedOverride}`、`cache_validator::{CacheValidator, CacheValidationResult}`、`binding_validator::{BindingValidator, RenderValidationResult, BindingError}`。

### `diffuse-capability`（已 `tested`）

- `capability_contract::{CapabilityAccess, CapabilitySource, CapabilitySourceKind, CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot, PluginCapabilityAuthority, ReleasePhase, new_uuid}`，以及 `CapabilityContract::tool_name()`。
- `capsule_schema`：Swift 形状的 JSON Schema 构建器（`string/string_pattern/string_enum/number/integer/boolean/array/object/choice/empty_object`）包住 Cove 的 `JsonSchema`。
- `capability_descriptor::{CapabilityDescriptor, CapabilityPreconditionSpec, PreconditionKind}`。
- `capability_registry::{CapabilityRegistry, CapabilityRegistryIntegrityError}`、`capability_validator::{CapabilityValidator, CapabilityValidationResult, CapabilityValidationError}`。
- `drafts::precondition_checker::{PreconditionCheckInput, PreconditionChecker, PreconditionViolation}`、`release::release_phase_gate::{ReleasePhaseGate, CapabilityDraftLimits}`、`release::sha256::{digest, capability_sha256_hex_digest, CapabilityDigest}`、`support::disposal::{Registration, DisposalScope}`、`support::swift_date::SwiftDate`。

### `diffuse-script-api`（新建；本轮属性/JSON 修订后为 `written`，未重新验证）

- `abi`：`HostApi`（函数表；当前 ABI 2，含 allocate/free/report_error）、`Slice`、`Bytes`、`Color4`(16/4)、`Transform3`(48/16)、`GroundState`、`CharacterStance`、`ABI_VERSION`。SDK 使用独立 `0.1.0` 包版本。
- `context::ScriptContext`（隐藏 `HostApi` 的安全封装，缺项保持 Swift 的 0/false 回退）。
- `authoring`：`ScriptBehavior`、`ScriptAuthoring`、`ScriptDefinition`、`ScriptProperty`、`ScriptPropertyOption`、`ScriptPropertyValue`、`ScriptParameters`、`ScriptDefinitionBuilder`、`authoring::json::{JsonValue, JsonObject, parse, parse_object}`。
- `export`：`diffuse_script_abi_version/create/on_start/on_pre_physics/on_update/on_destroy/destroy`、`CatalogEntry`、`catalog_bytes`、`diffuse_scripts!` 宏。

### `diffuse-script`（原生脚本核心已 `written`；动态脚本管线待 D1 改写）

2026-11-04 D1 增量（批次 78，未编译/测试）：`ScriptLoader::load_factory(id, path)` 仅接受单脚本目录；多脚本使用 `load_named_factory(id, path, name)`。`ScriptFactory = Arc<dyn Fn() -> Result<Script, ScriptLoadError> + Send + Sync>`，调用方必须处理创建失败后再注册返回的 Script。目录/选择失败不会替换旧代次，`definition(id)` 返回所选脚本的元数据，实例与工厂持有原动态库。HostApi ABI 为当前 SDK 的 3；通用桥接新增 29 项但尚未完整，见 §10。

- 根导出 `Script`、`ScriptCallback`、`ScriptBehavior`、`ScriptAuthoring`、`ScriptContext<'phase, 'world>`、`ScriptDefinition`、`ScriptProperty`、`ScriptPropertyValue`、`ScriptPropertyOption`、`ScriptParameterIssue`、`ScriptRuntime`、`ScriptVar`、`ScriptPresetKind`、`AnimationRuntime`。
- `ScriptRuntime` 的 Clone 保留 Swift class 的共享实例；`register_factory` 每绑定构造状态，`register` 保留共享回调，`register_authoring_behavior` 显式选择可选的 authoring trait（Rust 无 Swift 元类型协议转换）。暂停开关通过 `is_gameplay_execution_enabled/set_gameplay_execution_enabled` 访问；回调执行时不持有注册表锁。
- `ScriptContext` 本实体操作使用无后缀方法，其他实体使用 `_for/_of/_from`；世界变换读取会刷新层级。参数解析保留 NSNumber 对布尔值的数值桥接，authoring 类型校验仍严格拒绝数值位置的布尔值。
- 扩展 trait：`DefaultInputActions::cove_default`、`SceneSerializerScriptSupport::{serialize_full, deserialize_full}`、`PrefabScriptSupport::{instantiate_full, capture_full}`。`ScriptDebugState` 保留按原键排序、先取 32 项，再按字形簇截断键和值。
- `RuntimeScriptPhaseContext::with_physics_query_scene` 接收共享查询缓存；调度及 `SceneRuntime::run_script_driver` 均传场景已有缓存，五类脚本物理查询不另建后端。
- `ScriptCompiler::{new, compile, manifest_path, resolve_executable_url, build_arguments}`：接收 Scripts crate/Cargo.toml/内部源文件，输出目录下使用 `cargo-target` 复用 Cargo 缓存；结果为 `CompilationResult { output_path, stdout, stderr, diagnostics }`。完整 rustc 消息保存在 `ScriptCompilerDiagnostic::details`。
- `ScriptCompilationCancellationToken` 的 Clone 保持共享取消状态。默认编译时限为 None，调用方可设置 timeout；macOS/Linux 的终止升级保留 250 ms，输出管道在独立线程同时读至 EOF。SDK 导出宏要求 panic=unwind，编译器设置 release unwind 与 overflow checks。

### `diffuse-lsp`（已 `tested`）

- `byte_stream::{LspMessageFramer, LspDecoder, LspNotification, content_length, MAXIMUM_HEADER_BYTES, MAXIMUM_BODY_BYTES}`。
- `configuration::{LanguageServerConfiguration, WorkspaceFolder, ConnectHook, file_uri}`。
- `lsp::transport::{LanguageServerTransport, SharedTransport, Writer}`、`lsp::connection::LspConnection`、`lsp::error::{LspClientError, LspFailure}`、`lsp::client::LspClient`（同步请求 + 每请求超时，读线程替代 Swift 的 actor）。

### `diffuse-media`（已 `tested`）

- `MediaUrl`（Foundation `URL` 的替代，`from_file_path/parse/is_file_url/path/last_path_component/path_extension/appending_path_component/deleting_last_path_component/standardized_file_url/resolving_symlinks_in_path`）——**其他需要 `URL` 的 crate 复用或镜像它，不要另写一套 shim**。
- `MediaError`、`PCMBuffer`、`VideoFrame`、`MediaAsset`/`MediaAssetVideo`、`FileDecoder`、`GMStreamInfo`、`AudioFile`、`AudioReader`/`VideoReader`、`MediaComposition`/`CompositionClip`/`CompositionVideo`、`MediaExporter`/`ExportPlan`、`FFmpegTools`。
- 原生桥：`crates/diffuse-media/native/`（`Decoder.c/.h`、`Audio.c`、`Video.c`、`CFFmpegBridge.h`），`build.rs` 从 `DIFFUSE_NATIVE_ROOT`（默认 `vendor/`）链接，缺失时报出尝试过的路径并提示 `cargo xtask native-bootstrap`。

### `diffuse-exr`（已 `tested`）

- `EXRReader`/`LayerInfo`/`EXRReaderError`、`EXRWriter`/`Layer`/`PixelType`/`EXRWriterError`、FFI 类型 `CoveEXRContext`/`CoveEXRLayerDesc`（24 字节、8 对齐，已断言）。
- 原生桥：`crates/diffuse-exr/native/`（`openexr_bridge.cpp/.h`），C++17，`build.rs` 同上。

### `diffuse-cinematic`（已 `tested`）

- `aov_registry::{AovSpec, AovRegistry}`、`sampling_strategy::{SamplingStrategy, HaltonSampler, BlueNoiseSampler, SamplingStrategyPreset}`、`path_tracer::{PathTracer, PathTracerConfig, PathTracerState, Ray, CameraRay, SceneGeometry, HitResult}`、`simple_test_scene::SimpleTestScene`。
- 随机源：Swift 的 `Float.random(in:)` 换成文件内 splitmix64（不引入新 crate），采样范围与估计量形状不变。

### `diffuse-scene` Stage 1（破坏系统与提取层）

- `physics::destruction::{Destructible, DestructibleAsset, DestructibleFragmentAsset, DestructibleConnectionAsset, DestructibleAssetResource, DestructionSettingsResource, DestructionCommand, DestructionCommandFrameResource, DestructionCause, DestructionEvent, DestructionFailureReason, DestructionFailureEvent, DestructionRecycleReason, DestructionRecycleEvent, DestructionEventFrameResource, DestructionSourceState, DestructionStateFrameResource, DestructibleFragment, DestructibleRetainedFragment}`
- `physics::destruction_runtime::{advance_destruction_pre_physics, apply_destruction_contacts}`
- `physics::physics_frame_state::{PhysicsStepClockResource, PhysicsFrameBodyCounts, PhysicsFrameSynchronization, PhysicsFrameStateResource, PhysicsStateHashFrameResource}`
- `physics::physics_debug_frame::{PhysicsDebugBody, PhysicsDebugConstraint, PhysicsDebugDestructionConnection, PhysicsDebugFrameResource}`
- `physics::replay::physics_command_tape::{PhysicsRecordedBodyCommand, PhysicsRecordedCharacterCommand, PhysicsRecordedVehicleCommand, PhysicsCommandFrame, PhysicsCommandTape, PhysicsCommandRecordingResource}`
- `rendering::render_extraction::{RenderMeshComponent, RenderMaterialComponent, CameraComponent, LightType, LightComponent}`；`scene_bootstrap::{SceneNameComponent, SceneKindComponent, AssetReferenceComponent, SceneBootstrapDefaultsResource, preview_translation_matrix, preview_scale_matrix, preview_translation_scale_matrix}`

**破坏系统的「不要整理」语义（逐条实测）**：
- `accumulatedDamage` 是**饱和**的：`min(f32::MAX, a + b)`，绝不出 `inf`（64 次累加 `f32::MAX/2` 仍有限）。
- 命令顺序 = `(entity.rawValue, 原始偏移)`；接触 = `(entity, otherEntity, subShapeID)`。
- 碎片/连接列表**先排序再按预算截断**（截断稳定）。
- `sourceState` 在断裂后的提前返回**之前**写回 `runtime.sources`，否则非法碎片化命令会丢掉已断连接 ID。
- 休眠回收时钟在首次观察时启动，之后才计延迟。
- **`DestructionCommand.init` 的 `max(0, damage)` 会把 NaN 变成 0**（实测 Swift `max(0 as Float, .nan) == 0`），所以 `is_finite(damage)` 守卫对构造器建出的命令是死代码，只在结构体被直接改写时才有意义——**不要当作死代码删除**。
- **`LightComponent` 是第五个夹取顺序陷阱**：先 `outer = clamp(1...179)`，再 `inner = clamp(0...outer)`；顺序颠倒会在两者都越界时改变结果。

### `diffuse-scene` 物理层（批次 B 完成部分）

- `physics::backend::physics_backend_kind::{PhysicsBackendKind, Default}`：`Default` = `preferred()` = **`Natsel`**，不是首个枚举变体——Swift 唯一的隐式站点是 `PhysicsSettingsResource.init(backendKind: .preferred)`。**不要「修正」成 `None`。**
- `physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities`（`u32` option set，6 个标志 + `all()`）。
- `physics::backend::physics_backend::PhysicsBackend`：`Send + Sync`，11 个必需方法 + 2 个默认实现（`raycast_all`/`sweep_shape_all`，`max_hits: usize`，为 0 时短路）。
- `physics::backend::null_physics_backend::NullPhysicsBackend`：真实 null 行为，`capabilities() == .all()`。
- `physics::backend::physics_backend_context::{PhysicsSyncEvent, PhysicsPrepareContext/Result, PhysicsStepContext, PhysicsBodyWriteback, PhysicsStepResult}`。**upsert 载荷用 `Box`**（Swift 的关联值出线存储，`BodyUpsert(Box::new(..))`）；**`PhysicsBodyWriteback` 不 derive `Default`**（伪造 `EntityID(0,0)` 会让写回静默作用于实体 0）。
- `physics::physics_descriptors::*`、`physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource}`、`physics::physics_events::*`、`queries::trigger_detection::*`、`queries::physics_query_types::*`、`queries::spatial_queries`（仅 `MeshColliderGeometry`/`MeshColliderBoundsResource`/`MeshColliderGeometryResource` 三个）。
- `ComponentRegistry` ↔ `RuntimeWorld` 的循环：`RuntimeWorld` 按值持有 registry，schema 闭包以 `&RuntimeWorld` 作参数，不按值拥有。**优先用 `fn` 指针而非 `Box<dyn Fn>`**（Swift 侧是非捕获静态函数）；需要捕获时才用 `Box<dyn Fn + Send + Sync>` 加生命周期参数；**不要用 `Rc<RefCell<_>>` 绕借用检查**。

### `diffuse-plugin`（已 `tested`，53 个测试）

- `uuid::Uuid`——`new()` 生成 v4、大写、**36 字符 8-4-4-4-12**、本地校验；`parse`/`as_str`/`Display`/serde 字符串。刻意不委托给共享格式化器，凭据类 id 必须自身可校验。
- `base64_data::Data`——Swift `Data` 的 `Codable` 拼写（Foundation base64），所有 RPC 字段都用它；`encode_base64`/`decode_base64`。
- `contract::plugin_json::{PluginJSON, PluginJSON::Number}`——`PluginJSON` 是 `Eq`（清单要比较与哈希），`Number` 是 **`serde_json::Number` 而非 `f64`**，因为 `f64` 不是 `Eq`。
- `swift_manifest_json::encode_sorted<T>`——紧凑 `.sortedKeys` + `diffuse_kernel::codable::format_double` 的数字文本；**唯一**复现 Swift 数字拼写的文件，测试断言 `{"large":1e+20,"tiny":1e-07,"whole":100}`。
- `pattern`——25 个锚定模式改写成显式谓词（`lower_dash`/`lower_dot`/`lower_capability`/…），`glob_matches`，以及 fail-closed 的 `plugin_pattern::compile`（见 §10 的 G-隔离说明）。
- `PluginError`——crate 内所有 Swift 错误枚举的并集；调用点按变体匹配，对应 Swift 的 `catch PluginManagerError.x`。

**测试捕获的六个真实 bug（§5.4/§5.5 类，值得记录）**：`contributes` 需 `#[serde(transparent)]`（Swift 用 `singleValueContainer` 写成裸对象，否则每个清单都 `InvalidIdentifier`）；`PluginViewResult`/`PluginCommandResult` 必须拒绝顶层数组；`dependent_closure` 应为后序（先撤依赖方再撤提供方）；`enable` 回滚路径里 `MutexGuard` 临时值活进 `Err` 分支导致**真实死锁**；`pluginID`/`capabilityID` 是 Swift 合成键（`camelCase` 会把末尾 `ID` 小写化）；`pattern` 的两处测试期望写错而代码是对的。

### `diffuse-assets`（生产代码全部 `written` 或 `tested`，1 个测试文件待续）

- `swift_json::{to_sorted_pretty, to_compact, to_value, SwiftJsonValue, SwiftJsonError}`——**整份文档写出用这个**：Swift `JSONEncoder` 的 `.prettyPrinted + .sortedKeys` 模拟（两空格缩进、`" : "`、空容器 `[\n\n  ]`、`\/` 转义、按 UTF-8 code unit 排序、`Float`/`Double` 各自的科学计数阈值）。单字段的标量文本用 `diffuse_kernel::codable`。
- `asset_pipeline::{MeshAsset, MeshTopologySlice, MeshMaterial, MeshSubmesh, MeshTexture, MeshNode, MeshSkin, MeshAnimation*, BuiltinMesh, OBJLoader, OBJLoaderError, MeshNormalTools}`；`MeshAsset::append_vertex(9 参)` + `append_default_vertex`。
- `geometry::polygon_mesh::{PolygonMesh, PolygonFace, PolygonMeshEdge, PolygonEdge, PolygonEdgeUse, GeometryError, GeometryLimits, geometry_finite, geometry_normal, geometry_unit, GEOMETRY_UNIT_FALLBACK}`；`PolygonMesh::extrude_face` / `extrude_faces`（Swift 两个 `extrude` 重载）。
- `geometry::geometry_document::{GeometryDocument, GeometrySource, GeometryMaterial}`（`evaluate`/`save`/`load`）、`geometry::geometry_modifier::{GeometryModifier, GeometryModifierEntry, GeometryAxis}`、`geometry::geometry_baker::{GeometryEvaluation, GeometryShading}`。
- `asset_registry::{AssetRegistry, AssetRegistryEntry, RegisteredMeshAsset, ImportableAssetKind, AssetRegistryError}`、`mesh::mesh_asset_catalog::MeshAssetCatalog`、`project_resource_walker::{files, ProjectResourceWalkerError}`、`import::gltf_importer::{GLTFImporter, GLTFImporterError, PrimitiveMeshTopology, LoadedGLTF}`、`import::image_asset_decoder::{ImageAssetDecoder, DecodedTextureAsset, ImageAssetDecoderError}`、`import::mesh_texture_resolver::{MeshTextureResolver, ResolvedMeshTexture, MeshTextureResolverError}`。
- `mesh::destructible_asset_baker::{PrefracturedFragmentInput, DestructibleAssetBakeError, DestructibleAssetBakeResult, DestructibleAssetBaker}` 已 `written`；`bake` 的完整参数顺序是 `(asset_resource_id, revision, fragments, connections, automatically_generate_connections, connection_tolerance)`，`bake_fragments` 提供 Swift 默认值。`DestructibleAssetBakeResult::install(&mut SceneRuntime)` 只移除旧资产自有、且不在替换结果中的 `#convex:` 几何，保留其他资源。`asset_pipeline::AssetPipeline::{new, validate_path}` 也已补齐。未迁移的测试为 `DestructibleAssetBakerTests.swift`；本轮按用户要求不做测试。

### `diffuse-color` / `diffuse-card-battle` / `diffuse-documents`（已 `tested`）

- `diffuse_color::{aces_config, ocio_bridge, view_transform}`，19 个测试。
- `diffuse_card_battle::{core::*, rules::*, support::*}`，7 个测试。
- `diffuse_documents::{trash::Trash, workspace::Workspace}`，3 个测试。

### `diffuse-scene`（锚点已开始，完整 crate 待续）

- **「不要整理」的语义（逐条保留，勿合并/简化）**：
  - `diffuse_scene::physics::vehicles::vehicle::Vehicle` 的 `wheeled()`/`tracked()`/`motorcycle()` 三个预设各自的俯仰/滚转限制与引擎默认值不同（`.pi`/500 N·m、`.pi/3`/1500 N·m、`.pi/3`/150 N·m @ 10k RPM、6 挡、`clutch_strength: 2`），不得合并成「一个合理默认」。
  - `VehicleWheelConfiguration` 的两步夹取有顺序依赖：先按**未夹取**的上界夹 `suspension_min_length`，再把 `suspension_max_length` 抬到已夹取的下界；顺序颠倒会在两者都越界时改变结果。只保留 `new()` 构造，结构体字面量会绕过 Swift 的夹取。
  - `VehicleDifferentialConfiguration.limited_slip_ratio` 的下限是 **1.0001**，不是 1.0。
  - `TrackConfiguration.wheels` 是 `[i64; 3]`，缺位补 `-1`，不是 `Vec`。
  - `LocalTransform::rotation()` 把每个基列除以 `sx > 1e-6 ? sx : 1`：零长列**被除以 1**而不是被归一化，用 `.normalize()` 会在零缩放时产生 NaN。
  - `Cloth()` 的 `bend_type` 默认 `.distance`，而 `SoftBodyMesh()` 默认 `.dihedral`：兄弟类型默认值不同。

- `entity_id::{EntityID, RuntimeComponent}`：`EntityID { index: u32, generation: u32 }`，`new/from_raw_value/raw_value`，`Display` 与 Swift 一致；`RuntimeComponent: Clone + PartialEq + Send + Sync + 'static`（`'static` 代替 Swift 的 `ObjectIdentifier(type)` 作为组件身份）。
- 其余锚点（Scene 根类型、`WorldTransform`、`RigidBody`、`AudioSource`/`AudioListener`、组件注册表、序列化器）由 `diffuse-scene` 锚点批次补齐后追加到本节。
- （`diffuse-scene` 锚点批次后填写：Scene/World/Entity/Component 根类型。）
- （`diffuse-editor-core` 锚点批次后填写：Store、编辑器状态、面板注册类型。）

### `diffuse-script` 脚本组件与持久化（本轮 `written`）

- `core::script_component::{ScriptBindingID, ScriptHandle, ScriptBinding, ScriptComponent}`，在 crate 根重新导出。`ScriptBindingID::new/from_uuid_string/raw_value/uuid_string`：内部保存规范大写 UUID，脚本绑定的 Codable 字符串按 Swift 的显式实现写小写 UUID。`ScriptBinding::with_script/with_identifier` 提供 Swift 默认值，完整构造为 `new/from_identifier`。
- `interop::component_registry_script_codec::{ComponentRegistryScriptCodec, ScriptAuthoringDefaults, scene_document_scripts, encode_script_binding, decode_script_binding, encode_script_binding_for_editing}`。Rust 不允许为外部类型添加固有方法，所以 `register_script_codec(&mut self, default_identifier: &str)` 是扩展 trait，使用前导入 `diffuse_script::ComponentRegistryScriptCodec`；`register_default_script_codec()` 的默认标识符为 `cove.rotator`。
- 持久化脚本绑定不包含 `scriptHandle`；事务编码包含它。编辑时仅在绑定 ID 和 identifier 都匹配时复用原句柄，否则读取事务中的句柄。解码无效绑定 ID 时生成新 ID，保留 Swift 默认值。
- `ComponentSchema::make_default` 改为 `Arc<dyn Fn(EntityID, &mut RuntimeWorld) + Send + Sync>`，`for_component` 接收可捕获闭包：这是为了忠实保留每个脚本 registry 的 `defaultIdentifier`，不设全局映射或数量上限；其他不捕获的 schema 回调仍为函数指针，文档 schema 的默认分派相应包进 `Arc`。工厂只捕获字符串，不捕获 world，不产生所有权环。

### `diffuse-intent` 类型化能力与提交前置链（本轮 `written`）

- `capabilities::cove_capability::{CoveCapabilityInput, CoveCapability, AnyCapabilityRegistration, CapabilityPreparationTransform, CapabilityPreparationMaterial, CapabilityPreparationEntity, CapabilityPreparationContext, CapabilityPreview, PreparedCapability, CapabilityRegistrationError, CapabilityPreparationError}`，在 crate 根重新导出。`CoveCapability` 使用关联类型 `Input/Error` 和元数据常量；`AnyCapabilityRegistration::new::<C>()/descriptor/prepare` 统一 schema 校验、解码与纯准备，schema 验证仍由 `diffuse_capability` 重新导出的 Cove 实现完成。
- 4 个 `built_in_*_capabilities.rs` 已逐文件完成，`BuiltInTypedCapabilityCatalog::{registrations, registration, registry}` 注册原有全部 **36** 个能力。Swift 的嵌套 `Input` 在 Rust 中命名为去掉 `Capability` 后缀的类型名加 `Input`，例如 `SetCameraFOVInput`；`declare_capability` 仅生成重复声明，所有准备分支仍写在对应源文件。
- `invocation::capability_input_declaration::DeclaredCapabilityInput` 保留显式字段声明；补齐 `field_schema/entity_reference_schema` 对应的描述、数值/向量范围、字符串约束和组件要求。可选输入字段缺失时为 `None`，序列化仍写出 `null`，与 Swift 包装器的单值编码一致。
- `invocation::capability_invocation_planning::{CapabilityInvocationContext, CapabilityInvocationPlan, CapabilityValidationFailure, CapabilityInvocationPlanner}`；`CapabilityInvocationPlanner::new(registry, gate, scorer, allow_external_side_effects, plugin_authorities, plugin_authority_validator)`，`plan(&TransactionIR, &CapabilityInvocationContext)`。`CapabilityInvocationPlannerError::CapabilityDenied` 已补齐，错误文本保留 Swift 的 `capability validation failed:`。
- `pipeline::commit_pipeline::{CommitEntry, CommitRequest, CommitDenialCode, CommitDenial, CommitDecision, CommitPipelineError, CommitPipeline, Handler}`；`Handler` 为 `Arc` 闭包，`CommitHandlerError` 为可保留具体错误类型的 `Box<dyn Error + Send + Sync>`。顺序保持 context 要求 → planner → forbidden 策略检查，入口策略可用 `appending` 组合。
- `transactions::staged_transaction_store::{StagedTransactionSnapshot, StageTransactionResult, ApplyStagedTransactionResult, DiscardStagedTransactionResult, StagedTransactionStore}`；`stage(&TransactionIR, &TransactionExecutionContext)`、`apply_staged_transaction(&mut TransactionExecutionContext)`、`discard_staged_transaction(Option<&TransactionExecutionContext>)`。仅锁住 staged 状态，预览、执行和事件发布都在锁外；失败时的保留/清除顺序与 Swift 一致。
- 补齐历史 `written` 文件里的缺口：`SceneMutation::component_fields/component_data`；`SceneStateAssertion::verification_key/superseded_verification_keys`；`TransactionVerificationAssertion::exact_postconditions`。`component_data` 始终经过 registry codec、使用 `GameSave` 编码用途；可选 merge 字段缺失时省略，显式 `ComponentValue::Null` 保留。
- `transactions::transaction_executor::{TransactionExecutionContext, TransactionApplyResult, TransactionExecutor, TransactionExecutorError, TransactionExecutionError}` 已 `written` 并在 crate 根导出。`TransactionExecutionContext::new` 接收 scene/sequence/asset registry/bus/origin 和 4 个 stream ID；`Default` 提供 Swift 的空值与流名称。scene/sequence 为可复制值，registry/bus 为 `Arc` 引用；初始化时在场景自己的 registry 注册脚本 codec。`preview(&TransactionIR, &TransactionExecutionContext)` 拒绝 asset 变更并关闭副本的 observation bus；`apply(&TransactionIR, &mut TransactionExecutionContext)` 在校验、组件变更、后置条件或 outbox 发布失败时恢复原 scene/sequence，失败事件发布错误不覆盖原错误，asset registry 的外部变化按 Swift 不回滚。
- `intent_runtime_coordinator::{CapabilityInvocationDisposition, CapabilityInvocationResult, IntentRuntimeCoordinator, IntentRuntimeCoordinatorError, validate_confirmation_resolution}` 已 `written` 并在 crate 根导出。协调器为共享 `Arc<Mutex<...>>` 状态，入口策略按注册顺序执行，撤销历史公开为 `Arc<Mutex<UndoStack>>`；`new` 接收 owned UndoStack，`with_shared_undo_stack` 接收共享历史。`submit_plan`、`resolve_plan_confirmation`、`undo/redo` 均已接线，确认解答集及选项严格校验，AI 破坏性写入保留先整计划后破坏性警告的两轮确认，最终应用前仅重跑 Swift 原有的 standard pipeline。
- **生产翻译进度**：`diffuse-intent` 的 22 个生产文件全部 `written`；4 个测试文件仍 `pending`。尚未运行编译、clippy 或测试，不将这些行提升为 `compiled`/`tested`。

### 场景副本与共享后端（2026-11-01 配套语义修复，`written`）

- `SceneRuntime`、`RuntimeWorldSchedule` 和 `ScheduleState` 支持 `Clone`：world、命令缓冲、时钟、同步缓存和帧状态按值复制，物理后端和脚本驱动器保留 Swift `AnyObject` 引用语义，查询缓存保留 Swift `PhysicsQueryScene` 类引用语义。事务预览/失败回滚和 UndoStack 不会重新创建或丢失模拟配置。
- `physics::backend::physics_backend::SharedPhysicsBackend` 用 `Arc<Mutex<Box<dyn PhysicsBackend>>>` 共享真实实例，转发全部后端方法（含多命中重载）；`same_instance` 比较实例身份。当前生产后端的不可变 identifier 在构造时保存，查询后端返回 shared handle 值而非临时锁里的借用。
- `PhysicsQueryScene` 的 backend 和计数缓存在同一个共享状态中；`backend/synchronize` 返回 `SharedPhysicsBackend`，`replace_shared_backend` 接收现有 handle，`stats` 仍返回值快照。`RuntimeWorldSchedule::physics_query_backend` 与 `RuntimeScriptPhaseContext::physics_query_backend` 同步返回该 handle。
- `scripting::SharedRuntimeScriptDriver` 共享 driver 引用，调度器和 SceneRuntime 的 `set_script_driver` 接收 `impl Into<SharedRuntimeScriptDriver>`；兼容 `Box<dyn RuntimeScriptDriver>`、具体 driver 的 Box 与已有 shared handle。重复设置同一个 shared handle 不执行 reset，替换或清除时才 reset。
- 静态对照发现并修复两处旧接线偏差：`set_physics_backend` 原来保存显式 backend 后却实际安装另一个 preferred backend；`ensure_configured_physics_backend` 原来分别创建 simulation/query/shared 三个实例，导致共享身份判断恒为 false。现在显式 override 真正参与模拟，默认模拟与查询复用 Swift 的同一个 shared backend；初始 active backend 按 Swift 为 Null，shared/query backend 为 preferred。
- `JobSystem` 的 Rust 状态仅有只读配置对应的 worker 数和最小 chunk size，新增配置值 `Clone` 以支持 schedule 副本；该源文件旧 `tested` 状态已退回 `written`。`SceneStateAssertion::failure_description` 的全部 39 个状态分支已补齐，失败消息与 Swift 一致。

## 9. 进度与批次日志

`python3 Tools/Migration/inventory.py --status` 输出各 crate 的计数；每个批次在下面追加一行：

| 日期 | 批次 | crate | 文件 | Swift 行 | 结果 |
|---|---|---|---|---:|---|
| 2026-10-31 | 阶段 0 | workspace + 34 crate + xtask | 1337 | 208269 | 脚手架生成，`cargo check --workspace --all-targets` 通过；G1 的 `xtask/src/support` 已从 Cove `703fb10c` 恢复 |
| 2026-10-31 | 批次 1 | diffuse-math | 19 | 1384 | `tested`，27 个测试；SIMD/矩阵/四元数布局断言全绿 |
| 2026-10-31 | 批次 2 | diffuse-kernel | 5 | 334 | `tested`，clippy 干净 |
| 2026-10-31 | 批次 3 | diffuse-observation | 8 | 1619 | `tested`，12 个测试 |
| 2026-10-31 | 批次 4 | diffuse-sequence | 8 | 1485 | `tested`，10 个测试；`Track` 的 `solo`/`lock` 按 Swift `CodingKeys` 不落盘 |
| 2026-10-31 | 批次 5 | diffuse-capability | 13 | 2405 | `tested`，36 个测试；G6 未落地，经 `cove_devtools::agent` 过渡 |
| 2026-10-31 | 批次 6 | diffuse-script-api（新建） | 4 | — | `tested`，10 个测试；D1 的 C ABI 与 `diffuse_scripts!` 宏 |
| 2026-10-31 | 批次 7 | diffuse-lsp | 6 | 550 | `tested`；同步请求 + 超时，读线程替代 actor |
| 2026-10-31 | 批次 8 | diffuse-media | 7 | 365 | `tested`，6 个测试；CFFmpegBridge 迁入 `native/`，真实 FFmpeg 导出测试通过 |
| 2026-10-31 | 批次 9 | diffuse-exr | 3 | 283 | `tested`，6 个测试；COpenEXRBridge 迁入 `native/`，真实往返测试通过 |
| 2026-10-31 | 批次 10 | diffuse-cinematic | 5 | 751 | `tested`，14 个测试；`Float.random` 换成 splitmix64 |
| 2026-10-31 | 批次 11 | diffuse-color / diffuse-card-battle / diffuse-documents | 19 | 1710 | `tested`，19+7+3 个测试 |
| 2026-10-31 | 批次 12 | capability 切换 `cove-agent`（G6 关闭） | — | — | `diffuse-capability` 36 个测试仍全过；`cargo check --workspace --all-targets` 通过 |
| 2026-10-31 | 批次 13 | diffuse-kernel（补 `codable`） | — | — | Swift 兼容浮点文本：`format_double`/`format_float`/`serialize_*`；f32 与 f64 的上界不同，已按 Swift 6.4.1 实测断言 |
| 2026-10-31 | 批次 14 | diffuse-math（补 SIMD serde） | — | — | SIMD/矩阵/四元数按 Swift 的 lane 数组编码，填充 lane 不落盘；27+3 个测试 |
| 2026-10-31 | 批次 15 | diffuse-audio | 7 | 1114 | `tested`，15 个测试；`AudioBackend` 全实现，SDL3 设备 API 缺（G7），`AudioScene` 适配待 `SceneRuntime` |
| 2026-10-31 | 批次 16 | 状态审计 + Swift 基线 | — | — | 按内容审计把 5 个「部分翻译」与 11 个脚手架占位从 `written` 退回 `pending`；采集 `.migration/baseline/formats/` 三份 Swift 真实输出，`diffuse-kernel` 逐字节复现 |
| 2026-10-31 | 批次 17 | Swift 基线采集（`diffuse-math`） | — | — | `./cove test Engine --filter EngineMathTests` 27/27 通过并归档 `.migration/baseline/swift-tests.json`；与 Rust 端 27 个用例逐名一致，见 `parity.md` |
| 2026-10-31 | 批次 18 | Swift 基线采集（其余已完成 crate） | — | — | ObservationBus 12、Sequence 10、Capability 36、Cinematic 14、Color 7、Audio 16、CardBattle 18 全部通过并归档；与 Rust 端对照见 `.migration/baseline/parity.md` |
| 2026-10-31 | 批次 19 | diffuse-audio 收尾 | 7 | 1114 | `tested`，15 个测试，clippy 干净；`neg_cmp_op_on_partial_ord` 用带理由的局部允许保留 NaN 语义 |
| 2026-10-31 | 批次 20 | diffuse-assets | 36 | 5707 | `tested`，92 个测试（88+4），clippy 干净；`swift_json` 逐字节复现 Swift pretty 布局；按 §5.7 删除 5 处 `#[allow(dead_code)]` 及其真正未使用的字段 |
| 2026-10-31 | 批次 21 | 脚手架占位清理 + 状态复核 | — | — | 1168 个 1 字节占位文件归零；按内容审计确认 `diffuse-scene` 实为 15 个真实文件（44 个测试），`diffuse-assets` 36/39 |
| 2026-10-31 | 批次 22 | diffuse-render（GPU 布局与设置） | 3 | — | `render_uniforms`（布局断言：Skybox 112/Ssao 160/Ssr 160/Stylized 64/Post 16，均 16 对齐）、`render_settings`、`native_mesh_vertex_layout`（复用 `cove_graphics::rhi`，不重复定义）；`diffuse-render` 3 个文件 `written`，3 个测试 |
| 2026-10-31 | 批次 23 | diffuse-scene 批次 A-remainder + B（队友） | 13 | — | `diffuse-scene` 105 个测试；`PhysicsQueryOptions` 去掉 `Copy`（内嵌 `BTreeSet`）；`RuntimeWorld` 零后端依赖已核实 |
| 2026-10-31 | 批次 24 | diffuse-scene 批次 B（队友） | 11 | — | `diffuse-scene` 154 个测试；`PhysicsBackendKind::default()` = `Natsel`、`PhysicsBodyWriteback` 无 `Default`、upsert 载荷 `Box` 化、`PhysicsBackend: Send + Sync` 均已记录 §8 |
| 2026-10-31 | 批次 25 | diffuse-scene `ComponentRegistry` + `RuntimeWorld`（队友） | 2 | — | `diffuse-scene` 186 个测试；循环依赖用 `fn` 指针解决；新增私有 `AnyComponent`（`dyn Any` 无法 clone）与 `ComponentTypeKey::Document(u64)`；`diffuse-audio` 随即接上真实 `RuntimeWorld` |
| 2026-10-31 | 批次 26 | diffuse-audio 接入 `RuntimeWorld` | 1 | — | `impl AudioScene for RuntimeWorld` 完成，3 个集成测试走真实 world（含 25/50 距离衰减到 0.5）；18 个测试，clippy 干净 |
| 2026-10-31 | 批次 27 | UUID 缺陷修复（跨 6 crate） | — | — | node 用 `{node:012X}`；`diffuse-kernel::codable::new_uuid` 为规范实现，其余 5 处本地副本同步修正并各带形状断言 |
| 2026-10-31 | 批次 28 | diffuse-plugin 生产代码（队友） | 51 | 5945 | 生产文件全部落地，clippy 干净、无孤儿、无 `dead_code`；测试文件进行中 |
| 2026-10-31 | 批次 29 | diffuse-scene Stage 1（破坏系统+提取层，队友） | 7 | 2105 | `diffuse-scene` 230 个测试、43 个实现文件；`max(0, NaN) == 0` 实测确认 `is_finite(damage)` 守卫非死代码；`LightComponent` 为第五个夹取顺序陷阱 |
| 2026-10-31 | 批次 30 | diffuse-plugin 测试（队友） | 9 | 1200 | `tested`，53 个测试全过（44 个套件用例与 Swift 逐一对齐 + 9 个内部单测），clippy 干净；`packaged_broker`、`process_output`、`processes` 三个环境依赖用例在本机真实执行（宿主二进制与 `/usr/bin/{head,printf}` 均存在）；`contributes` 需 `#[serde(transparent)]`、`pluginID`/`capabilityID` 为 Swift 合成键，均由测试捕获 |
| 2026-10-31 | 批次 31 | diffuse-plugin 完成 + math API 补齐 | — | — | `diffuse-plugin` 53 个测试（44 与 Swift 逐一对应 + 9 内部单测）；补 `Float3x3::new_with_columns`（`Float4x4` 早有而 `Float3x3` 缺，属我的 API 不对称） |
| 2026-10-31 | 批次 32 | Natsel 上游修复（G8）+ `make_backend()` | 7 | 1244 | Natsel 侧新增 `unsafe impl Send for World`（带 SAFETY 论证，不实现 `Sync`）与 `CharacterVirtual::from_raw_world`，Natsel 测试 530→532；`diffuse-scene` 的 `make_backend()` 两臂真实落地，264 个测试 |
| 2026-10-31 | 批次 33 | diffuse-scene `scheduling/` 报告与帧上下文 | 2 | 196 | `schedule_report`、`schedule_frame_context` 完成；`RuntimeSystemPhase` 补 `Ord`（声明序=执行序）；272 个测试 |
| 2026-10-31 | 批次 34 | `scheduling/physics_state_hash` + `physics_query_scene` | 2 | 302 | 确定性哈希（种子/乘数/小端字节序必须逐字节对齐 Swift，改动即作废所有基线）；`PhysicsQueryScene` 缓存 + `resolved_collider_shape` 回退；286 个测试 |
| 2026-10-31 | 批次 35 | `SceneSerializer` + `Prefab` | 2 | 335 | 场景文档格式 v3；逐字节对齐 Swift `JSONSerialization(.prettyPrinted,.sortedKeys)`（两空格、`" : "`、空容器空行、UTF-8 code unit 排序）；实体交叉引用写成文档索引使 prefab 可迁移；299 个测试 |
| 2026-10-31 | 批次 36 | `scripting.rs`（`RuntimeScriptDriver` + 阶段上下文） | 1 | 263 | 用 `&mut` 借用对替代 Swift 的两个裸指针（无需 `unsafe`）；补 `VehicleCommandFrameResource`；306 个测试 |
| 2026-10-31 | 批次 37 | `scheduling/physics_collection` | 1 | 236 | 描述符收集 + 逐帧 sync 事件差分；约束在其任一刚体变化时必须重发（描述符不含刚体变换）；软体双拓扑冲突转发 `Invalid` 而非静默择一；313 个测试 |
| 2026-10-31 | 批次 38 | `physics_collection` 收尾 + `WorldSchedule` 前置类型 | 2 | 96 | 补 `JointPalette`/`JointPaletteMap`（`JointPalette::identity` 为单元素）、`RenderDeformableMesh`、`PhysicsCommandReplayControlResource`；317 个测试 |
| 2026-10-31 | 批次 39 | `scheduling/ragdoll_bridge` + `cove_slerp` 测试 | 1 | 156 | 方向双向桥接；`blend_transform_matrices` 在 0/1 端点**原样返回**源矩阵（不混合）；非模拟骨骼转 kinematic 仍推动动态刚体；palette 补 identity 到最大索引；`cove_slerp` 已存在（f64 三角对齐 Swift），补 5 条断言；324 个测试 |
| 2026-10-31 | 批次 40 | `schedule_debug_frame` + 空间索引类型 | 2 | 188 | 补 `SpatialIndexEntry`/`SpatialIndexResource`（`SpatialQueries.swift` 的真实缺口）；调试帧按实体升序、连接按 `(id, a, b)` 排序，碎片位置取**首次出现**；329 个测试 |
| 2026-10-31 | 批次 41 | 空间索引构建 | — | 103 | `build_spatial_index_resource`：球/胶囊用「半径 × 最大基向量长度」而非变换 AABB 角点（避免旋转椭球高估）；无几何的 mesh 回退半单位盒；记录 `world.revision()`；发现并记录 `WorldTransform` 需传播的语义；333 个测试 |
| 2026-10-31 | 批次 42 | `scheduling/schedule_phases` + 渲染骨架类型 | 1 | 574 | 十个阶段函数；`fixedPhysicsStep` 在 `prepare` 失败时拒绝推进；sync 缓存仅在成功后提交；`physicsWriteback` 先传播再刷新缓存；补 `RenderScene`/`RenderCamera`/`RenderInstance`/`ExtractedRenderSceneResource`；334 个测试 |
| 2026-10-31 | 批次 43 | `world_schedule` + `render_scene_extraction` | 2 | 523 | 十阶段循环；命令帧在 revision bump 后清空（postPhysicsScripts 入队的命令必须活到下一帧）；形变网格实例变换强制 identity（后端已用世界空间顶点）；相机选首个 `is_active`，退化为首个相机；347 个测试 |
| 2026-10-31 | 批次 44 | **`SceneRuntime` 落地**（关键里程碑） | 2 | 855 | `SceneRuntime` + `SceneRuntimeSnapshot`/`InputFrameResource` + `PhysicsReplayReport`/`PhysicsReplayMismatch`；`tick` 先写 `InputFrameResource` 再跑调度；358 个测试。**`diffuse-intent`/`diffuse-script`/`diffuse-render` 的下游阻塞解除** |
| 2026-10-31 | 批次 45 | `diffuse-intent` 起步：`Edit` + `IntentIR` | 2 | 267 | `IntentArgumentValue` 的 `stable_id` 蛇形线上拼写经 Swift 实测确认（`{"type":"stable_id","value":42}`）；`WorldRevisionSnapshot` 空值序列化为 `{}`；`diffuse-intent` 补 `serde`/`serde_json`（workspace 依赖，非新增第三方）；11 个测试 |
| 2026-10-31 | 批次 46 | `diffuse-intent` 事务层：`TransactionIR` + `SceneStateAssertion` | 4 | 772 | `SceneStateAssertion` 38 个变体完整；`SceneMutation`/`TransactionOperation` **不实现 serde**（承载 `LocalTransform`/`ComponentValue` 等运行时类型，与 Swift 非 `Codable` 一致）；`SequenceMutation::ReplaceDocument` 装箱以消除变体尺寸差；27 个测试 |
| 2026-10-31 | 批次 47 | `diffuse-intent` 确认流程类型 | 1 | 156 | `ConfirmationQuestion`/`Option`/`Batch`/`Answer`/`Resolution` 全部落地；`choose_one`/`approve_destructive` 蛇形原值经 serde 显式重命名；`CapabilityInvocationPlannerError` 缺 `capabilityDenied` 变体（依赖 `CapabilityValidationFailure`，属 planner 文件）；`diffuse-intent` 补 `thiserror`；33 个测试。**Cove 阻塞已解除** |
| 2026-10-31 | 批次 48 | `WorldEvent` + `component_changes` 投影 | 2 | 167 | `WorldPropertyValue` 手写编码：`vec3`/`vec4` 写 `x/y/z/w` **不写 `value`**，标量只写 `value`（Swift 手写 `encode(to:)` 的不对称）；组件文档投影到语义事件，`rendering`/`collider`/`script` 有专属字段名映射；46 个测试 |
| 2026-10-31 | 批次 49 | `UndoStack` + `IntentTransactionBuilder` | 2 | 255 | 撤销栈双栈各自独立限容、push 清空 redo、空栈 undo 不保存 current；builder 的 verb 表是完整契约（未知 verb 报错而非猜测），纯空白字符串参数视为缺失，目标解析优先级 `entity_id` > `targetObjectIDs` > 选中项；65 个测试 |
| 2026-10-31 | 批次 50 | `AmbiguityScorer` | 1 | 300 | 权重是行为不是可调参数：AI 置信度不足按 0.35×shortfall、人类按 0.25×shortfall（非线性，随低于阈值程度缩放）；每个缺失必需参数 +0.20；破坏性 verb +0.15；仅 AI 意图要求 evidence（+0.10）；总分 clamp 到 1.0；78 个测试 |
| 2026-10-31 | 批次 51 | `CapabilityInputDeclaration` | 1 | 442 | **Swift 的 property wrapper + `Mirror` 反射在 Rust 无对应机制**，故改为显式 `DeclaredField` 列表构建 schema，保留闭世界语义（`additional_properties: false`，未声明字段 → `JsonSchema::any` 使注册 fail-closed）；`SceneEntityRef` 解析期即拒绝非法引用；向量编码为裸数组且元素数严格；89 个测试 |
| 2026-10-31 | — | 并行：`xtask` 交由 `translate-xtask` 队友 | — | — | `xtask` 无 Diffuse 依赖、14,657 行，适合并行；已交接 `support/` 的 80 个 dead-code 错误须由正式翻译消除而非 `allow` |
| 2026-10-31 | — | **Cove 侧阻塞（非本项目）** | — | — | `cargo check --workspace` 因 `../Cove` 未提交改动失败：`Compose/rust/primitives/overlays/toast/notification_host.rs:94` 的 `Rc<dyn Fn()>` 不满足 `Send`。我未编辑 Cove；已确认 Diffuse 自身 17 个 crate `--all-targets` exit 0 |
| 2026-11-01 | 批次 52 | diffuse-scene 生产代码收尾（19 个粒子文件 + `Codecs/Particles.swift` + `RenderParticles.swift` + 25 个组件/物理/序列化模块 + 2 个 bench） | 48 | 8360 | 48 个生产文件全部 `written`。逐文件内容审计（`func`↔`fn` 覆盖、`struct`↔`pub` 字段覆盖、关键语义逐段对照）确认 21 个粒子批文件与 27 个非粒子文件均无缺口；两个 bench 按 `harness = false` 独立可执行，`COVE_PHYSICS_*` 的读取/默认值/钳制与 Swift 逐条一致，`peak/current RSS` 的三平台 `#[cfg]` 分支齐全。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check`（`0 problem(s)`） |
| 2026-11-01 | 批次 52 语义记录 | — | — | — | ① `ComponentTypeID` 用 `TypeId` + `type_name` 末段替代 `ObjectIdentifier`，`Constraint` 是类型别名故显式 `named::<Constraint>("Constraint")`；② `DocumentComponentSchema` 用 256 上限的静态 slot 表 + 常量泛型跳板替代 Swift 闭包捕获，`ObjectIdentifier` 语义由 slot 序号保留；③ `RequiredComponents` 的两个 Swift `RuntimeWorld` 方法改为接收 `world` 的自由函数（`inconsistent` 同名限制），并用 `ComponentEditFailure` 合并两种无类型 `throws`；④ `RenderGeometryOverlay` 的默认参数拆成 `new`/`with_edges`/`with_width`/`with_size`/`with_xray`；⑤ `scene_graph` 的 `local_transform_for_world` 恒返回 `Some`（Swift `guard` 的 else 返回 `world` 本身）；⑥ `ParticleSpawnResult::dropped` 与 `ParticleSpawnBudget::limit` 在 Swift 侧**无读取点**，Rust 未保留这两个死字段 |
| 2026-11-01 | 批次 53 | diffuse-scene 测试套件（6 个文件） | 6 | 846 | 6 个测试文件全部 `written`，共 32 个 `#[test]`：`advanced_rigid_body_tests`(8)、`animation/playback_editing_tests`(2)、`component_declaration_tests`(4)、`component_inspection_tests`(5)、`component_registry_tests`(7)、`compound_collider_tests`(6)。同时补上生产缺口 `SceneRuntime::component_descriptions`（Swift `Inspection.swift:139`）与 inspection 结构的 camelCase serde 键名（§5.4）。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 53 语义记录 | — | — | — | ① `SceneRuntime::component_descriptions` 原缺失：`defaults` 世界只持有 registry，每个 schema 从 pristine 副本克隆；无默认值时回退到场景中第一个已创作实例，再回退 `.object([:])`；② `ComponentDescription`/`ComponentInspection`/字段描述等结构补 `rename_all = "camelCase"`，`sectionID`/`typeID` 显式 `rename`（Swift `Codable` 键名，§5.4）；③ Swift `ComponentValue` 的 `==` 对数字变体做 `Int64`/`UInt64(exactly:)` 归一化，Rust 是严格变体相等——bendType 断言改用 `numeric_value()`，registry 测试用本地 `numeric_equivalent`；④ `SceneRuntime` 无 `Clone`，`scene_local_registration` 用同一 registry 新建 runtime 替代 Swift 的 `var copied = scene`；⑤ Rust `tick` 需 `frame_index` 与 `input_events`，测试按帧递增并传空输入；⑥ fixture 用 `include_str!` 指向 `Engine/Tests/SceneRuntimeTests/Fixtures/component-registry-v3.json` |
| 2026-11-01 | 批次 54 | diffuse-scene 测试（`DestructionTests`） | 1 | 953 | `Engine/Tests/SceneRuntimeTests/DestructionTests.swift` → `crates/diffuse-scene/src/tests/scene_runtime/destruction_tests.rs`，1566 行、25 个 `#[test]`，与 Swift 25 个用例 1:1；`rustfmt --edition 2024` 通过。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 54 语义记录 | — | — | — | ① Rust `tick` 需 `frame_index`，但仅写入 `InputFrameResource`、十个 phase 无一读取，故测试固定传 0（`replay_physics_command_frame` 自身也传 0）；② `SceneRuntime::resource::<R>()` 返回克隆，`configure_localized_loop`/`configure_fragment_rendering` 改完必须 `set_resource` 回写；③ Swift `invalidCommand.damage = .nan` 绕过了 `init` 的 clamp，Rust 直接改公有字段以复现「NaN 命令被判无效」；④ 阈值语义：连接阈值 `0` 继承实体级阈值，且 `damage_break`/`impulse_break` 要求阈值 `>0`，故阈值 0 = 永不破坏（`saturating_damage` 断言 `has_fractured == false`）；⑤ 完整断裂的 `broken_connection_ids` 是全部连接 ID，增量岛按「fragment 0 所在连通分量」保留、其余 detached，已断连接不重复计入事件（第二次命令事件为 `[11,12]`）；⑥ `recycle` 优先级 SourceRemoved > LifetimeExpired > Sleeping；⑦ fragment/connection 在预算截断前按 ID 排序，`fragments.reverse()` 只用于验证顺序无关性；debug frame 的 connections 同样按 ID 排序；⑧ `codable`/`GameSave`/`Prefab`/`SceneSerializer` 往返均走已落地的 Rust 结构，`Prefab::capture` 对 fragment 返回 `Ok(None)` |
| 2026-11-01 | 批次 55 | diffuse-scene 测试（7 个文件） | 7 | 567 | 7 个测试文件全部 `written`，共 34 个 `#[test]`：`empty_mesh_collider_tests`(4)、`game_save_tests`(6)、`local_transform_convenience_tests`(1)、`native_character_controller_tests`(3)、`natsel_migration_tests`(7)、`navigation_tests`(9)、`particle_settings_tests`(4)。Swift 的 `@Test(arguments:)`（空网格 3 个 mesh-backed shape）拆成 3 个独立用例 + 1 个共享 helper。**按用户要求未运行 cargo 门禁**，只跑 rustfmt（`--edition 2024`，7 个文件 `--check` 退出 0）与 `inventory.py --check` |
| 2026-11-01 | 批次 55 语义记录 | — | — | — | ① `GameSave.capture(scene:state:metadata:)` → `capture_with_state`，无 state 的 `capture(scene:metadata:)` → `capture`，Swift 的 metadata 默认参数在 Rust 侧显式传 `BTreeMap::new()`；② Swift 的 memberwise 便捷 init 在 Rust 是 `with_shape`/`with_shapes` 加公有字段赋值（`is_trigger`、`layer_mask`、`gravity_scale`）或 `struct update`（`CharacterCommand`/`RigidBodyOptions`）；③ `PhysicsOverlapAABBQuery(maxResults:)` → `with_max_results(bounds, i64)`，`PhysicsRaycastQuery(...maxDistance:)` → `with_distance`；④ `NavPathfinder.Cell` → `NavCell`，`simd_distance` 来自 `diffuse_math::simd::simd_compat`；⑤ Swift 的 `x == previousX` 用 `partial_cmp(...) == Some(Equal)` 保留 IEEE 语义且不触发 `float_cmp` lint；⑥ 粒子分组设置经 serde 容器级 `default` 复现 `decodeIfPresent ?? 默认值`，`ParticleEmitter::new` 仍执行 `normalize`，因此断言的是钳制后的值（`noiseScale` 0.0001、`restitution` 1、`ribbonSmoothingSegments` 16、`workgroupSize` 1）；⑦ 场景记录键为 `particleEmitter`/`settings`，旧扁平键 `emissionRate`/`seed` 不存在 |
| 2026-11-01 | 批次 56 | diffuse-scene 测试（`ParticleTests`） | 1 | 2588 | `Engine/Tests/SceneRuntimeTests/ParticleTests.swift` → `crates/diffuse-scene/src/tests/scene_runtime/particle_tests.rs`，3246 行、81 个 `#[test]`，与 Swift 81 个用例 1:1（独占批次，>700 行）；`rustfmt --edition 2024` 已格式化且 `--check` 退出 0。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 56 语义记录 | — | — | — | ① Swift `ParticleEmitter(settings: .init { … })` → `emitter_with(|settings| …)`（构造即 `normalize`，断言的是钳制后的值）；`advance(deltaTime:)` → `advance(&mut emitter, dt)` 封装 `advance(dt, None, &ParticleAdvanceOptions::default())`，带变换时 `advance_within` 传 `Some(matrix)`；`emit(n)` / `emit(n, Some(matrix))` 同名多参；② `matrix_identity_float4x4` + `columns.3 = SIMD4(x,y,z,1)` → `MATRIX_IDENTITY_FLOAT4X4` + `matrix.columns[3] = Float4::new(..)`，helper `translated(x,y,z)` 复现平移矩阵；③ 带 clamp 的 Swift struct init 不能逐字段构造：`ParticleEmitterFrameStats` 走 `frame_stats(|stats| …)`（从 `default()` 填字段）、`ParticleSubEmitter` 走 `sub_emitter(|rule| …)`、`ParticleSimulationEventApplyReport(...)` 走 `empty()` 再赋值；`Particle` 的 memberwise 默认参数（sizeScale/rotation/angularVelocity/size/color/generation/appearanceIndex/textureFrameSeed）在 Rust `Particle::new` 展开为 12 个显式实参；④ `ParticleEmitter::apply` 消耗所有权，测试里对需复用配置的用例先 `stack.clone()`；⑤ `ParticleFrameStatsResource` 的 `live_particle_budget_utilization`/`spawn_budget_utilization`/`dropped_spawn_count` 是**方法**（`live_particle_budget_limit` 才是字段），`ParticleEmitterFrameStats` 上同名亦为方法；⑥ `aggregate_stats(vec![…])` 用 `ParticleFrameStatsResource::new(0.0, stats, BTreeMap::new(), 0,0,0,0,0,0)`，聚合字段由 `new` 内计算；`apply_particle_simulation_events(&BTreeMap<EntityID, Vec<…>>)` 返回按实体聚合的报告；⑦ `SceneRuntime::tick(delta_time, frame_index, input_events)` 在本文件固定 `0, Vec::new()`；`SceneRuntime::resource` 返回克隆，改后须 `set_resource` 回写；⑧ `ParticleAdvanceOptions::new(4 参)` 与 `ParticleScalabilityPolicyResource::new(6 参)` 的顺序按 Swift 声明逐一对应，`updated_state(&stats, state)` 的 `previousState` 默认值由 `Default`（`applied_scale=1/pressure=0/reason=None`）提供 |
| 2026-11-01 | 批次 57 | diffuse-scene 测试（`Physics/ComponentEditingTests`） | 1 | 85 | `Engine/Tests/SceneRuntimeTests/Physics/ComponentEditingTests.swift` → `crates/diffuse-scene/src/tests/scene_runtime/physics/component_editing_tests.rs`，352 行、3 个 `#[test]`（`ccd_quality`/`cloth_indices`/`mesh_input`），与 Swift 3 个用例 1:1；`rustfmt --edition 2024 --check` 退出 0。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 57 语义记录 | — | — | — | ① Swift `SceneRuntime()` → `SceneRuntime::new(ComponentRegistry::built_in())`，`scene.setComponent(RigidBody(), for:)` → `RigidBody::default()`（`RigidBody::new(RigidBodyOptions::default())`）；② `setComponentData(_:typeID:for:mode:)` 的 `mode` 默认值是 `.replace`（Swift 声明处确认），所以 `meshInput` 里省略 mode 的调用在 Rust 侧显式写 `ComponentWriteMode::Replace`，其余为 `Merge`；③ `#expect(throws: ComponentEditError.invalidValue(t))` → helper `expect_invalid_value`，断言 `error.edit_error().cloned() == Some(ComponentEditError::InvalidValue(t))`（`set_component_data` 返回 `ComponentEditFailure`，`Edit` 变体透传 `ComponentEditError`）；④ Swift `Cloth(gridSizeX: 3, gridSizeZ: 2)` 的默认参数展开为 `Cloth::new(3, 2, 0.2, Vec::new(), 1.0e-5, 1.0e-5, 1.0e-5, ClothBendType::Distance)`，`SoftBodyMesh()` → `SoftBodyMesh::default()`；⑤ `.array([0, 5, 2, -1, 5, 999].map { .number(Double($0)) })` → helper `integer_array`（`ComponentValue::Number(f64)`），对象字面量 → helper `object`；⑥ `SceneSerializer.serialize(scene)` → `SceneSerializer::serialize(scene.world())`，`deserialize(encoded, into: &restored)` → `SceneSerializer::deserialize(&encoded, restored.world_mut())`；⑦ `componentData(...)?.value(at: ["resourceID"])` → `component_data(...).and_then(|v| v.value_at(&[..]).cloned())`（Rust 的 `value_at` 返回借用，需 `cloned()`）；⑧ 已验证生产侧语义与该测试一致：`merge_rigid_body` 仅在 CCD 标志真正变化且同一文档未显式给 `motionQuality` 时改写画质，`normalize_cloth_changes` / `normalize_soft_body_mesh_changes` 在数组按下标 patch 后重新校验并按新拓扑裁剪索引，`serialize_soft_body_mesh` 在 `resource_id == None` 时**省略** `resourceID` 键（因此断言 `value_at` 为 `None` 而非 `Null`） |
| 2026-11-01 | 批次 58 | diffuse-scene 测试（`PhysicsBackendSelectionTests`） | 1 | 874 | `Engine/Tests/SceneRuntimeTests/PhysicsBackendSelectionTests.swift` → `crates/diffuse-scene/src/tests/scene_runtime/physics_backend_selection_tests.rs`，1176 行、15 个 `#[test]`，与 Swift 15 个用例 1:1（独占批次，>700 行）；`rustfmt --edition 2024 --check` 退出 0。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 58 语义记录 | — | — | — | ① Swift 的 `SelectionRecordingPhysicsBackend` 类改成 Rust 结构体 + `impl PhysicsBackend`，`prepareContexts` 改为 `Arc<Mutex<Vec<PhysicsPrepareContext>>>`：`set_physics_backend(Box<dyn PhysicsBackend>)` 会**移动**后端，只有共享队列才能在 tick 之后继续断言（Swift 是引用类型可直接读）；`reset()` 按 Swift 保持空实现并注释说明；② `SceneRuntime()` → `SceneRuntime::new(ComponentRegistry::built_in())`，`PhysicsSettingsResource(...)` 的成员默认值（`allowSleep: true`、`collisionSteps: 1`）由 helper `play_settings(backend_kind, gravity, allow_sleep)` 展开，CCD 用例用结构体更新 `PhysicsSettingsResource { collision_steps: 2, ..play_settings(...) }`；③ `RigidBody(motionType:mass:linearVelocity:angularVelocity:gravityScale:linearDamping:angularDamping:allowSleep:isSleeping:)` 统一走 helper `rigid_body(...)` 返回 `RigidBodyOptions`，个别差异（`gravity_scale`、`is_sleeping`、`continuous_collision_detection`）用结构体更新叠加，再交给 `RigidBody::new`（`init` 里「CCD 开 → 强制 linearCast」的规则由此生效）；④ `Collider(shape:material:)` → `Collider::with_shape(...)` 后写 `material = PhysicsMaterial::new(0.9, 0.25, 2.0)`；⑤ `Constraint(...)` 是 `PhysicsJoint` 的类型别名，测试走兼容构造器 `PhysicsJoint::from_kind(kind, a, b, pivotA, pivotB, axisA, axisB, min, max, isEnabled, breakForce, breakTorque)`，helper `constraint(...)` 填 Swift 的默认值（pivot 零、axis `(0,1,0)`、`isEnabled = true`、断裂阈值 `DEFAULT_BREAK_LIMIT`）；⑥ `applyLinearImpulse/applyAngularImpulse/applyForce/applyTorque` 在 Rust 多一个 `wake: bool` 参数，Swift 的默认 `wake: true` 显式传入；⑦ `report.physics.writebackCount` → `report.physics.writeback_count`（`usize`），`runtime.physicsFrameState` → `physics_frame_state()`，`physicsContactFrame.began + .stayed` 用 `chain(...).copied()`，`.events` 是方法 `events()`；⑧ 旋转断言用 `Quatf::from_angle_axis` / `Quatf::from_float4x4` 与 `simd_dot4(quat.vector, ...)`（Swift 的 `simd_dot` 对 `simd_quatf.vector` 即 Float4） |
| 2026-11-01 | 批次 59 | diffuse-scene 测试（3 个文件） | 3 | 373 | `PhysicsJointTests.swift` → `physics_joint_tests.rs`（268 行、4 个 `#[test]`，Swift 3 个用例里的 `@Test(arguments:)` 拆成 cone/sixDOF 两个）、`PrefabTests.swift` → `prefab_tests.rs`（181 行、5 个 `#[test]`）、`RagdollTests.swift` → `ragdoll_tests.rs`（219 行、2 个 `#[test]`），用例数 1:1；三个文件 `rustfmt --edition 2024 --check` 退出 0。**按用户要求未运行 cargo 门禁**，只跑 `inventory.py --check` |
| 2026-11-01 | 批次 59 语义记录 | — | — | — | ① `PhysicsJoint(configuration:entityA:entityB:)` 走 `PhysicsJoint::new(configuration, a, b, pivot 零, pivot 零, true, DEFAULT_BREAK_LIMIT, DEFAULT_BREAK_LIMIT)`（Swift 成员默认值），helper `joint_at` 封装；`.point`/`.distance(...)`/`.cone(...)`/`.sixDOF(...)` 用 `PhysicsJointConfiguration` 变体，`ConeJointConfiguration::new` 补 `twistAxisA/B = (1,0,0)`、`SixDofJointConfiguration::new` 补 `axisA/B = (1,0,0)` 与默认 `PhysicsJointSpring`；② `runtime.updateComponent(Collider.self) { $0.shape = ... }` → `update_component::<Collider>(entity, |c| c.set_shape(...))`（`Collider::shape` 是兼容读取器，写入用 `set_shape`）；③ `physicsFrameState.synchronization.constraints/bodies` → `physics_frame_state().synchronization.{constraints,bodies}`（`i64`），`report.physics.error == nil` → `report.physics.error.is_none()`；④ `for _ in 0..<30 where event == nil` 的 where 子句在 Rust 展开为循环体内 `if event.is_some() { break; }`，事件读 `physics_event_frame().joint_breaks.first().copied()`；⑤ `Prefab.capture(from:root:)` 的 Swift 入参是 `SceneRuntime`，Rust 是 `&RuntimeWorld`（`source.world()`），`instantiate(into:)` → `instantiate(target.world_mut(), parent, transform)`；Swift 裸 `tick()` 默认 `deltaTime: 0`，故 Rust 侧传 `tick(0.0, 0, Vec::new())`；⑥ `findEntity(named:)` → `find_entity_named`、`entities(with:)` → `entities_with::<C>()`、`snapshot.entityCount` → `snapshot().entity_count`、`localTransform(for:)` 的 `translation` 是方法 `translation()`；`Prefab(data:)` → `Prefab::new(prefab.data())`（`data()` 返回 `&str`）；⑦ `Ragdoll(mode:blendWeight:bones:)` → `Ragdoll::new(mode, weight, true, bones)`，`RagdollBoneMapping(...)` 完整参数走 `with_mapping(8 参)`；`setRagdollMode(_:for:blendWeight:)` → `set_ragdoll_mode(mode, entity, Option<f32>)`，Swift 丢弃返回值的调用在 Rust 同样 `let _ =`；⑧ `ragdollStateFrame.states[root]?.bones.first?.isSimulated` → helper `bone_is_simulated` 返回 `Option<bool>`（保持 Swift 的可选语义），`palettes[root]?.matrices[0].columns.3.x` → `columns[3].x`（Rust 存数组），`JointPaletteMap(palettes: [root: ...])` → `JointPaletteMap::new(BTreeMap::from([(root, ...)]))` |
| 2026-11-01 | 批次 60 | diffuse-assets 生产代码收尾 | 1 | 480 | `DestructibleAssetBaker` 全部 `written`，同时补 `AssetPipeline::validate_path` 与 crate 根导出；闭合性/体积校验、表面邻接、稳定连接 ID、连通图检查、资产资源替换均保留。按用户要求不编译、不测试；仅格式化和迁移清单检查 |
| 2026-11-01 | 批次 61 | diffuse-script 组件与 registry codec | 2 | 172 | `ScriptComponent`、`ComponentRegistryScriptCodec` 全部 `written`；绑定 UUID 显式小写落盘，持久化与事务句柄分离；SceneRuntime 的默认工厂支持捕获每个 registry 的脚本默认标识符。复用 workspace 现有 serde/serde_json，未新增第三方 crate；按用户要求不测试 |
| 2026-11-01 | 批次 62 | diffuse-intent 能力声明与调用规划 | 2 | 695 | `CoveCapability`、`CapabilityInvocationPlanning` 全部 `written`；统一 Cove schema 校验与严格输入声明，完整版本/hash/access/source/plugin authority 校验，保留前置条件、歧义打分、警告与 approval 升级；补齐 `capabilityDenied` 变体。按用户要求不编译、不测试 |
| 2026-11-01 | 批次 63 | diffuse-intent 变换/灯光/相机/材质能力 | 2 | 877 | `BuiltInTypedCapabilities` + `BuiltInCameraMaterialCapabilities` 全部 `written`，对应 15 个能力；保留旋转结合顺序、退化轴回退、聚光灯先 outer 后 inner、材质纹理绑定和省略字段；目录声明完整注册 36 个能力。按用户要求不测试 |
| 2026-11-01 | 批次 64 | diffuse-intent 物理能力 | 1 | 525 | `BuiltInPhysicsCapabilities` 全部 `written`，11 个能力；保留同类 collider 的原尺寸与中心、异类形状默认值、局部字段更新、构造后经 registry codec 写出。按用户要求不测试 |
| 2026-11-01 | 批次 65 | diffuse-intent 场景/媒体/脚本能力 | 1 | 683 | `BuiltInSceneUtilityCapabilities` 全部 `written`，10 个能力；保留 spawn 默认值、父子关系限制、有界脚本值、绑定 ID/句柄替换、参数 sorted JSON、音频和动画缺省行为。36 个能力均已有真实准备逻辑；按用户要求不测试 |
| 2026-11-01 | 批次 66 | diffuse-intent 提交策略与暂存 | 2 | 315 | `CommitPipeline`、`StagedTransactionStore` 全部 `written`；按 Swift 顺序运行策略、保留错误类型、锁外发布生命周期事件；同时修复历史 `written` 文件缺失的组件变更构造与精确后置条件生成。事务执行器和协调器保持 `pending`；本轮不编译、不测试 |
| 2026-11-01 | 批次 67 | diffuse-intent `TransactionExecutor` | 1 | 1073 | 独占批次，完整 `written`：值快照预览、scene/sequence/asset 按域应用、revision 校验、归一化后置条件重放、失败回滚、outbox 与细粒度 WorldEvent 投影；创建/删除/复制/重排及所有组件变更分支保留。按用户要求不编译、不测试 |
| 2026-11-01 | 批次 68 | diffuse-intent `IntentRuntimeCoordinator` | 1 | 471 | 完整 `written`：入口策略注册/撤销、自动应用与暂存、两轮破坏性确认、确认前状态与授权重校验、严格答案校验、撤销/重做、确认事件 payload。22 个生产文件全部 `written`，测试文件仍 `pending`；不编译、不测试 |
| 2026-11-01 | 批次 69 | 场景快照依赖与历史接线修复 | 8 | — | `SceneRuntime`/schedule 支持忠实值复制；backend/driver/query cache 使用共享引用；修正显式 backend 被忽略及 simulation/query 实例分离；补 39 个 `failure_description` 分支。`JobSystem` 新增 Clone 后从 `tested` 退回 `written`，没有以新建 schedule 或空后端替代副本；只做格式化、静态源代码对照与清单检查 |
| 2026-11-01 | 批次 70 | diffuse-script 核心与输入锚点 | 6 | 875 | `ScriptBehavior`、`ScriptContext`、`ScriptDefinition`、`ScriptLifecycle`、默认输入映射和输入处理完整 `written`；保留参数合并/校验、完整组件与资源操作、prefab 实例化、触发器及物理查询。先补依赖锚点；按用户要求不翻译或运行测试、不编译 |
| 2026-11-01 | 批次 71 | diffuse-script 控制器、动画与预设 | 8 | 838 | 三个控制器、三个预设文件和两个序列化/调试扩展完整 `written`；保留图状态优先级、过渡时钟、1D 混合、关键帧区间/四元数插值、首个 skin 的关节调色板、输入失焦释放、相机同步及角色落地边沿。只格式化和静态源码对照 |
| 2026-11-01 | 批次 72 | diffuse-script `ScriptRuntime` | 1 | 337 | 完整 `written`：稳定名称/句柄、代次热替换、每绑定状态工厂、旧参数销毁、暂停保留实例且继续动画、结束会话有序销毁、输入与 canvas 帧资源；动态脚本六个文件仍 `pending`，本轮没有测试或编译 |
| 2026-11-01 | 批次 73 | 脚本 SDK 与上游缺口修复 | — | — | 补 SDK 属性元数据、字符串选项、Swift 关联枚举编码、严格 JSON 数字/代理项与完整 UInt64；补 `AssetRegistry::shared`、phase registry setter、WorldTransform 通用读取刷新及共享物理查询接线。AssetRegistry 从 `tested` 回退 `written`；SDK 修订不沿用历史测试结论 |
| 2026-11-01 | 批次 74 | diffuse-script D1 编译器 | 1 | 616 | `SwiftScriptCompiler.swift` → `ScriptCompiler` 完整改写为 `written`：Cargo release/JSON 消息、项目缓存、清晰诊断、准确 cdylib 选择、独立代次原子发布、取消注册竞态与 250 ms 终止升级、双管道并发读取和可选截止时间；Swift modulemap、动态符号链接与 Windows 导入库流程由 D1 的 std-only SDK 依赖替代。没有运行 Cargo、测试或编译 |
| 2026-11-01 | 批次 75 | diffuse-script 时间、输入、角色桥接与 SDK 修复 | 3 | 105 | 三个小桥接文件完整 `written`；新增调用期间有效的线程上下文、独占借用保护、宿主字节分配/释放和错误状态资源作为接线锚点。SDK 宏生成全部 C 导出、修正创建符号、捕获 panic 后停用、可选 authoring 选择及空字符串保留；目录使用宿主分配器，ABI 提升为 2。通用上下文桥接和加载器仍 `pending`，没有以空函数表宣称 D1 完成 |
| 2026-11-04 | 批次 76 | diffuse-render Core 帧/光照/网格/粒子（队友） | 25 | 2164 | RenderBackend/Core 的 25 个生产文件全部 `written`（frame 5、lighting 7、mesh 6、particles 5、render_stats、render_temporal_state）；GPU 布局断言 23 组（SceneLightUniforms 544、ShadowUniforms 384、EditorGridUniforms 192、MeshInstanceUniforms 160、GPUParticleSimulationUniforms 272、GPUParticleSimulationInstanceUniforms 240 等，均与 .slang 结构一致）；OpaqueSceneFingerprint 以固定 FNV 累加器替代 Swift 进程内 Hasher。按用户要求不编译不测试，仅 rustfmt 与 `inventory.py --check`（0 problem(s)） |
| 2026-11-04 | 批次 77 | Cove 路径与脚本加载器修正 | 0 完成 | — | workspace 的 Cove 依赖切到当前 `crates/` 目录；脚本实例回调加互斥、修正 Windows API 声明与符号指针转换，释放零长度目录缓冲区。加载器仍有多脚本选择、失败报告及 HostApi 接线缺口，清单退回 `pending`；没有将部分实现标为完成。 |
| 2026-11-04 | 批次 78 | Natsel G8 与 D1 加载器/通用桥接 | 1 完成 + 1 部分 | 154 + 30 | 用户授权下在 Natsel 补 `World: Send`、短借用角色世界句柄、`from_raw_world` 和 `world_mut`；修正 Diffuse 的多角色安全注释，并补 §2.2 的 Natsel release 溢出设置。加载器完整 `written`：先验 ABI 校验、目录严格校验、显式多脚本选择、可失败工厂、代次/元数据同锁替换。通用桥接新增 29 项（实体/层级/矩阵/参数/Prefab/画布/状态），其余待续，仍 `pending`。只做 Rust 格式化与静态检查，未运行 Cargo/测试。 |

## 10. 已知问题与需要用户确认的事项

- **2026-11-04 批次 78**：Natsel G8 的实现已按用户本轮授权补齐，见 [G8](.migration/cove-gaps.md)，尚未编译或测试。未修改 Cove，未新增第三方依赖。Natsel changelog 与迁移记录同步更新；本次没有发布新版本。
- **D1 通用桥接仍未完成**：实体、层级、完整 64 字节矩阵、参数、Prefab、画布与状态条目已接线；组件/资源、输入与触发帧、完整角色状态、车辆命令、五种物理查询条目待续，文件继续 `pending`。空名称和未提供名称、空字符串和缺失参数、实体 0 和缺失实体均用显式存在标志区分。加载器现已完整 `written`，不代表整个 D1 管线完成；其可失败工厂签名在 §8 登记，后续编辑器调用方必须传播错误。
- **2026-11-04 批次 77 历史检查**：Cove 已重排目录，workspace 依赖路径已更新并静态核对 19 个包名。该批次误试一次 `cargo check --workspace`，在旧 Cove 路径解析阶段失败，未开始编译；此后继续遵守此前不运行 Cargo/测试的迁移要求。

- **2026-11-01 批次 74–75**：新增 4 个生产文件为 `written`。未执行新编译器、Cargo、测试或动态库加载；仅格式化、静态源码对照及清单检查。`script_c_bridge_context.rs` 当前只是接线锚点，实体/变换/组件/资源/参数/物理查询等完整 HostApi 条目与加载器仍未落地，对应两行继续 `pending`。
- SDK ABI 2 目录入口明确为 `diffuse_script_catalog(host)`，以满足 D1 的“宿主分配、宿主释放”要求；不再泄漏脚本 Vec 或跨 DLL 释放脚本分配。所有生命周期与创建/销毁中的 panic 均隔离上报，实例随后停用；HostApi 生命周期必须覆盖 SDK 实例析构，后续加载器须持有该宿主句柄至最终 destroy 返回。现有 SDK 测试未修改或运行，历史验证结论不适用于这些 API 变动。
- `diffuse-script` 复用 workspace 已有 thiserror 表达编译错误，没有新增第三方 crate。SDK 继续 std-only；Color4 用 repr(C) 结构体传色值，避免裸数组作为 C 函数值参数，并补齐 ABI 类型的布局断言。
- Cove `NativeProcess` 的提前清 running 标志及退出监视线程错误丢失登记为 [G9](.migration/cove-gaps.md)；没有修改 Cove/Natsel。
- HostApi 尚待补齐的变换接口需保留 LocalTransform 的完整矩阵，不能用当前 SDK 的 TRS 48 字节表达丢掉 shear；实体 0、空名称与“未提供名称”、移除时返回旧组件/资源等边界也必须在通用桥接批次逐一保留。ABI 表布局再次变化时继续提升版本，不能静默复用旧布局。

- **2026-11-01 批次 70–73**：15 个脚本生产文件新增为 `written`；动态编译器、加载器与 HostApi 桥接六文件仍为 `pending`，未宣称 D1 管线已完成。SDK 本轮修订后没有编译或测试；保留现有测试源码，不修改断言以适应 API。后续 D1 批次仍须补全 HostApi 覆盖、panic 停用/报告与导出缓冲区所有权。
- `diffuse-script` 的 `diffuse-assets` 从开发依赖提升为生产依赖，对应 Swift ScriptRuntime 对 AssetPipeline 的现有依赖；补回规定的 `cove-system` 依赖。使用 workspace 已有的 `unicode-segmentation` 保持调试状态截断的字形簇语义，没有新增第三方 crate。
- Swift 可在泛型注册中动态查询独立的 `ScriptAuthoring` 元类型；Rust 不支持该转换，原生行为采用 `register_behavior` / `register_authoring_behavior` 两个入口，后续有 authoring 的调用点必须选后者。生命周期共享可变状态由 Mutex 串行访问，回调获得独占 `&mut ScriptContext`。

- **2026-11-01 批次 67–69**：事务执行器/协调器已完成生产翻译，补齐既有状态断言的判定逻辑；场景复制所需的共享引用接线和显式物理 backend 偏差也已按 Swift 修正。本轮不运行编译、测试或基准，相关运行表现尚未验证；没有修改 Cove/Natsel，也没有新增第三方依赖。

- **2026-11-01 当前用户要求：迁移不进行测试工作。** 本轮只迁移生产代码，运行 Rust 格式化与 `inventory.py --check` 静态清单检查，不运行 Swift/Rust 测试、cargo check/clippy 或运行时验证；新增完成行仅标 `written`，不提升为 `compiled`/`tested`。已有测试文件改动保留，未作为本轮工作继续扩展。
- `diffuse-script` 把 workspace 中已有的 `serde`/`serde_json` 用于脚本绑定编码；`serde_json` 从该 crate 的 dev-dependency 提升为生产依赖，没有新增第三方 crate。
- 本轮发现并补齐历史 `written` 的遗漏：`MutationComponents` 的两个构造方法、`SceneStateVerification` 的验证键/失效键/精确后置条件。迁移清单的存在性检查不会发现这类语义缺口，后续翻译仍需逐段对照源文件。

- G6（`cove-agent`）已由 Cove 落地（`../Cove/Agent`），`diffuse-capability` 已切换；G4（`cove-http`，`../Cove/Http`）也已落地，workspace 已声明依赖，HTTP 调用点可以过编译门禁。
- 感知（PerceptionRuntime）在 Swift 版中只有 Apple Vision 实现，其他平台没有 worker；按 2.3 保留并报告，不伪造实现。
- **Swift `JSONEncoder` 的键序（实测 Swift 6.4.1，≥3 键 + 独立进程）**：
  - 带 `.sortedKeys`：**总是按字母序**，跨进程稳定，与 `CodingKeys` 的声明顺序无关。5 次独立进程运行输出完全一致。
  - 不带 `.sortedKeys`：**每进程随机**。5 次独立运行得到 5 种不同顺序；且**显式 `CodingKeys` 与合成 `CodingKeys` 一样被随机化**——声明 `CodingKeys` 完全不能稳定顺序。
  - 结论：字节一致**只**对 `.sortedKeys` 写出器有定义；默认格式化的写出器**没有任何稳定字节目标**（既不是声明顺序也不是字母序），不要尝试复现，也不要假设任何顺序。所有落盘格式测试必须显式声明 `.sortedKeys`。
  - **记录两次误判**（同一个陷阱，两个方向）：先有人用「`maxBodies` 恰好字母序在前」推出「声明顺序」；我随后用 2 键结构验证并「证伪」为「显式 `CodingKeys` 用声明顺序」——2 键只有 2 种排列，单进程内种子稳定，于是两种解释都能自洽。**不要用 <3 键或单进程的样例推断序列化规则。**
- 无 macOS 之外的平台上无法执行的分支（例如 `diffuse-documents` 的非 macOS 归档路径）按 §2.3 保留完整 `#[cfg]` 实现；只在本机可执行的分支上跑过测试，其余需在对应平台复核。
- **阶段 0 脚手架的占位入口**：下列文件目前只有可编译的最小 `fn main() {}`，其 Swift 源仍在清单里是 `pending`，翻译时必须整体替换，不能保留空体：`crates/diffuse-editor/src/main.rs`（`Editor/Sources/EditorApp/main.swift`）、`crates/diffuse-player/src/main.rs`（`CovePlayer/main.swift`）、`crates/diffuse-export/src/main.rs`（`CoveProjectExport/main.swift`）、`crates/diffuse-plugin-host/src/main.rs`、`crates/diffuse-mcp/src/main.rs`、`crates/diffuse-render-validation/src/bin/native_rhi_pass_probe.rs`、`crates/diffuse-editor-core/src/bin/language_server_fixture.rs`。三个 bench 入口已不再属于占位：`diffuse-scene/benches/{scene_runtime,physics_runtime}.rs` 在批次 52 完成（`harness = false`，场景/预算/打印行与 Swift 对齐），`diffuse-render-validation/benches/render_backend.rs` 见该 crate 的批次日志。
- **Swift `JSONEncoder` 的浮点文本格式与 serde_json 不同（已实测 Swift 6.4.1）**：`100.0` 写 `100`、`1e20` 写 `1e+20`、`1e-7` 写 `1e-07`、`-0.0` 写 `-0`；serde_json 分别写 `100.0`、`1e20`、`1e-7`、`-0.0`。因此 `#[derive(Serialize)]` 的浮点**不能**与 Swift Codable 逐字节一致。凡是落盘格式含浮点（场景、组件注册表、序列、插件清单）都必须走 Swift 兼容的格式化器，并在 §5.4 的黄金文件往返测试里逐字节校验。
  - 科学计数法的上界**按宽度不同**：`Double` 在十进制指数 `>= 16` 转科学计数（`1e15`→`1000000000000000`，`1e16`→`1e+16`）；`Float` 在 `>= 8` 就转（`1e7`→`10000000`，`1e8`→`1e+08`）。两者下界相同：`1e-4`→`0.0001`，`1e-5`→`1e-05`。
  - 已落地：`diffuse_kernel::codable::{format_double, format_float, serialize_double, serialize_float}`（标量文本）；`diffuse_assets::swift_json::{to_sorted_pretty, to_compact}`（整份文档的 pretty/紧凑写出，含 Swift 的空数组 `[\n\n  ]` 布局、`\/` 转义与按 UTF-8 code unit 排序）。整份文档落盘用后者，单字段走前者。
- **「部分翻译」的行必须留在 `pending`**：早期批次的 `RuntimeWorld.swift`、`RenderScene.swift`、`Registry.swift`、`Inspection.swift`、`AssetPipeline.swift` 曾只落了「闭包前缀」（前缀里不引用 `RuntimeWorld` 的那部分类型）。按 §5.7，这类中间态不能标 `written`；完成状态以当前逐文件清单及后续批次日志为准，仍未完成的行须在 `notes` 里写明缺口。判断一个文件是否真的完成，用内容审计而不是看行数：脚手架占位的 `fn main() {}`、只有 `mod x;` 声明的入口、以及只含声明的前缀文件都不算完成。
- **`cargo clippy --workspace --all-targets -- -D warnings` 目前在 `xtask/src/support/` 报 80 个 dead-code 类错误**。这是预期的中间态：`xtask/src/support/` 是 G1 从 Cove `703fb10c:Tools/Support/rust/` 原样恢复的代码，而它的调用方（`xtask` 本身的 133 个文件）还没翻译，所以这些函数暂时没有使用者。批次 `xtask` 完成后这些错误自然消失。**不许**用 `#[allow(dead_code)]` 掩盖（§5.7）——正确处理是翻译 `xtask` 的实现，让这些函数被真正调用。
- **`RuntimeWorld` 不依赖物理后端**（已用 grep 核实）：`RuntimeWorld.swift` 里没有任何 `Natsel`、`makeBackend` 或 `PhysicsBackend`（trait）引用；`makeBackend()` 只在 `Scheduling/PhysicsCollection.swift`、`Scheduling/WorldSchedule.swift` 和它自己的定义处出现。`RuntimeWorld` 只把 `PhysicsSettingsResource.backend_kind` 当普通字段读，所以 `PhysicsBackendKind` 只需要那 16 行的数据枚举（`none`/`natsel` + `preferred`）。**结论：`RuntimeWorld` 与 `SceneRuntime` 可以先于 1,244 行的 Natsel 适配器落地**，四个下游 crate（audio/intent/render/render-validation）的解锁不必等后端。若某批次为 `make_backend()` 的 `natsel` 分支临时返回 `Null`，那是一次行为改变，必须在本节点名。
- **§5.3 的布局断言只加在真正跨 GPU 边界的类型上**。`Vec` 承载的数据结构不要加 `size_of`/`align_of` 断言——尺寸对它们没有意义。需要断言的是被逐字节上传的类型：uniform 块、顶点流、粒子 GPU 计划。`diffuse-render::core::frame::render_uniforms` 已按此加断言（实测 Swift：`SkyboxUniforms` = 112 字节、`SsaoUniforms` = 160、`SsrUniforms` = 160、`StylizedCharacterUniforms` = 64、`PostFrameUniforms` = 16，均 16 对齐）。我第一版把 `SkyboxUniforms` 猜成 128 字节，被编译期断言拦下——这正是断言存在的意义：把错误猜测变成编译错误，而不是渲染时的静默错位。
- **`inventory.py --check` 按字面量 grep `todo!`/`unimplemented!`，因此连注释里提到也会被判违规**。这是刻意保持「笨」的检查器：任何试图区分「散文里提到」与「真的用了」的逻辑都可被绕过。**不要在注释里写 `todo!()`**，解释为什么没写桩时用「未完成的桩体」这类措辞。已有一次真实误报（`physics_backend_kind.rs` 的文档注释）。
- **中间态的 workspace 红是正常的，但不要当成已完成**：一个批次写到一半时（例如 `components/core/registry.rs` 已定义 `ComponentRegistry`、却引用了尚未存在的 `RuntimeWorld`），`cargo check --workspace` 会红。这不是缺陷，也不允许用临时桩让它变绿。判断标准始终是「最后一次报告的四个门禁是否全部通过」，并且报告的那次运行必须晚于最后一次编辑。
- **`SceneRuntime` 的顺序修正**：Swift 的 `SceneRuntime` 结构体持有 `RuntimeWorldSchedule` 字段（`schedule` 在 10+ 处被调用），而 `RuntimeWorldSchedule` 又拉入整个 `scheduling/` 树并调用 `make_backend()`。所以实际顺序是 `scheduling/` → `SceneRuntime`，不是反过来。**不要写一个省掉 `schedule` 字段的「薄 `SceneRuntime`」**——那偏离 Swift 的结构形状；需要 `RuntimeWorld` 级查询的下游 crate（如 `diffuse-audio`）直接适配 `RuntimeWorld` 即可，已经这么做并通过 3 个集成测试。
- **Natsel 适配器（1,244 行，8 个文件）在 `scheduling/` 之前**：`make_backend()` 的 `.natsel` 分支必须有真实实现，不允许静默回退到 `Null`。这 8 个文件只 import `Foundation`/`SIMDCompat`，不依赖 `SceneRuntime`，所以可以提前落地。
- **`diffuse-plugin` 对插件自带语法模式的校验是 fail-closed 的**：`cove.language/v1` 的 `grammar.rules[].pattern` 与 `outline.rules[].pattern` 由 `crates/diffuse-plugin/src/pattern.rs` 的 `plugin_pattern` 匹配。支持：字面量、`.`、转义字面量、字符类（含区间与取反）、捕获组与 `(?:`、分支、`*`/`+`/`?`/`{n}`/`{n,}`/`{n,m}`（含惰性与占有后缀）、`^`/`$`。**超出该子集的构造在声明期被拒绝**（`NSRegularExpression` 本会接受），失败方向永远是「拒绝插件声明」，绝不会「接受非法插件」；只影响插件自带的语法模式，不影响用户数据或落盘状态。捕获组计数按 ICU 规则：仅对 `(` 且其后不是 `?` 的组递增，每个 `(` 压栈、`)` 出栈，歧义构造直接报错而不是猜测，因此不会少计。
- **UUID 生成曾有一个 34 字符的缺陷，已在 `diffuse-kernel::codable::new_uuid` 统一修正**。原实现把 node 写成两个字段 `{node_a:04X}{node_b:06X}`，当掩码后的 node 值较小时 `{node_b:06X}` 不足 6 位，导致长度变成 34 而不是 Swift `UUID().uuidString` 的 **36**（8-4-4-4-12），`Uuid::parse` 会正确拒绝。该实现被**复制到了 5 个 crate**（capability/sequence/observation/documents/media），所以缺陷一起扩散。现在 `diffuse-kernel::codable::new_uuid` 是规范实现（`{node:012X}`），每个 crate 都带一条断言长度 36 与分组 `[8,4,4,4,12]` 的测试。**教训：这类「小工具函数」也必须有测试，否则复制时会连同缺陷一起传播。**
- **G8（Natsel）：已在上游修好**（用户授权修改 Natsel）。`CharacterVirtual<'w>` 原本持有 `&'w mut World`，无法被同样持有 `World` 的对象持久存储；Swift 的 `characters: [EntityID: CharacterRecord]` 正是这种形状。Natsel 侧新增两处纯增量改动（`cargo test` 530 → 532，行为不变）：`unsafe impl Send for World {}`（`src/simulation/world_runtime.rs`，带完整 `// SAFETY:` 论证，且刻意**不**实现 `Sync`），以及 `CharacterVirtual::from_raw_world(world: *mut World, def)` + `world_mut()`（`src/character/character_virtual.rs`，文档写明调用方三项义务）。Diffuse 因此从「两处 `unsafe` 块」降为「一处可审计的 `unsafe` 调用」。
- **`RuntimeWorld::local_transform` 对活着的实体永不返回 `None`**：缺失的 `LocalTransform` 组件会被读成 `LocalTransform::IDENTITY`（Swift 同名方法的行为），只有实体不存在时才返回 `None`。因此「没有 transform 的实体会被物理收集跳过」是错的——判据只能是「既无 `RigidBody` 也无 `Collider`」。这个语义容易误判，写测试时尤其当心。
- **`WorldTransform` 只有传播后才反映 `LocalTransform`**：`RuntimeWorld::world_transform` 对活着的实体返回存储的 `WorldTransform`（缺失则为 `IDENTITY`），它**不会**自动从 `LocalTransform` 推导。任何读取世界空间的代码（空间索引、调试帧、物理快照）都必须先 `propagate_transforms`，调度器在 `hierarchyPropagate` 和写回后各做一次，测试也必须显式调用。这个坑会静默给出 identity 变换，不报错。
- Cove 侧问题见 [.migration/cove-gaps.md](.migration/cove-gaps.md)。
