# GuavaPluginKit

用 Embedded Swift 编写 Guava 插件的 SDK。插件编译成 WebAssembly 核心模块，再包进 `capabilities.wit` 描述的组件；不需要手写 WAT。

```sh
./guava plugin build Editor/Plugins/Git --output Editor/Sources/EditorCore/Resources/Plugins/Git.guavaplugin
```

插件目录包含 `plugin.json`、`capabilities.wit` 与 `Sources/*.swift`。构建会：

1. 由 `GuavaPluginHost --component-shell` 按 WIT 生成组件外壳（`shell.wat`，内含占位核心模块）和导出绑定 `Exports.swift`；
2. 用所选 Swift 工具链把本 SDK（`-parse-stdlib`，以便调用 `memory.grow`）和插件源码编译成 `wasm32-unknown-none-wasm` 对象，`wasm-ld` 链接成核心模块；
3. 由 `GuavaPluginHost --link-component` 编译外壳，并把占位核心模块替换成 Swift 编译出的模块。

每个能力 `name: func(input: name-input) -> string` 对应插件里的普通函数，字段名转为小驼峰；输入记录只支持 `string` 与 `list<string>` 字段：

```swift
import GuavaPluginKit

func provider(request: String, stdout: String) -> String { ... }
```

## 内容

- `Runtime`：分配器（`posix_memalign`、`free`、`cabi_realloc`）、规范 ABI 字符串输入输出、`guava:process/host` 调用。每次调用都在新实例中运行，内存不跨调用。
- `JSON`：Embedded Swift 没有 Codable 与 Foundation，这里提供 JSON 值、解析与序列化，数字按整数读取。上千条目的结果用 `JSONWriter` 直接写出，再以 `JSON.raw` 返回，避免构建值树。
- `Text`：按单字节切分工具输出；`String(utf8:)`、`joined(separatorByte:)` 与内部的 `ByteWriter` 用 `copyMemory`（一条 `memory.copy`）整块复制。Embedded Swift 标准库在 WebAssembly 上逐字节复制字符串，燃料按指令计，大段文本应走这里。
- `VersionControl`：`contributes.versionControl` 的步骤协议。

## 版本控制步骤协议

插件决定做什么，编辑器去执行；插件宿主不会被长命令卡住。

```
编辑器 → 插件: {"op":"status"}
插件 → 编辑器: {"run": ["status","--porcelain=v2",…], "next": "parse"}
编辑器: 按 manifest 的进程权限运行命令（参数前缀由 manifest 提供），异步等待
编辑器 → 插件: {"op":"status", "next":"parse", "output": {"exit", "stderr", "offset", "complete"}}，stdout 是一个输出窗口
插件 → 编辑器: {"emit": "{\"changes\":[…", "consumed": 1048000, "next": "<状态>"}   （分页）
插件 → 编辑器: {"emit": "…]}", "done": true}                                  （最后一页）
```

一步可以是 `run`（带 `next` 时回调；不带 `next` 时命令的标准输出就是结果，用于差异）、`trash`（编辑器检查路径在仓库内后移到废纸篓，再带 `next` 回调）、`result`、`error`，或分页的 `page` / `lastPage`。`run` 可带 `input`（写入标准输入）、`env`（须在 manifest 的 `environmentKeys` 内）与 `timeout`（秒）。

### 分页

命令输出按 1 MiB 窗口发给插件（`CommandOutput.stdout`、`offset`、`isComplete`）。插件读完窗口里完整的记录，返回 `.page(片段, consumed: 已读字节, next: 状态)`；编辑器把片段接到结果文本后，从 `offset + consumed` 起发下一窗口。最后一页返回 `.lastPage(片段)`，所有片段拼起来就是结果 JSON。跨页的状态（如是否已写过元素、分支信息）放进 `next`。

- 记录数组用 `VersionControl.pagedArray(request, separator:element:)`，状态由它管理。
- 需要整段输出的解析（如去重）用 `output.whole`；为 nil 时返回 `.wholeOutput(next:)`，编辑器加宽窗口直到包含全部输出。
- 返回 `consumed: 0` 而窗口还没到末尾时，编辑器会加宽窗口，所以单条记录比窗口长也没关系。

大结果用 `JSONWriter` 直接写片段，不构建 `JSON` 值树。

编辑器的进程请求以 `{"process":…}` 发给插件，`VersionControl.serve` 不解析，原样转给 `guava:process/host`，由宿主按 manifest 校验。
