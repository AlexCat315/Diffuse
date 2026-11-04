# diffuse-script 测试翻译约定（内部工作稿，勿提交）

仓库根：`/Users/cyke666/dev/Diffuse`。Swift 源：`Engine/Tests/ScriptRuntimeTests/*.swift`。
Rust 目标：`crates/diffuse-script/src/tests/script_runtime/*.rs`（全部是 0 字节占位，`mod.rs` 已声明全部模块）。

只写自己负责的文件，不要动 `mod.rs`、不要动生产代码、不要动别的队友的文件。

## 硬性要求（MIGRATION.md §5.6 / §5.7）
- 容差、夹具、断言一个不少。**不许**为通过而放宽断言或删除用例。
- 禁止 `todo!()`、`unimplemented!()`、空函数体、`#[allow(dead_code)]`。
- 每个文件顶部写 `//! Ported from \`Engine/Tests/ScriptRuntimeTests/<Name>.swift\`.`，再补若干行说明 Swift → Rust 的调用差异（照 `crates/diffuse-scene/src/tests/scene_runtime/particle_tests.rs` 的风格）。
- Swift `@Test("显示名")` → 上一行 `/// 显示名` 注释 + `#[test] fn 蛇形名()`。
- `#expect(a == b)` → `assert_eq!`；近似比较用 `assert!((a - b).abs() < eps)`；`try #require(x)` → `x.expect(...)` / `let Some(x) = ... else { panic!(...) }`。
- 参数化 `@Test(arguments:)` 展开成循环，失败信息带上参数。
- 浮点比较若 Swift 用 `partial_cmp` 语义，Rust 保留 `partial_cmp`，不要用 `==`。
- 需要 GPU 的用例，照 Swift 的跳过条件跳过（不要写成永远跳过）。

## 关键 API 对照（已核对生产代码）

### SceneRuntime（`diffuse_scene::scene_runtime::SceneRuntime`）
```rust
let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
runtime.set_script_driver(scripts.clone());          // 接受 SharedRuntimeScriptDriver / ScriptRuntime
runtime.set_resource(map);                            // InputActionMap
let entity = runtime.create_entity();
runtime.set_local_transform(LocalTransform::default(), entity);
runtime.set_component(CameraComponent::default(), entity);
runtime.set_component(ScriptComponent::new(handle), entity);
runtime.tick(delta_time, frame_index, input_events);  // 返回 RuntimeScheduleReport，Swift 的 tick 只有 deltaTime
runtime.component::<CameraComponent>(entity)          // Option<C>
runtime.local_transform(entity)                       // Option<LocalTransform>
runtime.resource::<InputFrameState>()                 // Option<R>，返回克隆
```
Swift 的 `_ = runtime.tick(deltaTime: 0.1)` → `runtime.tick(0.1, 0, Vec::new())`。

### ScriptRuntime（`diffuse_script::ScriptRuntime`）
```rust
let scripts = ScriptRuntime::new();
let handle = scripts.register(Script::first_person_camera(0.01), Some("camera.first-person"));
// 或无名字：scripts.register(script, None)
scripts.register_factory(Some("name"), "{}", ScriptDefinition::default(), move || script.clone());
scripts.register_behavior::<MyBehavior>(Some("name"), "{}");
```
Swift `scripts.register(named:) { .xxx }` → 中文对应：`Script::xxx(...)` 构造器 + `register(script, Some(name))`。
注意：`register` 返回值是 `ScriptHandle`。

### 输入（`diffuse_scene::input_action`）
```rust
let mut map = InputActionMap::new(BTreeMap::new());   // Swift: InputActionMap()
map.bind("jump", InputBinding::key(Scancode::SPACE)); // 常量名以生产代码为准
runtime.set_resource(map);
```
`InputFrameState` 字段：`held` / `just_pressed` / `just_released`（`BTreeSet<String>`）、`axes`（`BTreeMap<String, f32>`）；
方法：`is_held(&str)`、`is_just_pressed(&str)`、`is_just_released(&str)`、`axis(&str) -> f32`。

`DefaultInputActions` trait 提供 `InputActionMap::cove_default()`（`crates/diffuse-script/src/input/default_input_actions.rs`）。

### 输入事件（`diffuse_kernel::input_event`）
Swift `.keyDown(KeyEvent(...))` → Rust 对应变体构造；`.windowFocusLost` / `.windowMinimized` 同理。
**开工前先 `sed -n '1,200p' crates/diffuse-kernel/src/input_event.rs` 确认变体名和字段**，不要凭猜。

### 预设（`diffuse_script::script_presets`，通过 `Script::` 关联函数调用）
`Script::rotator(Float3)`、`Script::oscillator(Float3, f32, f32)`、`Script::follower(EntityID, f32, f32)`、
`Script::look_at_target(EntityID, Float3)`、`Script::destroy_after(f64)` 等。开工前 `grep -n "pub fn " crates/diffuse-script/src/presets/script_presets.rs` 取全量。

### 组件
`CameraComponent`、`ScriptComponent`、`LocalTransform` 来自 `diffuse_scene`。
`ScriptComponent::new(handle)`；`camera.target` 字段直接可读。
`LocalTransform::translation()` 是方法（不是字段）。

### 向量
`use diffuse_math::simd::simd_compat::{Float3, Float4, Quatf, simd_length, simd_normalize, ...};`
`Float3::new(x, y, z)`；`SIMD3<Float>(1,2,3)` → `Float3::new(1.0, 2.0, 3.0)`。

## 完成标准
1. 文件非空、用例数与 Swift 一一对应。
2. `cargo check -p diffuse-script --all-targets` 通过（只看自己文件相关的 error）。
3. `cargo clippy -p diffuse-script --all-targets -- -D warnings` 无新增问题。
4. `rustfmt --edition 2024` 已格式化。
5. 回报：文件路径、用例数、Swift 行数、你解决的 API 差异要点、遗留问题。

不要修改 `Docs/rust-migration-files.json`（状态由 Lead 统一改）。
