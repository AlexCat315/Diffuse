# NativeRenderer 场景迁移

NativeRenderer 已从独立网格 consumer 发展为真实场景 consumer，支持索引绘制、静态网格、子网格材质、不透明和 alpha mask、实例化、镜像变换、相机裁剪与距离 LOD。深度预通道只写 depth32，r1/r2/r3 基础几何 pass 写 BGRA8，并可以加载几何深度叠加编辑器网格。窗口与离屏目标共享资源管理，resize 会替换并延迟销毁旧目标。

目前支持 r1/r2/r3/r4 和 unlit/baseColor/worldNormal/roughness/metallic 查看模式。材质查看模式沿用现有 WGSL 的 inverse-ACES 输出规则；在这些早期 LDR 阶段，它们还没有经过后续 tonemap。这是画面对照的共同输入约定，不能把它们当作最终 PBR 画面。

完整替换目标仍在推进：PBR 光照、级联/多光源阴影、HDR 天空和 tonemap 已迁移，见 [PBR 验证](NATIVE_PBR_VALIDATION.md)；透明/动画、r5 后处理和风格化见 [动画验证](NATIVE_ANIMATION_VALIDATION.md)、[后处理验证](NATIVE_POST_VALIDATION.md) 和 [风格化验证](NATIVE_STYLIZED_VALIDATION.md)。粒子、编辑器/GuavaUI viewport 互操作与游戏内 HUD 已接入 NativeRHI 并在 Metal 对照验证。主／辅助窗口宿主、整体性能门槛和默认 renderer 切换仍在推进。NativeRenderer 对尚未支持的场景明确报错，避免用缺失的画面冒充完整渲染。默认 EngineHost 仍使用 WGPU。

## 接入与资源

```swift
let device = try NativeRHI.Device.make(DeviceConfig(preferredBackends: [.metal]))
let renderer = try NativeRenderer(device: device)
let settings = RenderSettings(stage: .r2MultiObjectDepth, debugViewMode: .unlit)
host.queueRenderSettings(settings)
host.start(renderConsumer: renderer)
```

EngineHost/RenderThread 发送原有 RenderPacket，不创建第二套场景模型。NativeRenderer 的可变状态由渲染线程拥有。工具和测试调用 renderChecked，能直接捕获错误；普通 consumer 路径记录 lastError。colorTexture 返回借用的 NativeRHI Texture，可进行原生读回；currentViewportSurfaceState 在成功提交后发布持有 TextureResource 的离屏图像与 used/capacity region。UI geometry / snapshot 可长期保留此资源，直接交给同 device 的 NativeDrawListRenderer 采样。窗口 swapchain 图像不作为持久 viewport 发布。详见 [UI/viewport 验证](NATIVE_UI_VALIDATION.md)。

资源由 NativeMeshStore 管理。它读取 AssetRegistry 原子返回的 MeshAssetCatalog，版本不变时无需复制/哈希大网格；重载、替换、删除、reset 都会改变版本。当前版本更新以事务方式重建导入资源，失败保留旧资源，下次可重试；后续可以细化到逐资产版本。稀疏 meshIndex 通过字典管理，内置 cube 和 OBJ fixture 保留在 0/1。可注入独立 AssetRegistry，各 renderer 的裁剪边界取自自己的 GPU 资源目录。

材质解析通过 ResolvedMeshMaterial 与 WGPU 共用。导入 baseColorFactor 与运行时覆盖相乘；本轮修正了 WGPU 丢失导入 RGB 因子的行为。MeshInstanceUniforms 的 160 字节布局也由两条路径共用。顶点沿用 MeshAsset 的 96 字节布局。

Slang 仅在离线生成阶段使用。基础几何/深度产物已捆绑 Metal 和 SPIR-V；运行时只加载 ShaderArtifact。DX12 管线使用同一抽象，但本机无 DXC，尚未生成/验证该 pass 的 DXIL。可在支持 DXC 的环境运行 `compile-native-renderer-shaders.py --targets dxil`。

## 本机验证

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|AssetRegistryTests|MeshAssetCatalogTests|MeshSurfaceAndVisibilityTests|RenderThreadTests'

