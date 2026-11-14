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
- Cove today: `xtask/` (crate `cove-package`) still bundles one binary plus `Assets/` and `Platforms/<p>/Resources`; `bundle()`, `Cli`, `Command`, `Project` and `Target` are all private, only `main()`/`cargo_main()` are public
- Needed: `[package.metadata.cove] helpers = ["diffuse-plugin-host"]` and additional resource directories
- Diffuse meanwhile: batch 85 wired `cove-package` in as the thin forwarding layer (`xtask/src/main.rs`); the helpers/resources copy wrapper is still **not implemented**
- Status: partially wired (G3 itself still open)

## G4: no general HTTP client; Linux has no TLS
- Needed by: `diffuse-ai` (model API calls: POST, headers, streamed responses), `diffuse-plugin` (`Network/Transfers.swift`), `diffuse-editor-core` (toolchain downloads), `xtask`
- Cove today: `cove-http` (`../Cove/Http`), UI-free, deps `thiserror` only
  - `Client::new(ClientConfig { timeout, max_redirects, user_agent })`; `client.send(Request) -> Result<Response, HttpError>`; `Request::get/post/new(method, url).header(n, v).body(bytes)`
  - `Response { status, headers: Headers, url }` + `body() -> &mut dyn Read`, `into_body() -> Box<dyn Read + Send>`, `bytes(limit)`, `header(name)`, `is_success()`; a non-2xx status is a `Response`, not an error
  - `HttpError`: `UnsupportedUrl`, `InvalidRequest`, `Unavailable`, `Network`, `Tls`, `Timeout`, `InvalidResponse`, `TooManyRedirects`, `BodyTooLarge`
  - `Client::capabilities() -> Capabilities { http, https, limitation }`
  - backends: Apple `NSURLSession` (`native/apple.m`), Windows WinHTTP, Linux/Android/other Unix HTTP/1.1 + OpenSSL (`native/openssl.c`, `libssl` loaded at run time, 1.1.1–4.x, system trust store incl. Android `cacerts`). No proxy setting: Apple/Windows use the system proxy, the socket backend connects directly
  - Android: no system OpenSSL; `cargo xtask android-prepare` bundles `libssl.so`/`libcrypto.so` from `COVE_OPENSSL_ANDROID_DIR`, otherwise https reports unavailable
- Diffuse meanwhile: use `cove_http` directly
- Status: fixed in Cove (uncommitted working tree, 2026-10-31)

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
- Cove today: `cove-agent` (`../Cove/Agent`), deps serde/serde_json. Everything is re-exported at the crate root (`cove_agent::AgentToolbox`, `McpServer`, …); modules `transport` (`serve_stdio`, `serve_lines`, `LineWriter`, `AgentLocalServer`, `Handler`) and `ui_tools`
  - `McpServer::with_provider(name, version, skills, tools, execute)` advertises `listChanged: true` and re-reads the tools on every `tools/list`/`tools/call`
  - `ToolExecutor` and `AgentModel` are `Arc<dyn Fn + Send + Sync>`
  - notifications: `cove_agent::notification("notifications/tools/list_changed", None)` written through a cloned `transport::LineWriter` (pass the same writer to `serve_lines`)
- Diffuse meanwhile: use `cove_agent::…` paths everywhere; Diffuse defines no MCP or JSON-RPC code of its own
- Status: fixed in Cove (uncommitted working tree, 2026-10-31)

