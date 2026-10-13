# NativeRHI 独立运行验证

2026-10-11，Apple M1，macOS 27.0.1，Swift 6.4.0。桌面渲染统一使用 NativeRHI；运行时不再链接 wgpu-native，也不需要 Rust/Cargo 构建图形依赖。

## 迁移范围

- 移除 `RHIWGPU`、`CWGPUBridge`、wgpu-native 二进制目标及 CMake 下载/构建流程，删除旧桌面 WGSL shader、渲染器和参考绘制器。
- Engine、Editor、Player、GuavaUI 窗口与 HUD 直接使用 `NativeRHI.Device`。EngineHost 未提供设备时执行无 GPU 仿真；需要绘制的宿主显式创建并共享设备。
- 视口通过 `TextureResource` 持有图像，保留跨帧快照的资源所有权；HUD 拒绝来自不同设备的渲染目标。
- 配置改用 `--rhi-backends`、`--rhi-config`、`GUAVA_RHI_BACKENDS`、`GUAVA_RHI_CONFIG`；后端名为 `metal`、`vulkan`、`dx12`。Editor/Player 的 `--renderer native` 选择平台默认后端，也可显式指定后端。
- 移除旧后端专用的 Render Bundle 设置和统计；编辑器性能面板、趋势分析和诊断使用实际网格批次数 `meshBatchCount`。
- Wasmtime 是插件运行时的独立预编译依赖，继续保留。浏览器预览直接使用浏览器 WebGPU API 和自己的 WGSL，也继续保留。

## 修正与工具链

- 共享 UI 绘制器的每个窗口在绘制前重新应用本窗口的 MSAA 设置，避免 1x/4x 窗口交替绘制时复用错误的管线状态。
- 固定工作室环境的 CPU IBL 数据改为每进程生成一次，各设备仍独立拥有 GPU 纹理。
- Device 创建前拒绝空后端列表和非正的 frames-in-flight，避免无效配置进入原生后端。
- Slang 2026.19 安装校验 SHA-256 和编译器版本，在目标文件系统暂存并完成验证后发布。
- shader 编译先完成编译、反射与序列化，再原子替换单文件。批量工具先完成全部编译再发布；编译失败保留已有批次。`--check` 重新编译并比较已提交产物和反射，不修改源码目录。
- GPU 回归固定测试清单，每次建立新的报告目录，同时覆盖 Swift Testing 和 XCTest。SwiftBuild 6.4 未输出 XCTest XML 时，从本次运行日志中的已完成测试记录补全报告；缺项、跳过和失败均拒绝通过。

## 验证命令

在仓库根目录、Swift 6.4.0 环境中执行。已安装 Slang 时直接设置 `SLANGC`；首次安装可运行 `python3 scripts/bootstrap-rhi-slang.py`。

```sh
export SLANGC="$PWD/Engine/vendor/slang/bin/slangc"
cmake -S Engine/third-party -B Engine/build/native -DCMAKE_BUILD_TYPE=Release
cmake --build Engine/build/native --parallel --config Release
python3 scripts/test-rhi-shader-toolchain.py
python3 scripts/compile-native-renderer-shaders.py --check
python3 scripts/test-gpu-regression-verifier.py
swift test --package-path Engine
swift test --package-path GuavaUI
swift test --package-path Editor
bash scripts/test-gpu-regression.sh
python3 scripts/check-swift-maintainability.py --report
```

GPU 回归报告和场景像素默认写入 `Engine/build/gpu-regression/`；每次运行的日志及 XML 位于独立的 `run-*` 子目录。

本机结果：

| 检查 | 结果 |
| --- | --- |
| CMake Release 原生依赖完整构建 | 通过 |
| 固定 Slang 的全新安装与版本校验 | 通过 |
| shader 工具链契约 | 9 项通过，包括使用全新安装的编译器复验 |
| Metal / SPIR-V 已提交产物与反射 | 86 份 shader 产物检查通过 |
| GPU 回归清单校验器契约 | 7 项通过，覆盖缺项、未完成、跳过、失败与混合报告 |
| GPU 回归固定清单 | 51 个 Engine 和 17 个 GuavaUI 测试函数通过，无跳过 |
| Engine 完整包测试 | 通过，其中 NativeRHI 121 项、NativeRenderer 42 项均通过 |
| GuavaUI 完整包测试 | 通过 |
| Editor 完整包测试 | 通过，包括 GameApplication 实际 Metal 视口与网格批次诊断 |
| 最终场景冒烟复验 | 7 类场景及编辑器网格通过，检查可读像素与真实几何覆盖 |
| Swift 可维护性检查及 diff 空白检查 | 通过；32 个既有超限指标未增加，旧后端债务记录已移除并降低相关上限 |

