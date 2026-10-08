# NativeRenderer resident GPU 粒子模拟

NativeRHI 已接入 GPU spawn append、物理模拟、存活状态压缩、metadata reset/finalize 与逐帧事件回读。`renderOnGPU` 现可直接从 resident state 执行 GPU 排序、appearance/curve、texture-sheet 与 trail/instance 转换，再进入稳定可见性压缩和 indirect draw。默认 renderer 仍为 WGPU。

## 状态与提交

模拟数据的二进制布局由 `ParticleSimulationGPUData.swift` 统一拥有，WGPU/NativeRHI 直接使用同一 batch 构造 uniforms/state，并共用 metadata/event 到运行时 snapshot 的转换。state 为 80 字节、uniforms 272 字节、metadata 32 字节、event 48 字节。共享 ABI 的 dispatch count 存在 Float32 中，Native 在分配前限制 capacity 不超过 2²⁴，保证整数精确并避免越界取整。WGPU 的内部编码 API 改为接收整个 `RenderParticleSimulationBatch`，第一方调用和 GPU 测试同时更新。

`NativeParticleSimulationState` 只拥有 resident state、compact scratch、metadata 和 events；程序按 physical workgroup size 独立缓存。emitter 身份决定 residency，换序时继续使用已有 GPU 数据，不上传过时 CPU 粒子。匿名批次每帧重新播种。移除/空 payload 后清除 residency；容量不足或工作组改变时分配并重新播种。容量足够时沿用既有 grow-only 分配策略，持续模拟的 dispatch count 是实际 resident capacity，统计记录该实际工作量。

新资源播种前清零整个 state，避免未使用尾部包含未初始化数据；每帧清理 compact scratch。Native/生产 WGSL 的 spawn 以不可变 append cursor 加输入编号分配，存活压缩使用单个 physical workgroup 分块前缀和，保留源粒子顺序。此前原子分配/压缩会因工作组调度改变预算所选粒子和相同排序键的先后；两条路径已一起改为稳定算法。压缩仍只有一个 workgroup，大容量吞吐需要独立评估。渲染可见性压缩继续使用单独的稳定算法。

所有播种和 metadata 上传通过 frame-owned transient buffer 录制 copy；失败/未提交的录制不改变已有 GPU 数据，不提前设置 initialized 或退休旧 residency。只有 Device.submit 成功后才 commit proposed state 和 event readbacks。发生部分提交错误时沿用 Device 的失效规则。

逐帧独立复制 metadata 和 event buffer，下一帧 reset 不会覆盖未读事件。consumer 的 drain 接口保留 emitter/slot、存活/死亡/碰撞/生成/丢弃/压缩计数和 generation/appearance 信息，沿用现有场景事件桥。待读队列上限 64，`maxSnapshots == 0` 不消费；读失败保留请求供重试。同步 `Device.readBufferData` 在 endFrame 后等待已提交工作，按字节范围读回；常规 render 编码不调用它。

## 排序与实例转换

两条 renderer 共用 `ParticleInstanceGPUData.swift` 的二进制模型、appearance/curve 打包与 bitonic pass 计划；instance uniforms 为 240 字节、appearance 48 字节、keyframe/sort item 各 16 字节。appearance 最多 64 个；曲线共用 128 个 keyframe 配额，截断保留末尾 key。默认值、耗尽时 fallback 和重复时间处理与生产路径相同。

GPU 支持距离升/降序、年龄老/年轻优先，以及 source index 的同键排序。按 render budget 选取源范围，再以 2 的幂补齐排序项；padding 不可成为 storage buffer 地址。转换覆盖五种 texture-sheet playback、随机起始帧、UV 子矩形、六种曲线、authored appearance/sizeScale、世界变换、速度对齐/拉伸、预算 alpha 和渐细/渐隐 trail。

