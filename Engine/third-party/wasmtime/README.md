# Wasmtime 构建与交付

版本、目标 triple 和官方下载 SHA256 由 `catalog.json` 统一管理。保持 Wasmtime **49.0.2**；这里不依赖 PATH 中的 Wasmtime 可执行文件。

桌面与 Android 下载经过 SHA256 校验的官方 C API 包，并提取静态库和头文件。iOS 从同一版本、同样经过校验的源码包构建，启用 `cranelift,component-model,pulley,wat`，不链接 WASI。Cranelift 在这里将组件编译为 Pulley 字节码，guest 由解释器运行。桥接层在 iOS 和 iOS Simulator 上强制选择 `pulley64`。

在仓库根目录独立准备当前主机依赖：

```sh
swift run --package-path Tools/Developer cove-dev plugins stage
swift run --package-path Tools/Developer cove-dev plugins stage --check
```

指定其他目标或交叉构建输出目录：

```sh
swift run --package-path Tools/Developer cove-dev plugins stage --platform android-arm64 --vendor Engine/build/android-validation/native/vendor
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
swift run --package-path Tools/Developer cove-dev plugins stage --platform ios-arm64
swift run --package-path Tools/Developer cove-dev plugins stage --platform ios-arm64-simulator
```

普通桌面/Android构建需要 CMake 和 curl。iOS 构建另外需要 macOS、Xcode、Rust/Cargo 及所选 iOS Rust target；构建使用源码自带的 Cargo.lock，原生预编译包不需要 Rust。

产物位于 `Engine/vendor/Wasmtime.artifactbundle`；各平台 variant 可同时存在。每个 variant 自带源码来源、归档 SHA256、静态库 SHA256 和执行方式的 `provenance.json`。`--vendor` 对应 SwiftPM 的 `COVE_ENGINE_ARTIFACT_ROOT`，该环境变量必须是相对 Engine 包根目录的路径。全量 `swift run --package-path Tools/Developer cove-dev native-bootstrap`、Engine CMake 和 Cove Android CLI 使用同一套 staging 实现。旧的动态 XCFramework 不再保留。

| 平台 | 可用目标 | 执行方式 |
| --- | --- | --- |
| macOS | arm64、x86_64 | Wasmtime 原生 / 可选 Pulley |
| Windows MSVC | x86_64、arm64 | Wasmtime 原生 / 可选 Pulley |
| Linux glibc | x86_64、aarch64 | Wasmtime 原生 / 可选 Pulley |
| Android | arm64、x86_64 | Wasmtime 原生 / 可选 Pulley |
| iOS 26+ | arm64；arm64/x86_64 Simulator | 强制 Pulley |
| 浏览器 | 独立 Web 交付流程 | 见 [插件执行说明](../../../../docs/architecture/plugin-execution.md) |

此表描述插件运行库的目标，其他 Engine/CoveUI 模块和应用构建命令仍以各自支持矩阵为准。预编译 Linux 包使用 glibc，不包括 musl；Android UI 工具链目前仍以 arm64 为应用目标。

静态链接后，发行包只交付 `DiffusePluginHost` 可执行文件，不再另外复制 `libwasmtime.dylib` 或 Wasmtime DLL/so。桌面继续使用独立宿主进程。iOS/Android 应用可使用 `EmbeddedPluginSession`；两种入口复用同一插件契约、授权指纹、查询快照和输出校验。

可执行验证：

```sh
cmake -S Engine/Validation/Plugins -B Engine/build/plugin-probe \
  -DCOVE_WASMTIME_VARIANT="$PWD/Engine/vendor/Wasmtime.artifactbundle/macos-arm64"
cmake --build Engine/build/plugin-probe
swift run --package-path Tools/Developer cove-dev plugins verify --probe Engine/build/plugin-probe/CovePluginProbe
swift build --package-path Engine --product DiffusePluginHost
swift test --package-path Engine --filter PluginRuntimeTests
```

CI 的独立插件 gate 在 macOS、Linux、Windows 上运行真实组件、查询和燃料中断测试，并构建 Android 静态链接探针、执行 iOS Simulator Pulley 探针。Engine CI 另运行 Swift 宿主 RPC 与浏览器 Worker 集成测试。