普通完整包测试保留 opt-in benchmark 等用例的默认跳过行为；GPU 固定清单单独启用并禁止跳过。原生播放器符号检查未发现 wgpu-core、wgpu-hal 或 wgpu C API 符号。

## 验证边界

本机执行 Metal GPU 路径。Windows 默认优先使用 DX12，DX12 设备创建失败时尝试 Vulkan；Linux 默认使用 Vulkan。Windows 的 DX12 以及 Windows/Linux 的 Vulkan 运行、呈现和独立队列族仍需对应宿主验证。已提交的 Metal/MSL 和 Vulkan/SPIR-V 离线产物都检查与 Slang 源码一致；DXIL 场景产物尚未打包，DX12 渲染需要先在具备 DXC 的工具链中生成这些产物，缺失产物会明确失败。

移除旧后端后，重复原生会话用于验证确定性、资源重建和历史状态。它不是独立 shader 正确性基准；实际像素变化、几何覆盖、粒子状态/事件、工作组一致性、视口所有权及失败恢复由专门断言验证。旧 WGPU 对照报告和 benchmark JSON 保留为历史证据，不代表当前可以运行的对照路径。

本轮没有执行完整的 Editor 窗口/MCP 脚本编译、热重载和导出流程脚本 `scripts/validate-editor-native-loop.py`；相关包测试和 GPU 窗口集成分别验证。

## Android 真机补充验证（2026-10-12）

Swift 6.4.0 + Android SDK + NDK r30 已在 Android 16 / ARM64 / Adreno 710 上编译并运行 NativeRHI 与 GuavaUI 共享代码。设备 loader 为 Vulkan 1.4，物理驱动实际为 1.1.128。核心 render pass、timeline KHR feature 协商与 SPIR-V 1.3 UI 产物已接入，七项 GPU/布局检查及 APK 横竖屏、触摸、前后台 surface 重建检查通过。详见 [Android 复现与支持边界](../../../../../Platforms/Android/README.md)。

本轮 macOS 回归：121 项 NativeRHI 测试通过且无跳过；43 项相关 GuavaUI 测试通过；10 项 shader 工具链契约通过，86 份产物与反射重新编译一致。Swift 可维护性检查发现既有 `GuavaUI/Sources/GuavaUI/Core/AppDisplayHandle.swift` 为 29 个存储属性、既有上限为 27，本轮没有修改该文件，也没有扩大 baseline。

### SharedCounter 真机接入

Android APK 已进一步运行桌面和浏览器共用的 `CounterView`。字体依赖由 NDK 从仓库固定的 FreeType / HarfBuzz 子模块构建，实际文字经共享 FontAtlas / DrawList / NativeDrawListRenderer 在 Vulkan 上呈现。Java 宿主管理 Choreographer、Surface 和 InputConnection。

`scripts/android/verify-demo.py` 在同一台 Android 16 / Adreno 710 设备通过 22 个检查点，并检查计数字形截图变化、主题背景像素、拖出取消和空闲时停止 GPU 提交。真实 Android IME 绑定与英文按键提交通过；中文预编辑、提交、取消、代理对及组合字素通过 debug 广播调用同一 InputConnection 验证。后者是回调回放，尚不代表所有系统输入法的人工验收。

Activity 重建、回到桌面再返回、横竖屏窗口重排均保留计数、主题与已提交文字；焦点、预编辑和 GPU 会话不进入持久状态。横竖屏截图也检查了平板兼容窗口中的真实 Surface 偏移。

接入字体工具链后的七项 NativeRHI GPU/布局探针再次通过；GuavaUI Portable 96 项和 GuavaUIText 12 项主机测试通过。完整组件 Gallery 和完整 TextField 不在本轮范围内。复现命令、输出格式和限制见 [Android 文档](../../../../../Platforms/Android/README.md)。