## G7: `cove-shell` exposes no SDL3 audio-device surface
- Needed by: `diffuse-audio` (`Backends/SDL3AudioBackend.swift`, `Playback/MediaPlayer.swift`'s `PlaybackAudioSink`)
- Cove today: `Shell` owns SDL3 windowing, clipboard and input (`sdl3_shell`, `sdl3_clipboard`) but nothing for audio: no `SDL_InitSubSystem(SDL_INIT_AUDIO)`, no `SDL_OpenAudioDeviceStream`, no stream queue/available queries, no `SDL_ResumeAudioStreamDevice`.
- Needed: a `cove_shell` audio-device API, i.e. open a default playback stream for an `f32` stereo spec at a requested rate, expose the device's real format (freq/channels/sample format), report queued and available bytes for pacing, accept `put`/`flush`/`resume`, and close on drop. Equivalent of the five SDL calls the Swift sink made.
- Diffuse meanwhile: `diffuse-audio` implements `AudioBackend` fully (`SilentAudioBackend` today) and takes the trait object; `SDL3AudioBackend` and `MediaPlayer` are translated against the planned API above and stay blocked at their gate until this lands.
- Status: fixed in the current Cove checkout (2026-11-14): `Sdl3AudioDevice` serves playback and the SDL backend; subsystem initialization and release are dispatched to SDL's main thread. Cross-platform verification is pending.

## G12: SDL audio streams lack gain and playback-rate controls
- Needed by: `diffuse-audio` (`Backends/SDL3AudioBackend.swift`).
- Cove today: `cove_shell::Sdl3AudioDevice` exposes queueing, flushing and device control, but no equivalent of `SDL_SetAudioStreamGain` or `SDL_SetAudioStreamFrequencyRatio`.
- Needed: stream gain and frequency-ratio setters with SDL's live-stream semantics, including changes to already queued audio.
- Diffuse meanwhile: the SDL backend remains pending; applying gain or resampling only when feeding samples would change the behavior of queued audio. No upstream code was modified.
- Status: fixed in the current Cove checkout (2026-11-14): live `set_gain` and `set_frequency_ratio` serve the Diffuse backend's short pan-adjusted queue. Cross-platform verification is pending.

## G9: process running state is cleared before termination is observed
- Needed by: `diffuse-script` cancellation and bounded compiler shutdown.
- Cove today: `cove_system::native_process::NativeProcess::terminate(false)` clears its running flag immediately, even when a child ignores SIGTERM. `start` also discards an exit-monitor thread spawn error instead of returning it.
- Needed: retain the running flag until the exit monitor observes termination; propagate failure to create the monitor so clients cannot wait indefinitely for a callback that has no producer.
- Diffuse meanwhile: compile completion and the 250 ms escalation are driven by the actual `on_exit` notification, matching the source compiler's wait-for-exit behavior. No Cove files changed; resource-exhaustion behavior of the upstream monitor remains unresolved.
- Status: open (source inspection, 2026-11-01; no tests or process execution performed).

## G8: `natsel::CharacterVirtual` cannot be stored by an owner that also owns the `World`
- Current checkout, 2026-11-04: **implemented; full upstream verification pending**. Batch 81 compiled the current Natsel dependency through Diffuse and ran 633 scene tests (618 pass, 15 fail, including character trigger exit); the standalone Natsel suite has not been run and these failures have not been isolated to Natsel. The user explicitly authorized the Natsel change. Restored `World: Send`, `CharacterVirtual::from_raw_world`, and `world_mut()`. Character storage now uses a private `NonNull<World>` handle with an exclusive lifetime marker and creates references only for each access, allowing multiple characters and direct world operations to be serialized by their owner. The safe `new(&mut World, def)` API retains its exclusive lifetime borrow. No tests or compilation were run in batch 78 under its then-standing migration constraint; the historical 532-test result below is not a result for this checkout. Batch 81 results are recorded above.
- Needed by: `diffuse-scene`'s `NatselPhysicsBackend` (`Physics/Backend/Natsel/NatselDeformables.swift`'s `CharacterRecord`)
- Original gap: `CharacterVirtual<'w>` held `world: &'w mut World` for its whole lifetime. Natsel's test helpers laundered that lifetime through a raw pointer; the current implementation above scopes world references to each access instead.
- Needed: either an owning form (`CharacterVirtual` that borrows the world only for the duration of `update`/`extended_update`, e.g. `character.update(&mut world, dt)`), or a documented safe handle (`CharacterHandle` resolved against `&mut World` per call). Either makes the Swift `characters: [EntityID: CharacterRecord]` shape expressible without `unsafe`.
- Diffuse meanwhile: `natsel_physics_backend.rs` stores the records behind a raw `*mut World` with a `// SAFETY:` note naming the invariant (backend owns the world, records are destroyed before it, no aliasing during `prepare`/`step`/`reset`). This is a faithful port of Swift's unchecked aliasing, not an ideal design — it exists because the Swift API being ported requires the record to outlive the call.
- Blocker B, related: `natsel::World` holds raw pointers (`*mut TraversalPair`, `*mut i32`, `*mut c_void`, `*mut ContactPayload`) and did not implement `Send`; Natsel patched this on its sub-structs (`CollideBuffers`, `ContactPayloadPool`, `PathGeometry`, `Shape`, `ShapeGeometry`).
- Historical resolution (not verification of the 2026-11-04 checkout): **fixed in Natsel** (user authorised editing Natsel). Two additive changes, `cargo test` 530 → 532 passing, no behaviour change:
  - `unsafe impl Send for World {}` in `src/simulation/world_runtime.rs`, with a `// SAFETY:` comment naming why the privately-owned traversal stacks transfer safely and why `Sync` is deliberately omitted.
  - `CharacterVirtual::from_raw_world(world: *mut World, def) -> Option<CharacterVirtual<'a>>` plus `world_mut(&mut self)`, in `src/character/character_virtual.rs`. This is the sanctioned way to express Swift's `unowned let world`; its doc comment states the caller's three obligations. Diffuse now has one auditable `unsafe` call instead of two `unsafe` blocks.

