# NativeRHI 编辑器网格 pass

`NativeEditorGridPass` 将现有 editor_grid pass 接入 NativeRHI，复用 `RenderPacket`、`RenderCameraMatrices`、`EditorGridPlane` 和 `EditorGridUniforms`。Slang 与 WGSL 执行相同的平面射线求交、抗锯齿、网格 LOD、轴线颜色和深度计算。两个后端均以一个 fullscreen triangle、相同 BGRA8 / Depth32 单采样目标及 alpha blend 执行。

这是独立 pass 的验证路径：`NativeGridRenderer` 只绘制背景和网格，场景 mesh、光照和后处理仍使用原 renderer。默认 EngineHost 行为保持 WGPURenderer。Native consumer 不把 NativeRHI 句柄伪装成 WGPU `GPUTexture` 指针，`currentViewportSurfaceState()` 返回无效状态；当前可直接呈现到 native window，或读取 NativeRHI 的 offscreen texture。Editor 的 WGPU viewport interop 尚未迁移。

## 接入

已有 NativeRHI 帧图可直接录制 pass（调用方负责 begin/endFrame、颜色/深度目标和提交）：

```swift
let grid = try NativeEditorGridPass(device: device)
try device.beginFrame()
let commands = CommandBuffer()
try grid.encode(packet: packet,
    color: RenderColorTarget(texture: sceneColor, loadAction: .load),
    depth: RenderDepthTarget(texture: sceneDepth, loadAction: .load),
    into: commands)
try device.submit(commands)
device.endFrame()
```

或把独立 consumer 接入正常 EngineHost / RenderThread 的 packet 流：

```swift
let device = try NativeRHI.Device.make(DeviceConfig(
    preferredBackends: [.metal], enableValidation: false, framesInFlight: 3))
let renderer = try NativeGridRenderer(device: device, surface: renderSurface)
host.start(renderConsumer: renderer)
```

Packet 的 `renderSettings.enableEditorGrid` 决定是否绘制，spacing、相机与 drawable size 使用现有 renderer 参数。工具和测试调用 `renderChecked`，避免错误被日志捕获后当作成功样本。帧常量来自 transient upload ring，binding 明确使用 192 字节范围，避免每帧覆写 GPU 正在读取的 uniform。Resize 创建新的目标，并通过 NativeRHI 的帧退休机制销毁旧资源。

## Shader 产物

源文件为 `RenderBackend/Resources/Shaders/Slang/editor_grid.slang`；两个矩阵显式使用 column-major，匹配 Swift / WGSL 的 192 字节布局。Metal、SPIR-V 的 vertex / fragment 产物和原始 reflection 已打包，运行时不需要 Slang。固定 Slang 2026.19 重建：

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
  python3 scripts/compile-native-renderer-shaders.py
```

Bundled Metal 产物省略 `#line`，不会嵌入开发机器的绝对路径。DXIL 可在具有 DXC/dxcompiler 的环境中通过 `--targets dxil` 生成；本轮未生成或验证 DX12 renderer shader，缺失时会明确报错。

## 本机验证

当前仅在 Apple M1 / macOS 27.0.1 上验证 Metal。macOS 不编译或回退到 Vulkan，Vulkan 面向原生 Windows/Linux。NativeRendererTests 覆盖透视、三种正交平面、看向地面以外时 discard、depth/color load、禁用网格、连续帧改变参数、非方形 resize、无效 frame 后恢复、uniform 越界、native window present / resize。RenderThread 的 GPU 集成测试验证 consumer 收到正常 packet 并报告网格 draw。

```sh
export SLANGC="$PWD/Engine/vendor/slang/bin/slangc"
export GUAVA_RUN_GPU_SMOKE_TESTS=1
export GUAVA_WGPU_BACKEND=metal
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|RenderThreadTests|RenderCameraMatricesTests|editorGrid'
python3 scripts/check-swift-maintainability.py
python3 scripts/test-rhi-shader-toolchain.py
```

WGPU reference 检查启用 WGPU validation。原生 Windows/Linux Vulkan 与 DX12 本轮不做 GPU 验证。

## 性能测量

```sh
GUAVA_WGPU_BACKEND=metal \
swift run -c release --package-path Engine --jobs 4 NativeRHIPassProbe \
  --width 1280 --height 720 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-grid-720
```

1080p 使用 `--width 1920 --height 1080`。工具导出 `report.json` 和三张 PPM 实际读回画面；像素偏差超限会使工具退出失败。WGPU reference 只执行相同的一个网格 pass，不启用原 renderer 的其他 pass 或 opaque cache。

CPU frame / encode / submit 使用单调时钟，CPU frame 包含相机参数、上传、录制和提交。预热与管线创建不进入样本；每三帧调用相应后端的 GPU idle，重复批次的 wall time 除以帧数得到 completed-batch ms/frame。两条路径都采用三帧批次；shader 编译、图像读回、文件写出和窗口 vsync 不进入批次计时。

Completed-batch 时间包含 CPU、GPU、驱动提交及等待开销，**不是 GPU timestamp 时长，也不是整个引擎的 FPS**。单次实测可用于迁移基线，不能推出通用的引擎提速比例。报告包含时间、系统、build configuration、样本数和量化误差；p95 使用 nearest-rank，对仅三个 completed-batch 样本代表其中最慢的一次。

2026-10-08 本机实测如下，CPU frame 和 completed-batch 列均为 p50；每个尺寸预热 30 帧，再进行 3 × 180 帧测量：

| 尺寸 | 路径 | CPU frame（µs） | Completed batch（ms/frame） |
| --- | --- | ---: | ---: |
| 1280×720 | Native Metal | 24.0 | 0.520 |
| 1280×720 | WGPU / Metal | 115.5 | 1.484 |
| 1920×1080 | Native Metal | 31.4 | 0.826 |
| 1920×1080 | WGPU / Metal | 119.7 | 1.697 |

图像差值按 RGB 三通道计算。两个尺寸下，Native Metal 与 WGPU 的 RGB 输出逐字节相同；完整 p95、样本数与环境见 [720p 报告](benchmarks/native-grid-m1-720.json) 和 [1080p 报告](benchmarks/native-grid-m1-1080.json)。

历史报告中的 Vulkan 样本不属于 Windows/Linux 平台验证；当前探针默认仅选择本机原生 API。PBR/HDR 的新测量见 [PBR 验证](NATIVE_PBR_VALIDATION.md)。
