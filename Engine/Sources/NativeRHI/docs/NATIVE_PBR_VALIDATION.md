# NativeRenderer PBR、阴影与 HDR

NativeRenderer 的 r4 路径已执行实际 PBR 光照、法线/金属粗糙度纹理、studio IBL、多光源级联阴影、HDR 天空、HDR 编辑器网格和 ACES/sRGB tonemap。深度/阴影/相机 pass 共享静态网格资源和材质分组；两条 renderer 共享 ShadowAtlasPlanner，直接使用原 RenderPacket、SceneLightUniforms 和 ShadowUniforms。

NativeRHI texture transfer 增加显式 mip/layer subresource，供完整 IBL mip 链上传和读回使用；Metal、Vulkan 与 DX12 的调用方同步更新。Metal 的 mip 采样/array 往返测试检查不同层级的实际 GPU 值以及无效范围。Vulkan/DX12 的对应原生实现本轮未编译或运行验证。

macOS 构建与探针仅使用 Metal；Vulkan 面向原生 Windows/Linux。SPIR-V 离线产物已捆绑，DX12 renderer 的 DXIL 产物仍需在具有 DXC 的环境生成。平台设置、HWND/Xlib/Wayland 呈现边界见 [RHI 契约](RHI_CONTRACT.md)。

## 画面对照与功能覆盖

`NativePBRTests` 对照生产 WGPURenderer，而非重写一个相同算法的 WGSL 参考。8 个连续帧涵盖真实 OBJ、glTF 索引 primitive、alpha mask、纹理与运行时材质、directional/point light、阴影开关、单/三级级联与第二个阴影光源、exposure、debug normal、正交相机、清空光源/环境强度、resize 和 r4→r3 切换。阴影开启必须改变实际接收像素；每帧 RGB 均检查平均通道误差 <0.5、差值 >3 的像素 <1%。

CPU 验证还检查未迁移的 UI/TAA packet 会在开始 GPU 帧之前明确拒绝，恢复支持的输入后可继续使用。Metal 窗口测试验证 CAMetalLayer 的 HDR 呈现、持续帧、resize、阴影分辨率变更，以及错误 packet 后恢复。现有 grid/opaque 测试继续覆盖实例化、镜像/双面、遮罩深度、资源替换/删除/回滚、裁剪、LOD 和渲染线程的真实 packet。

最终选择范围执行 83 项 NativeRHI XCTest、13 项 NativeRenderer XCTest、26 项渲染线程/可见性/生产 GPU 与 shader catalog Swift Testing、6 项资产目录 Swift Testing，均无失败或跳过。Slang 工具链 5 项 Python 测试通过；Swift 结构检查通过，既有 46 项超限指标未增加。

生产 WGPU 从 r3 才发布可读回的 viewport，因此 WGPU 画面对照使用 r3/r4。r1 与深度预通道的输出等价由 NativeOpaqueTests 单独检查，不把未发布的 viewport 误判为 GPU 渲染失败。

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|RenderThreadTests|MeshSurfaceAndVisibilityTests|MeshAssetCatalogTests|AssetRegistryTests|RenderBackendGPUSmokeTests/(material|directionalShadow|multiDirectionalShadow|directionalCascades|editorGridPaints)|ShaderCatalogTests'

SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
python3 scripts/check-swift-maintainability.py --report
```

## Release 性能探针

`--scene pbr` 使用 38 个真实 mesh instance、接收平面、两个阴影 directional light 和一个 point light，每帧轻微移动相机，防止 WGPU 复用 opaque snapshot。Native/WGPU 的 packet、相机、光照、阴影分辨率和最终 RGB 相同；WGPU 还含空透明/粒子 pass 及 viewport 发布。首次资源/管线编译与 30 个预热帧不计入测量。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene pbr --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-pbr-1080
```

2026-10-08，Apple M1、macOS 27.0.1、Release。每条路径 540 个 CPU 样本，3 个 completed-batch 样本。每三帧等待 GPU 完成，完成批次耗时包含 CPU、驱动提交、GPU 与等待开销，不是 GPU timestamp、窗口 FPS 或整个引擎的性能。

| 尺寸 | 路径 | CPU frame p50 (µs) | completed-batch p50 (ms/帧) | p95 (ms/帧) |
| --- | --- | ---: | ---: | ---: |
| 1280×720 | Native Metal | 418.6 | 2.105 | 2.195 |
| 1280×720 | WGPU Metal | 792.0 | 2.975 | 3.005 |
| 1920×1080 | Native Metal | 859.9 | 3.056 | 3.074 |
| 1920×1080 | WGPU Metal | 969.1 | 4.088 | 4.133 |

最终 RGB：720p 平均通道误差 0.000130、最大差 1、差值 >3 的像素 0；1080p 平均误差 0.000137、最大差 4、差值 >3 的像素 1/2,073,600。两种分辨率均通过探针门限。alpha 不参与 RGB 比较。

原始数据：[720p](benchmarks/native-pbr-m1-720.json)、[1080p](benchmarks/native-pbr-m1-1080.json)。探针同时输出实际读回的 Native/WGPU PPM。

## 默认切换前剩余范围

默认 EngineHost 仍使用 WGPU。NativeRenderer 会明确拒绝尚未支持的透明网格、蒙皮/变形、粒子、其他后处理和风格化路径；Editor/GuavaUI 的纹理/命令互操作仍在迁移。上述功能覆盖与画面/性能验证完成后再切换默认 renderer，然后移除 WGPU 运行时和参考依赖。Windows/Linux 原生验证按用户要求暂不作为本轮执行任务。
