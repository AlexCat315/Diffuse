# NativeRenderer 透明、蒙皮和变形网格

NativeRenderer 的 r1–r4 网格路径现已包含透明绘制、实体独立 joint palette，以及由 RenderDeformableMesh 驱动的动态几何。Metal 和 SPIR-V 离线 shader 一起更新；macOS 实际验证使用 Metal。Windows/Linux 的 Vulkan 与 Windows DX12 原生编译和运行验证按用户要求暂缓。

## 数据与绘制契约

- NativeMesh 分别拥有 NativeMeshGeometry、材质与纹理。变形实例替换整个几何组，复用原网格的材质和采样资源。
- 透明物体按相机视线深度从后向前绘制，不参与实例合批、深度预通道或阴影，不写深度。透明 pass 位于编辑器网格之后、HDR tonemap 之前，使用 source-alpha 混合。
- 相机、深度和阴影 shader 共用加权蒙皮。每个 frame 上传 palette 的显式数量；越界 joint、空 palette 与删除 palette 使用单位矩阵。不同实体的姿态互相隔离，蒙皮实例避开 bind-pose 裁剪与静态 LOD。
- 共享 ShadowAtlasPlanner 将 joint 变换后的网格范围纳入单级阴影拟合。单位矩阵范围也保留，涵盖无权重与越界 joint；范围拟合使用通常的非负归一化 skin weights 契约。
- 变形顶点和索引通过 transient upload 加 GPU copy 写入 resident buffer。content revision 更新顶点，topology revision 更新索引；容量足够时复用 buffer。成功提交后才提交 revision 和资源替换；未提交的分配回收，已移除的资源按 NativeRHI 的帧退休规则释放。
- WGPU 参考路径同步修复 palette 缩短和清空时可能保留旧矩阵的问题，并与 Native 共用变形顶点转换及阴影规划。

## 本机画面对照

NativeAnimatedMeshTests 对照生产 WGPURenderer 的实际 viewport。连续帧涵盖输入顺序变化、相机轴排序与欧氏距离排序的区别、透明深度遮挡、重复帧清屏、镜像/双面、HDR/网格混合、两个独立 palette、多关节加权与旋转、palette 缩短/清空/删除/重加、蒙皮裁剪、透明蒙皮、阴影接收像素、变形内容和拓扑 revision、容量增长、删除后重新上传、无效/重复实体，以及录制失败后的版本重试。

每帧检查 RGB 平均通道误差 <0.5、差值 >3 的像素 <1%，另有姿态重置、顺序无关和接收阴影的实际像素断言。CPU 检查非有限矩阵拒绝及 joint 移动后阴影投影范围。原有 Native 窗口/PBR/静态网格与 NativeRHI 契约测试继续执行。

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|RenderThreadTests|MeshSurfaceAndVisibilityTests|RenderCameraMatricesTests|DeformableMeshUploadTests|RenderBackendGPUSmokeTests/(transparent|skinned|material)|ShaderCatalogTests'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

## Release 动态负载

`--scene animated` 在 PBR 探针上增加六个独立蒙皮实例、六个透明物体及一张 12×12 顶点的持续变形布面。每帧更新姿态和布面，不允许 WGPU 使用 opaque snapshot。相同 packet、相机、灯光、阴影和最终 RGB 用于两条路径；首次管线编译与预热不计入样本。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene animated --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-animated-1080
```

2026-10-08，Apple M1、macOS 27.0.1、Release。每条路径 540 个 CPU 样本与 3 个 completed-batch 样本；30 个预热帧不计入。每三帧等待 GPU 完成，整批耗时包含 CPU、驱动提交、GPU 和等待开销，不是 GPU timestamp 或窗口 FPS。

| 尺寸 | 路径 | CPU frame p50 (µs) | completed-batch p50 (ms/帧) | p95 (ms/帧) |
| --- | --- | ---: | ---: | ---: |
| 1280×720 | Native Metal | 903.9 | 2.505 | 2.568 |
| 1280×720 | WGPU Metal | 967.6 | 3.236 | 3.256 |
| 1920×1080 | Native Metal | 1104.5 | 3.357 | 3.364 |
| 1920×1080 | WGPU Metal | 1004.6 | 4.233 | 4.235 |

本场景的整批吞吐通过对照，1080p CPU frame p50 则增加约 0.10 ms，仍需在完整 renderer 的性能评估中保留这一指标。720p 最终 RGB 平均通道误差 0.000126、最大差 1、差值 >3 的像素 0；1080p 平均误差 0.000133、最大差 4、差值 >3 的像素 1/2,073,600，均通过像素门限。alpha 不参与 RGB 比较。

原始报告：[720p](benchmarks/native-animated-m1-720.json)、[1080p](benchmarks/native-animated-m1-1080.json)。探针同时输出实际 Native/WGPU PPM。受影响范围执行 83 项 NativeRHI XCTest、17 项 NativeRenderer XCTest、25 项渲染/资源/shader Swift Testing，均通过；阴影边界更新后又执行动画对照、4 项相机/阴影 CPU 测试和 3 项生产阴影 GPU 测试。Slang 工具链 5 项 Python 测试与 Swift 结构检查通过，既有 46 项超限指标未增加。

## 默认切换前剩余范围

EngineHost 默认仍使用 WGPU。粒子、风格化着色、r5 后处理以及 Editor/GuavaUI 的纹理与命令互操作仍须迁移和验证；DX12 renderer 的 DXIL 产物仍须补齐。完成全部功能覆盖、画面对照和性能门限之后，再切换默认 renderer 并移除 WGPU。