## G7: `cove-package audit` rejects Cargo targets outside `src/`
- Needed by: `cargo xtask audit` in the Diffuse workspace
- Cove today: `xtask/src/audit.rs` inspects `cargo metadata --no-deps --locked` and fails with `Rust target outside src/: .../benches/physics_runtime.rs`
- Diffuse meanwhile: keep the standard Cargo `benches/` layout; do not use `audit` until benchmarks move under `src/` or Cove relaxes the check
- Status: open (upstream layout constraint)

## G8: `cove-media`'s FFmpeg build produces no command line tools
- Needed by: `diffuse-media::MediaExporter` (`-filter_complex` export) and `MediaAsset::inspect`
- Cove today: `ffmpeg-sys-next =9.0.1` with the `build` feature clones `release/9.0` into `OUT_DIR` and configures with `--disable-programs`; only static libraries, and the media crate has no encoder/muxer
- Diffuse meanwhile: batch 85 keeps the export strategy and resolves an external FFmpeg 9.x CLI (`COVE_FFMPEG_EXECUTABLE`/`COVE_FFPROBE_EXECUTABLE`, shipped `Tools`/`Helpers`, then `PATH`); the `cove-media` `ffmpeg` feature is not enabled on any Diffuse crate yet
- Status: open (export capability needs a Cove API or a permanent external-tool dependency)
- Update (2026-11-14): `MediaAsset::inspect` uses Cove's in-process decoder and no longer needs `ffprobe`. Cove now has an optional `ffmpeg-tools` build and resolver; Diffuse consults it for export. Packaging the CLI for desktop releases still needs verification.

## G10: `JsonSchemaValidator` does not evaluate regex patterns
- Needed by: every capability input carrying a `scene:<number>` reference (`diffuse-intent` typed capabilities, `diffuse-ai` capability drafts and `SceneEditPlanExecutor`)
- Cove today: `simple_pattern_matches` accepts a literal-equal value or the hard-coded identifier pattern `^[a-z0-9][a-z0-9_-]{0,63}$`; any other `pattern`, including Diffuse's `^scene:[0-9]+$`, never matches. Swift's `JSONSchemaValidator` evaluates the regex, so a valid reference such as `scene:1` is rejected with `does not match required pattern`.
- Needed: a pattern matcher for the JSON Schema subset (at minimum anchored, character-class and quantifier patterns), or a hook that lets a host register the patterns it serves.
- Diffuse meanwhile: `diffuse_capability::capsule_schema::validate_capability_input` checks `^scene:[0-9]+$` itself and validates a copy of the schema with that pattern removed; every Diffuse validation path (`AnyCapabilityRegistration::prepare`, capability drafts, plugin host calls, the scene edit executor) goes through it. Contract schema hashes and advertised schemas keep the original pattern.
- Status: open (source inspection, 2026-11-08; covered by `capsule_schema` unit tests).

## G11: `JsonSchema` serializes `additional_properties` in snake_case
- Needed by: `diffuse-mcp` (`tools/list` schemas for project tools, capability contracts and dynamic capability tools), `diffuse-ai` provider requests, any JSON Schema crossing to Swift/editor-core
- Cove today: `crates/agent/src/schema.rs:48` declares `pub additional_properties: Option<bool>` without a rename. Serialization emits `"additional_properties":false` while every other JSON Schema keyword is camelCase (`minLength`, `maxLength`, `oneOf`, `minItems`, `maxItems`). Deserialization likewise expects `additional_properties`, so a Swift `JSONSchema` encoded as `additionalProperties` loses the constraint when decoded in Rust and drops it when re-advertised over MCP.
- Needed: `#[serde(rename = "additionalProperties", default, skip_serializing_if = "Option::is_none")]` on the field (or `rename_all = "camelCase"` on `JsonSchema` with the existing explicit renames kept).
- Diffuse meanwhile: `diffuse-mcp` passes `contract.input_schema` and decoded editor schemas through unchanged; the resulting MCP tools advertise a keyword clients ignore and lose strictness after a round trip. No Diffuse-side workaround, per the no-bypass rule.
- Fixed in Cove `crates/agent/src/schema.rs` (2026-11-11, user-authorized upstream edit): the field now carries `#[serde(default, rename = "additionalProperties", skip_serializing_if = "Option::is_none")]`. `tools/list` emits `additionalProperties` for all 37 tools and `diffuse-intent`'s schema test asserts both encode and decode. `cargo test -p cove-agent` (27+4+3) still passes.
- Status: fixed (found 2026-11-11 while porting `DiffuseMCP`; fixed and verified 2026-11-11).