整帧 GPU source buffer 同时预留 CPU 粒子尾部，CPU upload copy 录在 GPU 转换之后；相邻 CPU texture/blend batch 保持顺序，GPU emitter batch 先绘制。source/sort 新分配和 residency 一起在成功 submit 后提交。此次完整对照还修复了 WGPU 的整帧预分配：编码不同 emitter 中途扩容曾丢掉较早批次的输出；空批次现在释放 emitter residency，恢复时重新播种。WGPU 统计通过 encoding 的实际 dispatch count 报告工作量，持续模拟不再把较小 CPU seed 数量误当 resident capacity。

## 跨平台程序

Slang 九个 kernel 提供 Metal 和 SPIR-V 离线产物。噪声、uniform/curl vector field、radial/vortex force、local/world plane collision、angular velocity、aging/death、spawn overflow 及 compact 的公式和边界沿用生产 WGSL。

`ParticleGPUSimulationPlan` 允许 1–256 内任意工作组大小。Slang constant ID 0 对应 physical local-size X；Metal 使用 function constants，Vulkan 使用 VkSpecializationInfo 和 SPIR-V LocalSizeId。artifact 的默认大小也显式特化，避免离线元数据和实际线程数分离；设备检查/启用 Vulkan maintenance4。serial reset/finalize 使用一个线程。

DX12 不支持运行时改变 numthreads。Windows 离线生成器为七个可变工作组 kernel 编译完整 1–256 的固定 DXIL 代码族，校验每个变体除 local size 外 ABI 完全相同；运行时选择对应代码。缺少 family/variant 时明确报错，不按错误线程数 dispatch。macOS 本轮没有生成 DXIL。

macOS 只执行 Metal，不使用 MoltenVK。Vulkan 面向 Windows/Linux，DX12 面向 Windows；这些原生源码与 readback 接口按用户要求暂不做原生编译或运行验证。

## 本机验证

Apple M1 的实际 Metal GPU 对照覆盖 1/37/64/255/256 个 physical threads，分别处理 257/257/131/257/513 个粒子，并跨多个工作组。Native/WGPU 存活 state 的所有向量与身份字段对照（Float 容差 0.0005），事件按 source index/trigger 排序后逐字段对照；存活、死亡、碰撞、事件总数和压缩计数一致。清理后的 inactive state 全部字节为零。相同输入、seed 和 time 的匿名重播种复现物理结果。

生命周期测试覆盖两个 emitter 换序、stale CPU seed、跨帧累计、未提交录制、resident spare-slot spawn、满容量 spawn drop、移除/恢复、工作组改变、扩容、匿名每帧重播种和 64 个待读 snapshot 上限。NativeRenderer 的完整 renderChecked 还验证统计、consumer 事件发布、非法输入拒绝和恢复。独立 NativeRHI 测试回读 uint/int/float/bool constants、五种 physical group sizes，以及 byte-offset/bounds；37 的离线默认与 Slang 源默认 64 不同，验证未传 override 时实际仍 dispatch 37。

`NativeParticleInstanceTests` 的 24 组实际 GPU kernel 对照覆盖 1/37/64/255/256 个线程、四种排序、五种 texture-sheet 模式、六种曲线、无效 appearance index fallback、超过 64 个 appearance / 128 个 keyframe 的截断、死亡粒子、预算和 trail。逐项检查所有 instance 的 28 个 Float（容差 0.0001）、sort key/index 与实际 pass/workgroup 数；输出前后预填字节验证非零 baseInstance 和写入范围。

22 个连续完整绘制帧覆盖两个 emitter 换序、过时 CPU seed、spawn、整帧 source 扩容、预算改变、清空/恢复、viewport 扩大/缩小、混合 CPU/GPU 粒子、alpha/additive、12 格真实 BMP atlas、HDR Bloom/TAA/FXAA。resident state 和 converted instance 按实际存储顺序逐 Float 比较（容差 0.0001），身份字段精确比较，并拒绝非有限值；不先按身份重排。模拟/实例/sort/cull/indirect 的统计与 snapshot 数量一致。该序列 RGB 最大通道误差 1，>3 像素为 0；最高平均通道误差 0.00002713。

