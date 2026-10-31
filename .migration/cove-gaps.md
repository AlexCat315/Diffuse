# Cove gaps found by the Diffuse migration

Diffuse agents do not edit `../Cove`. Anything Diffuse needs from Cove that is missing or broken goes here, one entry per gap, so it can be handed to the Cove migration.

Format:

```
## G<n>: <one line>
- Needed by: <Diffuse crate / file>
- Cove today: <what exists, with the Cove path or type>
- Needed: <the API or fix, as a signature where possible>
- Diffuse meanwhile: <what the Diffuse code references or how it is blocked>
- Status: open | fixed in Cove <commit>
```

## G1: `cove-tool-support` (Tools/Support) was deleted with the Cove CLI
- Needed by: `xtask` (111 Swift imports of `ToolSupport` in Tools/Developer)
- Cove today: removed in `b325535b`; the Rust port is intact at `703fb10c:Tools/Support/rust/` (archive, concurrency, download, files, process_runner, process_signal, repository, sha256, shell, terminal, windows_build_environment)
- Needed: nothing from Cove; Diffuse owns this code now
- Diffuse meanwhile: phase 0 restores it as `xtask/src/support/`
- Status: open (resolved inside Diffuse)

## G2: Android host only accepts `Application`-mode content
- Needed by: `diffuse-android` (the Android game player)
- Cove today: `cove_hosts::android::install_application_content(fn() -> AnyView)`; `HostedScene` answers `SceneLaunchMode::Game` with "game content is hosted by Diffuse" (`Hosts/rust/android/sources/cove_android_app/content/scene.rs`)
- Needed: a way to install a `HostedSceneContent` for a launch mode, e.g. `install_scene_content(mode: SceneLaunchMode, factory: fn() -> Box<dyn HostedSceneContent>)`
- Diffuse meanwhile: translate `CoveAndroidApp` against that planned function and keep the crate `blocked` at `cargo check`
- Status: open

## G3: `cove-package` cannot bundle helper executables or extra resources
- Needed by: editor packaging (`DiffusePluginHost` ships beside the editor; `Editor/cove.json` `desktopHelpers`), player export, shader artifacts in `RenderBackend/Resources`
- Cove today: `Tools/Package` bundles one binary plus `Assets/` as `AppContent.resources`
- Needed: `[package.metadata.cove] helpers = ["diffuse-plugin-host"]` and additional resource directories
- Diffuse meanwhile: `cargo xtask package` wraps `cove_package` and copies helpers and resources itself
- Status: open

## G4: no general HTTP client; Linux has no TLS
- Needed by: `diffuse-ai` (model API calls: POST, headers, streamed responses), `diffuse-plugin` (`Network/Transfers.swift`), `diffuse-editor-core` (toolchain downloads), `xtask`
- Cove today: `cove_hosts::application_services::http` is a GET-only image downloader behind `cove_ui_compose::…::ImageDownloadTransport` (so it pulls in the UI stack); Foundation on Apple, WinHTTP on Windows, plain HTTP/1.1 over `std::net` on Linux with `https = false`
- Needed (decision D2: OpenSSL): a UI-free crate `cove-http`
  - `Client::new(ClientConfig { timeout, max_body_bytes, proxy })`, `client.send(Request { method, url, headers, body }) -> Result<Response, HttpError>`, `Response { status, headers, body_reader: Box<dyn Read + Send> }` so callers can stream
  - backends: Apple Foundation (`NSURLSession`, Objective-C/C bridge as today), Windows WinHTTP, **Linux and Android OpenSSL** through a small C binding (`native/tls.c`: `SSL_CTX` with system trust store, SNI, hostname verification, `SSL_read`/`SSL_write` over the existing socket code); Android links the NDK-built `libssl`/`libcrypto` already used by the Android package
  - the existing image transport becomes a thin adapter over `cove-http`
- Diffuse meanwhile: translate URLSession call sites against the API above; the gate for crates that call it waits on this gap
- Status: open

## G5: Cove's Rust tests have not all been run
- Needed by: every Diffuse crate
- Cove today: production code migrated, test migration and a full `cargo test` still in progress
- Needed: a green `cargo test --workspace` in Cove
- Diffuse meanwhile: when a Diffuse test fails inside a Cove call, reproduce it with a Cove-only snippet and file it here before changing Diffuse code
- Status: open

## G6: MCP/agent layer is not reusable outside the UI stack
- Needed by: `diffuse-capability` (re-exports the tool schemas, as Swift `CapabilityRuntime` re-exported `CoveUIAgentCore`), `diffuse-ai`, `diffuse-intent`, `diffuse-plugin`, `diffuse-mcp`, `diffuse-editor-core` (`Application/Bridge/MCPIntegration.swift`)
- Cove today: the Swift `CoveUIAgentCore` target depended only on `CoveFileSystem`. The Rust port folded it into `cove-devtools` (`agent/{schema,tool,skills,mcp}.rs`, `agent_transport.rs`, `inspection/tools.rs`), which depends on `cove-composition`, `cove-core` and `cove-graphics`. Those modules themselves use only serde/serde_json/std. Two behaviours of the Swift server are missing from the port:
  - Swift `MCPServer(name:version:skills:tools:execute:)` takes a **tool provider** re-read on every `tools/list` and advertises `"listChanged": true`; Rust `McpServer::new` takes a fixed `AgentToolbox`, and `tools_may_change` is never set
  - Swift executors are `@Sendable`; Rust `ToolExecutor` is `Rc<dyn Fn>`, so a toolbox cannot move to the stdio or TCP server thread
- Needed: a crate `cove-agent` (UI-free; deps serde, serde_json, thiserror) holding `schema`, `tool` (`AgentTool`, `AgentToolbox`, `AgentToolResult`, `AgentError`, `AgentSession`, provider formats), `skills`, `mcp` (`McpServer`), `transport` (`serve_stdio`, `AgentLocalServer`), and the UI diagnostic tool registry plus `ui-diagnostics` skill (`inspection/tools.rs` is pure data). `cove-devtools` depends on it and keeps `pub use cove_agent as agent;` plus the UI handlers. Restore the Swift behaviours:
  - `McpServer::with_provider(name, version, skills, tools: impl Fn() -> Result<Vec<AgentTool>, AgentError> + Send + Sync, execute: impl Fn(&str, &Value) -> Result<AgentToolResult, AgentError> + Send + Sync)` with `listChanged: true`
  - `ToolExecutor = Arc<dyn Fn(..) + Send + Sync>`
  - a notification writer so a server can emit `notifications/tools/list_changed` (DiffuseMCP sends it after a capability search)
- Diffuse meanwhile: use `cove_agent::…` paths everywhere; Diffuse defines no MCP or JSON-RPC code of its own
- Status: open
