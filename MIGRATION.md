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
| CoveUIAgentCore、CoveUIAgent（传输）、CoveUIInspection 的工具注册表与 skill | `cove-agent`（G6，待 Cove 抽出；抽出前对应路径是 `cove_devtools::agent`） |
| CoveUIDevTools、CoveUIInspection 的 UI 处理器 | `cove-devtools`（`inspection`、`server`） |
| URLSession（HTTP 客户端） | `cove-http`（G4，待 Cove 新建） |
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
- 导出宏 `diffuse_scripts!(GameScript, OtherScript)` 生成：`diffuse_script_abi_version() -> u32`、`diffuse_script_catalog()`（JSON：名字 + `ScriptDefinition`）、`diffuse_script_create(name, host) -> *mut c_void`、四个生命周期入口、`diffuse_script_destroy`。每个入口用 `catch_unwind` 包住，panic 转成脚本错误上报并停用该脚本实例，绝不跨 FFI 展开。
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

URLSession 的调用点（AIRuntime `Session.swift`、PluginRuntime `Network/Transfers.swift`、工具链下载、Tools/Developer 的验证工具）改用 Cove 的通用 HTTP 客户端 `cove-http`。它由 Cove 新建（G4）：Apple 用 Foundation，Windows 用 WinHTTP，**Linux 与 Android 用 OpenSSL**，TLS 部分是 C（AGENTS.md：性能与平台关键路径用 C）。Diffuse 不自带 HTTP 栈；在 G4 落地之前按 G4 里写定的 API 翻译调用点，相关 crate 的编译门禁等待 G4。

### MCP 与 agent 层（2026-10-31 定）

Swift 版中 Diffuse 已经复用 Cove 的公共层：`CapabilityRuntime` 以 `@_exported import CoveUIAgentCore` 重新导出工具 schema，`DiffuseMCP` 就是 Cove 的 `MCPServer` 加一个到编辑器的 TCP 转发，编辑器侧的 MCP 桥接用 Cove 的本地传输。迁移后保持这一边界：

- Cove 把 agent 层抽成独立的、不依赖 UI 栈的 `cove-agent`（G6），并恢复 Swift 版的动态工具列表（`listChanged`）与可跨线程的执行器。
- Diffuse 里 **不写任何 JSON-RPC、MCP 协议或 JSON Schema 校验代码**：`diffuse-capability` 重新导出 `cove_agent`；`diffuse-mcp` = `McpServer::with_provider` + `serve_stdio` + TCP 转发；`diffuse-editor-core` 的 `MCPIntegration` 用 `cove_agent` 的本地服务；`diffuse-ai` 的工具定义与 provider 格式用 `cove_agent::tool`。
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

- （阶段 0 后填写：`diffuse-math` 的向量/矩阵/四元数类型名与布局。）
- （`diffuse-scene` 锚点批次后填写：Scene/World/Entity/Component 根类型。）
- （`diffuse-editor-core` 锚点批次后填写：Store、编辑器状态、面板注册类型。）

## 9. 进度与批次日志

`python3 Tools/Migration/inventory.py --status` 输出各 crate 的计数；每个批次在下面追加一行：

| 日期 | 批次 | crate | 文件 | Swift 行 | 结果 |
|---|---|---|---|---:|---|

## 10. 已知问题与需要用户确认的事项

- G4（`cove-http`）与 G6（`cove-agent`）由 Cove 实现；落地前依赖它们的 crate 停在编译门禁前。
- 感知（PerceptionRuntime）在 Swift 版中只有 Apple Vision 实现，其他平台没有 worker；按 2.3 保留并报告，不伪造实现。
- Cove 侧问题见 [.migration/cove-gaps.md](.migration/cove-gaps.md)。
