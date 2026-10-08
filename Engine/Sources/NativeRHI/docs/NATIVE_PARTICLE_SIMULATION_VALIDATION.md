# NativeRenderer resident GPU 粒子模拟

NativeRHI 已接入 GPU spawn append、物理模拟、存活状态压缩、metadata reset/finalize 与逐帧事件回读。这一阶段支持 `renderOnGPU == false` 的 simulation batch；GPU 排序、appearance/curve、texture-sheet 与 trail/instance 转换仍明确拒绝，继续作为下一阶段迁移范围。默认 renderer 仍为 WGPU。

## 状态与提交

模拟数据的二进制布局由 `ParticleSimulationGPUData.swift` 统一拥有，WGPU/NativeRHI 直接使用同一 batch 构造 uniforms/state，并共用 metadata/event 到运行时 snapshot 的转换。state 为 80 字节、uniforms 272 字节、metadata 32 字节、event 48 字节。共享 ABI 的 dispatch count 存在 Float32 中，Native 在分配前限制 capacity 不超过 2²⁴，保证整数精确并避免越界取整。WGPU 的内部编码 API 改为接收整个 `RenderParticleSimulationBatch`，第一方调用和 GPU 测试同时更新。

`NativeParticleSimulationState` 只拥有 resident state、compact scratch、metadata 和 events；程序按 physical workgroup size 独立缓存。emitter 身份决定 residency，换序时继续使用已有 GPU 数据，不上传过时 CPU 粒子。匿名批次每帧重新播种。移除/空 payload 后清除 residency；容量不足或工作组改变时分配并重新播种。容量足够时沿用既有 grow-only 分配策略，持续模拟的 dispatch count 是实际 resident capacity，统计记录该实际工作量。

新资源播种前清零整个 state，避免未使用尾部包含未初始化数据；每帧清理 compact scratch，GPU 原子 append/compaction 和生产 WGSL 保持一致。原子压缩的存储顺序不保证稳定，物理结果按粒子身份对照；渲染可见性压缩仍是单独的稳定算法。

所有播种和 metadata 上传通过 frame-owned transient buffer 录制 copy；失败/未提交的录制不改变已有 GPU 数据，不提前设置 initialized 或退休旧 residency。只有 Device.submit 成功后才 commit proposed state 和 event readbacks。发生部分提交错误时沿用 Device 的失效规则。

逐帧独立复制 metadata 和 event buffer，下一帧 reset 不会覆盖未读事件。consumer 的 drain 接口保留 emitter/slot、存活/死亡/碰撞/生成/丢弃/压缩计数和 generation/appearance 信息，沿用现有场景事件桥。待读队列上限 64，`maxSnapshots == 0` 不消费；读失败保留请求供重试。同步 `Device.readBufferData` 在 endFrame 后等待已提交工作，按字节范围读回；常规 render 编码不调用它。

## 跨平台程序

Slang 六个 kernel 提供 Metal 和 SPIR-V 离线产物。噪声、uniform/curl vector field、radial/vortex force、local/world plane collision、angular velocity、aging/death、spawn overflow 及 compact 的公式和边界沿用生产 WGSL。

`ParticleGPUSimulationPlan` 允许 1–256 内任意工作组大小。Slang constant ID 0 对应 physical local-size X；Metal 使用 function constants，Vulkan 使用 VkSpecializationInfo 和 SPIR-V LocalSizeId。artifact 的默认大小也显式特化，避免离线元数据和实际线程数分离；设备检查/启用 Vulkan maintenance4。serial reset/finalize 使用一个线程。

DX12 不支持运行时改变 numthreads。Windows 离线生成器为四个并行 kernel 编译完整 1–256 的固定 DXIL 代码族，校验每个变体除 local size 外 ABI 完全相同；运行时选择对应代码。缺少 family/variant 时明确报错，不按错误线程数 dispatch。macOS 本轮没有生成 DXIL。

macOS 只执行 Metal，不使用 MoltenVK。Vulkan 面向 Windows/Linux，DX12 面向 Windows；这些原生源码与 readback 接口按用户要求暂不做原生编译或运行验证。

## 本机验证

Apple M1 的实际 Metal GPU 对照覆盖 1/37/64/255/256 个 physical threads，分别处理 257/257/131/257/513 个粒子，并跨多个工作组。Native/WGPU 存活 state 的所有向量与身份字段对照（Float 容差 0.0005），事件按 source index/trigger 排序后逐字段对照；存活、死亡、碰撞、事件总数和压缩计数一致。清理后的 inactive state 全部字节为零。相同输入、seed 和 time 的匿名重播种复现物理结果。

生命周期测试覆盖两个 emitter 换序、stale CPU seed、跨帧累计、未提交录制、resident spare-slot spawn、满容量 spawn drop、移除/恢复、工作组改变、扩容、匿名每帧重播种和 64 个待读 snapshot 上限。NativeRenderer 的完整 renderChecked 还验证统计、consumer 事件发布、非法输入拒绝和恢复。独立 NativeRHI 测试回读 uint/int/float/bool constants、五种 physical group sizes，以及 byte-offset/bounds；37 的离线默认与 Slang 源默认 64 不同，验证未传 override 时实际仍 dispatch 37。

本机完整回归通过：87 项 NativeRHI XCTest、36 项 NativeRenderer XCTest、44 项 shader catalog/生产 GPU Swift Testing。共享 metadata/event 转换调整后，4 项 Native simulation、2 项 specialization 与 37 项生产 GPU 测试再次通过。Slang 工具链 8 项 Python 测试通过；Swift maintainability 仍为 46 项既有超限指标，无新增。

验证命令：

```sh
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|ShaderCatalogTests|RenderBackendGPUSmokeTests'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

本阶段没有 GPU 模拟绘制的图像或性能结论；此前 CPU 粒子绘制/稳定压缩的图像与 Release 数据见 [粒子绘制验证](NATIVE_PARTICLE_VALIDATION.md)。接完排序、appearance/curve 与 instance conversion 后再跑真实模拟绘制对照及性能 gate。Editor/GuavaUI 互操作与 DXIL 产物也仍待完成，完整覆盖之前不切换默认、不移除 WGPU。
