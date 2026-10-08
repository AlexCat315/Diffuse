# NativeRenderer r5 后处理与历史缓存

NativeRenderer 已通过 NativeRHI 执行生产 r5 的 SSAO、SSR、TAA、Bloom、tonemap 与 FXAA。相同 RenderFramePlanner 决定执行顺序，PostEffectUniforms 直接提供两条 renderer 的生产参数；Metal 与 SPIR-V 离线产物一起更新。macOS 仅使用 Metal，Windows/Linux Vulkan 与 Windows DX12 的原生验证按用户要求暂缓。

## 执行与状态边界

SSAO/SSR 从场景深度重建法线，在 HDR ping-pong 纹理中处理不透明图像。编辑器网格随后进入 TAA，透明网格在历史采样之后合成，最后执行 Bloom、tonemap 和 FXAA。Bloom 保持独立输入，不覆盖用于 tonemap 的场景颜色。

RenderTemporalState 独立管理历史有效性、稳定帧数、设置快照和资源版本。resize、网格开关、关闭 TAA 或资源版本变化会使历史失效；成功提交 GPU 后才提交新的帧状态。即使一次 resize 已分配资源、随后录制失败，后续帧也会依据资源版本重新建立历史。

场景与后处理纹理共用 ViewportTargetAllocation 的 256 像素量化扩容策略。缩小 viewport 复用纹理，采样 scale/max 与 texel offsets 分别使用逻辑尺寸及分配容量。即使容量没有变化，逻辑尺寸变化也会重置历史与缓存；GPU 对照检查实际纹理 handle 在缩小时保留、容量增长时替换。直接向 swapchain 绘制的非 HDR 通道仍保持颜色/深度附件尺寸一致。

OpaqueSceneFingerprint 为两条 renderer 共用的场景指纹，保留排列无关性，并用 wrapping sum 与数量修复 XOR 对成对重复实例的抵消。运动期间跳过 SSR，稳定帧恢复全质量。TAA 在 6 个稳定帧后允许捕获不透明 HDR snapshot；缓存命中时恢复 snapshot，继续透明、Bloom、tonemap 和 FXAA，避免重复叠加透明层或编辑器网格。

NativeRHI 新增 `CopyPassEncoder.copyTexture`：在不同、同格式、单采样 2D 颜色纹理的 base mip 间复制左上区域。提交规划器追踪源/目标与队列依赖；Metal 使用 blit、Vulkan 使用 vkCmdCopyImage、DX12 使用 CopyTextureRegion。范围/格式拒绝和 Metal 链式实际读回检查未使用区域及位模式；Windows/Linux 的对应实现已写入但未进行原生编译或运行验证。

## 本机画面对照与功能检查

NativePostTests 比较生产 WGPURenderer 的实际 viewport：24 帧覆盖逐项启用效果、SSR 运动/静止、TAA 连续历史、网格开关、缩小/增长 viewport、关闭/重启 TAA、缓存命中、透明更新、分配后的失败 resize 恢复、r4/r5 切换与正交相机。另有 9 帧单独检查 SSAO、SSR、Bloom、FXAA 都实际改变像素，避免把空 pass 当作功能实现。

所有对照帧检查 RGB 平均通道误差 <0.5、差值 >3 的像素 <1%。实际 Native/WGPU PPM 保存于 `/tmp/guava-native-post`；本机还查看了组合效果和正交场景的读回图像。alpha 不参与 RGB 比较。

受影响范围执行 85 项 NativeRHI XCTest、23 项 NativeRenderer XCTest、32 项渲染线程/相机/生产 GPU/shader Swift Testing。包含实际 Metal 窗口的 r5 后处理呈现、缩放与错误输入恢复。旧测试中的“r5 尚未支持”和“稳定帧必须重画不透明通道”断言随功能更新并复测通过；容量策略更新后再次通过全部 NativeRenderer 测试和纹理复制测试。Slang 工具链 5 项 Python 测试及 Swift 结构检查通过；既有 46 项超限指标未增加。

```sh
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|RenderThreadTests|MeshSurfaceAndVisibilityTests|RenderCameraMatricesTests|RenderBackendGPUSmokeTests/(orthographic|opaqueCache|editorGrid|transparent|material)|ShaderCatalogTests'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

## Release 后处理负载

`--scene post` 使用 PBR 探针、透明物体和更亮的 point light，启用全部五种效果。相机每 12 帧移动一次，其间 SSR 恢复、TAA 收敛、缓存复用；两条 renderer 接收相同 packet。报告逐项记录实际执行的 pass 帧数和 draw 数，并要求 Native/WGPU 的 SSAO/SSR/TAA/Bloom/FXAA/tonemap 执行帧数相同且非零。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene post --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-post-1080
```

Apple M1 本机 Release，Metal 验证关闭，30 帧预热，3×180 帧测量：

| 分辨率 / renderer | CPU frame p50 / p95 (µs) | 完成批次 p50 / p95 (ms/frame) |
|---|---:|---:|
| 1280×720 NativeRHI Metal | 749.833 / 1446.208 | 2.511 / 2.526 |
| 1280×720 WGPU Metal | 853.625 / 1170.250 | 3.575 / 3.622 |
| 1920×1080 NativeRHI Metal | 761.292 / 1695.583 | 4.283 / 4.456 |
| 1920×1080 WGPU Metal | 942.958 / 2125.833 | 6.208 / 6.289 |

完成批次含每三帧等待 GPU 的时间，反映该负载的吞吐，不是 GPU timestamp 或显示 FPS。CPU 每项 540 个样本，批次每项 3 个样本。720p NativeRHI CPU p95 高于 WGPU，不能据此声称所有延迟指标均改善；批次 p50 分别降低约 29.8% / 31.0%。

720p RGB 平均通道误差 0.043850，最大通道差 74，>3 的像素 4722/921600（0.5124%）；1080p 分别为 0.045278、86、10407/2073600（0.5019%）。两者均通过平均误差 <0.5、>3 像素 <1% 的现有门限，并非逐像素完全相同。实际图像及连续帧对照仍保留供检查。

两条路径在 540 个测量帧中均执行 SSAO/TAA 315 帧、SSR 270 帧、Bloom/tonemap/FXAA/透明绘制 540 帧；深度、阴影、天空、base 和网格均执行 315 帧。原始环境、时间分布、pass 帧数/draw 数和误差见 [720p 报告](benchmarks/native-post-m1-720.json) / [1080p 报告](benchmarks/native-post-m1-1080.json)。

## 默认切换前剩余范围

EngineHost 默认仍使用 WGPU。风格化已在后续阶段迁移，见 [风格化验证](NATIVE_STYLIZED_VALIDATION.md)。粒子 GPU 模拟、Editor/GuavaUI 纹理/命令互操作和 DXIL 产物仍须完成。全部功能、画面对照与性能门限完成后再切换默认 renderer，然后移除 WGPU 运行时与参考依赖。
