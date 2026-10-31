# Swift 基线（MIGRATION.md §7.1）

这些文件是 Swift 版本真实产生的输出，Rust 端必须逐字节复现。采集方式：在本机用 Swift 6.4.1 编译并运行生成脚本，不使用手工编写的期望值。

## `formats/`

| 文件 | 来源 | 对应 Rust 断言 |
|---|---|---|
| `scalars.json` | `JSONEncoder(outputFormatting: [.sortedKeys])` 编码一个含 `Double`/`Float` 各边界的结构 | `diffuse_kernel::codable::golden_tests::scalar_formatters_reproduce_swifts_golden_file_byte_for_byte` |
| `component-registry-sorted.json` | 同上，嵌套文档 + 浮点数组 + 非 ASCII 字符串 | `golden_tests::float_array_formats_inside_a_document_exactly_as_swift_did` |
| `component-registry-pretty.json` | `JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys])` | 由 `diffuse_assets::swift_json` 的 pretty 写出器断言 |

## 记录到的 Swift 事实（已实测，勿凭记忆改写）

- 浮点文本：`100`/`1e+20`/`1e-07`/`-0`；`Float` 与 `Double` 的科学计数切换点不同（见 §10）。
- 按 UTF-8 code unit 排序键。
- 非 ASCII 字符串原样写出（`日本語 light` 不转义）。
- pretty 布局：两空格缩进、`" : "` 分隔、空容器写作 `[\n\n  ]`。

## 仍待采集

- `.migration/baseline/swift-tests.json`：`./cove test` 的逐用例结果。
- 场景/物理基准的最终状态哈希。
- NativeRendererTests 的像素回读哈希（本机 Metal）。

这些依赖能完整跑通 Swift 测试套件的环境；在当前机器上 `./cove test Engine` 需要较长时间。未采集前，Rust 端的对应 crate 不得标 `tested` 以外的完成度，且 §7.2 的对等性检查视为未完成。
