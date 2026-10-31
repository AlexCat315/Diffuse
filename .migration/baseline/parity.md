# 对等性验证记录（MIGRATION.md §7）


## 已完成：`diffuse-observation` ↔ Swift `ObservationBusTests`

| 项目 | Swift 基线 | Rust 移植 | 一致 |
|---|---|---|---|
| 用例数 | 12 | 12 | ✅ |
| 通过 | 12 | 12 | ✅ |
| 用例名 | 见 `swift-tests-observationbus.json` | 同名注释 + `#[test]` | ✅ |

Swift 侧的 `async` / actor / `DispatchQueue.concurrentPerform` 在 Rust 侧按 §5.5 换成线程 + 通道 + `Mutex`；断言强度未降低（`sink` 的投递、`AsyncStream` 的产出、并发追加 64 次不丢事件都保留了）。

## 已完成：`diffuse-math` ↔ Swift `EngineMathTests`

| 项目 | Swift 基线 | Rust 移植 | 一致 |
|---|---|---|---|
| 用例数 | 27 | 27 | ✅ |
| 通过 | 27 | 27 | ✅ |
| 失败 | 0 | 0 | ✅ |
| 用例名 | 见 `swift-tests.json` | 同名，`#[test]` 上方的注释保留 Swift 显示名 | ✅ |
| 浮点格式 | 见 `formats/scalars.json` | `diffuse_kernel::codable::golden_tests` 逐字节复现 | ✅ |

`EasingTests` 的 `linear maps t to itself` 在 Swift 里是参数化测试（`arguments:` 5 组），Rust 侧展开成循环并在失败信息里带上参数，符合 §5.6。

## 已验证一致的四个 crate（Swift ↔ Rust 用例数逐项相同）

| crate | Swift 测试目标 | Swift | Rust | 说明 |
|---|---|---|---:|---|
| `diffuse-math` | `EngineMathTests` | 27 | 27 | 逐名一致 |
| `diffuse-observation` | `ObservationBusTests` | 12 | 12 | 逐名一致 |
| `diffuse-sequence` | `SequenceRuntimeTests` | 10 | 10 | 逐名一致 |
| `diffuse-capability` | `CapabilityRuntimeTests` | 36 | 36 | 逐名一致 |
| `diffuse-cinematic` | `CinematicRendererTests` | 14 | 14 | 逐名一致 |
| `diffuse-color` | `ColorPipelineTests` | 7 | 7 | 逐名一致 |
| `diffuse-audio` | `AudioRuntimeTests` | 16 | 15 | Rust 少 1：`videoPlaybackRespectsRangeAndCancellation` 需要真实 SDL3 音频设备（G7），随 SDL3 后端一起等待 |
| `diffuse-card-battle` | `CardBattleRuntimeTests` | 18 | 22 | Rust **多** 4 个：Swift 18 个用例的意图全部覆盖，另加逐字节编码/往返/Dictionary 形状等 §5.4 断言 |
| `diffuse-assets` | `AssetPipelineTests` 等 | 未采集 | 92 | Swift 侧 `./cove test Engine` 全量尚未跑完；Rust 侧 92 个测试含 5 个逐字节编码断言（见下） |

`diffuse-assets` 的 §5.4 证据：`geometry_document_bytes_tests::pretty_output_matches_swift_bytes` 断言 `to_sorted_pretty(&captured_document())` 等于一份 1282 字节、sha256 `237eb610…fb88e` 的夹具，该夹具由 Swift `JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys])` 真实生成。另有 4 个配套断言：空容器的 `[\n\n  ]` 布局、往返逐字节一致、save/load 保持字节、标量记法（`1e-05`/`10000000`/`1e+08`/`-0`/`0.0001`/`1e-07`）。

每个基线都归档为 `.migration/baseline/swift-tests-<target>.json`，含逐用例名称与结果，便于逐项核对。

## 未完成（需要用户确认环境后再采集）

- `Engine` 其余测试目标（SceneRuntime、ScriptRuntime、AssetPipeline、AudioRuntime、…）：`./cove test Engine` 全量需较长时间，尚未完成。
- 模拟哈希：`SceneRuntimeBenchmarks`/`PhysicsRuntimeBenchmarks` 的最终状态哈希。
- 渲染回读：`NativeRendererTests` 在本机 Metal 上的像素哈希。
- 编辑器侧（`Editor`、`Editor/Documents`、`Editor/Tests/*`）与 `Engine/Media`。

在这些采集完成前，§7.2 的对等性检查不能视为通过；对应 crate 的 `tested` 只表示「Rust 测试自身通过」，不表示「与 Swift 基线一致」。