完整执行的 87 项 NativeRHI XCTest、39 项 NativeRenderer XCTest 和 37 项生产 GPU Swift Testing 均通过。着色器目录测试同步稳定算法的资源断言后，7 项单独复跑通过；收紧 UInt 身份/有限值检查后，3 项 instance 测试再次通过。Slang 工具链 8 项 Python 测试通过；Swift maintainability 仍为 46 项既有超限指标，无新增。

验证命令：

```sh
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|ShaderCatalogTests|RenderBackendGPUSmokeTests'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

## Release 模拟绘制探针

`--scene simulation` 在完整 HDR post graph 中提交两个常驻 emitter，各 1,024 个粒子，physical workgroup 分别为 37 / 255；CPU seed 保持不变，GPU 连续执行 noise/curl/vortex、aging、rotation、spawn/drop、distance/age sorting、authored curves 和速度对齐 trail 转换。共 6,144 个 GPU instance，再混入 32 个 CPU ribbon。相机十二帧保持，以覆盖 opaque cache hit。运行前后都没有 CPU 回读 state 来生成绘制实例。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene simulation --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --backends metal --output /tmp/guava-native-simulation-1080
```

Apple M1，Release，validation 关闭，30 帧预热和 3×180 帧测量：

| 分辨率 / renderer | CPU frame p50 / p95 (µs) | 完成批次 p50 / p95 (ms/frame) |
|---|---:|---:|
| 1280×720 NativeRHI Metal | 1179.417 / 1388.916 | 2.984 / 3.003 |
| 1280×720 WGPU Metal | 3193.667 / 3634.625 | 9.013 / 9.019 |
| 1920×1080 NativeRHI Metal | 1129.416 / 1807.125 | 4.583 / 4.636 |
| 1920×1080 WGPU Metal | 3437.000 / 4971.458 | 11.454 / 11.473 |

该场景 CPU p50 分别降低约 63.1% / 67.1%，完成批次 p50 降低约 66.9% / 60.0%。每项 CPU 分布 540 个样本，批次分布 3 个样本；批次计时包含每三帧显式等待 GPU 和 packet 构造，衡量整帧吞吐，不能当成 GPU timestamp 或显示 FPS。此结果不替代其他场景的性能 gate，此前 CPU 粒子场景仍记录了个别 CPU 分位回退。

两条路径逐项要求并通过工作量相等检查：1,080 个 simulation batch、1,105,920 个实际 simulation/sort 粒子、17,820 个 physics workgroup、60,480 次 sort pass / 997,920 个 sort workgroup、52,380 个 instance workgroup、3,317,760 个 GPU render instance、3,335,040 个含 CPU 粒子的 cull candidate、1,620 个 cull workgroup / indirect draw。事件分配容量和回读字节、全图 pass frames/draws 也相等；opaque pass 各 315 帧，SSR 270 帧，粒子/Bloom/tonemap/FXAA 各 540 帧。

最终 RGB 图像通过平均通道误差 <0.5 / >3 像素 <1% 门限：720p 为 0.042205、最大 76、4,676/921,600（0.507378%）；1080p 为 0.042701、最大 86、10,260/2,073,600（0.494792%）。完整 post 场景不能由独立 22 帧测试推断逐像素相同。原始环境、分位数和工作量见 [720p 报告](benchmarks/native-simulation-m1-720.json) / [1080p 报告](benchmarks/native-simulation-m1-1080.json)；本机 PPM 保存在对应的 `/tmp/guava-native-simulation-*` 输出目录。

此前 CPU 粒子绘制/稳定压缩的图像与 Release 数据见 [粒子绘制验证](NATIVE_PARTICLE_VALIDATION.md)。Editor/GuavaUI 互操作与 DXIL 产物仍待完成，完整覆盖及性能 gate 通过之前不切换默认、不移除 WGPU。
