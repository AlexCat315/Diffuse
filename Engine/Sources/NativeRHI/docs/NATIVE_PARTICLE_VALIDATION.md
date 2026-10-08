# NativeRenderer 粒子绘制与 GPU 压缩

NativeRenderer 已接入 CPU authored / runtime 提取后的粒子绘制、GPU 稳定可见性压缩和 indirect draw。Metal 与 SPIR-V 离线着色器产物同时提供；macOS 只使用 Metal，不使用 MoltenVK。Windows/Linux Vulkan 和 Windows DX12 的原生编译及运行按用户要求暂缓。

## 绘制与资源

两条 renderer 共用 `ParticleGPUData.swift`，把整个 RenderParticle 打包成相同的 112 字节 instance。批次直接采用生产 `ParticleRenderBatchPlan`：相邻同纹理/混合模式合并，保持输入排序。Native 的 source 和 batch descriptors 使用 frame-owned transient upload；visible 和 indirect 输出独立扩容，旧资源由 Device 延迟退休保护。

Slang 沿用生产的六顶点 quad、旋转 billboard、速度对齐投影、拉伸、渐细 ribbon、末端颜色/alpha、重复 V 和 texture-sheet UV rect。纹理通过真实 ImageAssetDecoder 解码成 RGBA8，失败时使用白色 fallback、每个路径仅警告一次，后续帧继续尝试加载。alpha 和 additive 的颜色及 alpha 混合因子与生产路径一致，深度只读。

压缩 compute 使用 64 个 physical threads，每个 render batch 对应一个 workgroup；分块处理任意数量候选，shared flags 前缀和保留可见 instance 顺序。可见条件与 WGSL 相同：size/alpha、clip.w 以及带 padding 的 NDC x/y；深度遮挡交给 raster。GPU 写出四个 UInt32 的 indirect arguments，包括每批次的 firstInstance。

Slang 的 SV_InstanceID 在 Metal/SPIR-V/DXIL 为批次内编号，Native shader 用绑定的 batch start 还原 shared-buffer 索引，避免依赖 DX12 SM 6.8 的 StartInstanceLocation。参见 [Slang Metal 语义说明](https://docs.shader-slang.org/en/stable/external/slang/docs/user-guide/a2-02-metal-target-specific.html)。这次对照也发现旧 WGPU device 未请求 `indirect-first-instance`，导致后续非零 firstInstance 批次不绘制；已修复生产 bridge 的必需特性请求。Native Vulkan device 同时检查并启用 `drawIndirectFirstInstance` 和 `shaderDrawParameters`，否则明确报告不支持。

粒子在透明网格之后、Bloom/tonemap 之前绘制；opaque snapshot 复用仍每帧重新处理粒子。非法非有限输入在 beginFrame/资源分配前拒绝。resident GPU simulation 的生成、物理、存活压缩和事件回读现已接入，见 [GPU 模拟验证](NATIVE_PARTICLE_SIMULATION_VALIDATION.md)。`renderOnGPU` 的排序/appearance/实例转换仍明确拒绝，不能把 GPU 压缩当成完整模拟绘制已经迁移。

## 本机验证

`NativeParticleTests` 的实际 GPU 回读检查 131→399→7 个候选的稳定压缩、分块边界、扩容与缩小，并逐批检查 vertexCount、instanceCount、firstVertex、firstInstance 和整个有效 instance 字节。

26 个连续 RGB 对照帧覆盖 alpha/additive 混合、真实 BMP 解码、UV rect、旋转、速度对齐、ribbon 宽度/颜色/alpha/重复 V、fallback、缺失纹理恢复后的重试、深度遮挡、批次重排、400 个新增交错批次、清空/恢复、viewport 扩容/缩小、正交相机、HDR Bloom/TAA/FXAA、opaque cache hit 和错误输入恢复。关键参数必须改变实际像素；此本机测试序列全部 RGB 像素相同。原始图像在 `/tmp/guava-native-particles`。另有实际 Metal 窗口的六帧呈现、缩放与错误恢复检查。

本机相关检查：85 项 NativeRHI XCTest、32 项 NativeRenderer XCTest、44 项 shader catalog/生产 GPU Swift Testing 均通过；纹理恢复和 runtime ABI guard 调整后，3 项 NativeParticleTests 再次通过。Slang 工具链 5 项 Python 检查及 Swift maintainability 检查通过，既有 46 项超限指标没有增加。

```sh
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|ShaderCatalogTests|RenderBackendGPUSmokeTests'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

## Release 探针

`--scene particles` 在完整 HDR post graph 中每帧提交 2048 个 billboard 和 32 个 ribbon，alpha/additive 共 16 个批次。相机阶段性保持静止，以覆盖 opaque cache 复用时粒子的持续变化。测量会要求 Native/WGPU 的候选总数、cull batches、实际 dispatch workgroups、indirect draws 及粒子 pass draw 总数一致且非零。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene particles --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-particles-1080
```

Apple M1 本机 Release，验证关闭，30 帧预热、3×180 帧测量：

| 分辨率 / renderer | CPU frame p50 / p95 (µs) | 完成批次 p50 / p95 (ms/frame) |
|---|---:|---:|
| 1280×720 NativeRHI Metal | 949.709 / 1312.584 | 2.663 / 2.712 |
| 1280×720 WGPU Metal | 978.791 / 1226.709 | 3.797 / 3.802 |
| 1920×1080 NativeRHI Metal | 1379.958 / 1773.958 | 4.490 / 4.523 |
| 1920×1080 WGPU Metal | 1115.167 / 1636.375 | 6.142 / 6.198 |

每项 CPU 分布包含 540 个样本，完成批次为 3 个样本。完成批次包含每三帧等待 GPU，测量吞吐，不是 GPU timestamp 或显示 FPS。批次 p50 分别降低约 29.9% / 26.9%；1080p CPU p50/p95 和 720p CPU p95 仍高于 WGPU，完整迁移及默认切换前还需评估 CPU 开销。

每条路径共处理 1,123,200 个候选、8640 个 cull workgroups 和 8640 次 indirect draws，粒子 pass 执行 540 帧。整个图的实际 pass frames/draws 完全一致：opaque pass 各 315 帧、SSR 270 帧、透明/粒子/Bloom/tonemap/FXAA 各 540 帧，余下 225 帧复用 opaque snapshot。benchmark 会检查整张图的计数一致。

720p RGB 平均通道误差 0.038857，最大差 97，>3 像素 4402/921600（0.477648%）；1080p 为 0.039231、86、9611/2073600（0.463493%）。完整连续 HDR/post 负载通过平均误差 <0.5 和 >3 像素 <1% 的门限，不能由上面的独立 26 帧测试推断整个场景逐像素相同。原始环境、计时分布、实际工作量和图像误差见 [720p 报告](benchmarks/native-particles-m1-720.json) / [1080p 报告](benchmarks/native-particles-m1-1080.json)。

## 默认切换前剩余范围

GPU 模拟绘制的 appearance/curves、GPU sorting、texture-sheet playback 和 trail/instance conversion 尚待迁移；resident emitter state、spawn/compact、force/noise/collision、events/readback 和 reset 生命周期已接入，详见 [模拟验证](NATIVE_PARTICLE_SIMULATION_VALIDATION.md)。Editor/GuavaUI 纹理/命令互操作及 DXIL 产物也仍未完成。默认保持 WGPU；完整功能、画面对照与性能验证通过后再切换默认并移除 WGPU。