python3 scripts/check-swift-maintainability.py
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

NativeOpaqueTests 对照生产 WGPURenderer（包括实际资源目录与 frame planner），而非新写一个同构 WGSL 参考：

- 36 个 cube 实例与已有 FinalBaseMesh.obj，涵盖五种材质查看模式、实例合批、镜像、正交相机、编辑器网格及有/无深度预通道。
- NativeSceneFixture.gltf 经真实 GLTFImporter 导入两个索引 primitive，嵌入 PNG alpha 棋盘与独立材质；验证纹理、材质因子、遮罩深度、遮挡、实例顺序与运行时覆盖。
- 模型替换/移除、无效目录回滚、稀疏 slot、18 个持续帧与 resize，及裁剪/LOD 的开关。
- Metal 的 CAMetalLayer 实际呈现与 resize，以及 RenderThread 上的真实索引场景包。

Vulkan encoder 使用负高度 viewport 并调整 y，与其他后端的 +Y 向上 clip space 约定一致，统一图像方向、剔除与 front-facing；不要求每个 shader 单独翻转。约定依据 [Khronos VkViewport](https://docs.vulkan.org/refpages/latest/refpages/source/VkViewport.html)。本轮没有 Windows/Linux 原生 Vulkan 图像验证。

真实网格探针还发现 AccessTracker 持续累积重复的只读访问与历史诊断 hazard，导致提交耗时随帧数增长。本轮按 queue/range 合并读取并保留 stage 并集，移除运行时历史诊断列表。5000 个只读帧后的跨队列写入测试验证依赖仍完整；提交回滚和 GPU hazard 测试继续覆盖实际同步。

## 性能测量

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene mesh --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-mesh-1080
```

`--scene grid` 保留独立网格探针，默认仍为 grid。mesh 使用同一个 RenderPacket、37 个实例、相同材质查看模式与深度/基础几何输出。原生产 WGPU 路径还包含空透明/粒子 pass 与视口发布；Native 深度 pass 不写弃用颜色。两者最终 RGB 进行自动对照，均不使用 HDR opaque snapshot 缓存。

剔除初次资源/管线编译与预热，540 个 CPU 样本；每三帧显式等待 GPU 完成，记录三次整批耗时除以帧数。指标包括提交和等待成本，不是 GPU timestamp、窗口 FPS 或完整场景 renderer 的性能。测量之后读回 RGB，并生成 JSON/PPM；颜色误差门限为平均每通道 <0.5、差异 >3 的像素 <1%。alpha 不参与 RGB 误差统计。

本机 Apple M1、macOS 27.0.1、Release、2026-10-08 的测量：

| 分辨率 | 路径 | CPU 帧 p50 (µs) | 完成批次 p50 (ms/帧) | p95 (ms/帧) |
| --- | --- | --- | --- | --- |
| 1280×720 | native-metal | 122.8 | 1.085 | 1.106 |
| 1280×720 | wgpu-metal | 243.7 | 1.406 | 1.434 |
| 1920×1080 | native-metal | 133.8 | 0.996 | 1.015 |
| 1920×1080 | wgpu-metal | 312.5 | 1.585 | 1.602 |

两个分辨率下 Native Metal 与生产 WGPU/Metal 的最终 RGB 完全一致（最大通道差 0）。这些历史 mesh 测量不代表完整 PBR 场景的性能，PBR 新数据见专门验证文档。历史报告中的 Vulkan 样本不属于 Windows/Linux 平台验证。

原始数据：[720p](benchmarks/native-mesh-m1-720.json)、[1080p](benchmarks/native-mesh-m1-1080.json)。PNG 画面保存在 `Engine/.build/validation/native-mesh-720/` 与 `native-mesh-1080/`，不提交构建生成的图片。

本轮平台调整后仅在 macOS 上执行 Metal GPU 检查，Vulkan 不再作为 macOS 后端或回退。Windows/Linux Vulkan 与 DX12 已有原生实现，本轮按要求不做原生验证；DX12 renderer 的 DXIL 离线产物仍待生成。
