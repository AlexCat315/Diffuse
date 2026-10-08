# NativeRenderer 风格化角色路径

NativeRenderer 已迁移生产的 toon 角色着色、inverted-hull 描边和 ink paper HDR 后处理。Metal 和 SPIR-V 离线产物一同更新；macOS 仅使用 Metal，Windows/Linux Vulkan 与 Windows DX12 的原生验证按用户要求暂缓。

## 输入、管线与执行

风格化着色沿用生产的 toon ramp、ambient/directional/point/spot Lambert、normal map、rim、材质偏色和纸张 grain。StylizedCharacterUniforms 从完整 StylizedCharacterStyle 创建，两条 renderer 使用同一个转换。透明网格使用风格化颜色和 alpha 混合；mask coverage、双面 normal 翻转和镜像 winding 保持生产语义。风格化着色与生产路径相同，不采用 PBR 的 IBL、debug view 或阴影接收算法。

NativeMeshVertexLayout 增加原 MeshAsset stream 中的 `material_index` 标量；缓冲布局与 stride 保持一致。NativeRHI 的标量 float 顶点格式对应 Metal float、Vulkan R32_SFLOAT 和 DX12 R32_FLOAT。着色、深度、阴影与描边共用 skinMatrix 和显式 palette count；描边在蒙皮后沿 local normal 扩张，剔除正面、保留 depth test、不写深度。透明物体不参加描边，零厚度 authored mesh 通过两条路径共享的 MeshOutlinePolicy 排除。

NativeMeshShaders 独立拥有着色模块及 14-slot ABI 校验；NativeMeshPass 保留材质管线变体与帧绑定职责。模块创建失败会清理已创建模块，避免把新增模块堆入 renderer 的扁平状态。inkPaperPost 按 RenderFramePlanner 排序，在 HDR ping-pong 纹理上执行，进入 SSAO/SSR/TAA 和不透明缓存之前；r1–r3 与生产行为相同，仅执行着色和描边。

style 中非有限输入在 GPU frame/资源准备之前拒绝；失败输入不会提交历史或缓存状态。风格修改、开关、stage/viewport 变化继续由共享指纹、资源版本和 RenderTemporalState 管理。authored defaults 与持久化格式没有变更。

## 本机功能与画面对照

NativeStylizedTests 使用生产 WGPURenderer 的真实 offscreen 输出：默认/关闭 grain 2 帧，加 30 个连续帧覆盖 imported texture/normal map/mask、非零 material index、material bias、outline width、grain strength、toon/ink 色彩、spot light、镜像、透明物体、蒙皮 palette 缩减/删除/恢复、变形网格更新、正交相机、viewport 缩小/扩容、r3/r4/r5 切换、全后处理、SSR 运动恢复、TAA 收敛、snapshot 复用、非法 style 恢复及风格关闭。关键设置还必须改变实际像素。

独立薄片用例只保留一个朝上的平面，从背面观察；检查单面不显示、双面确实显示，并重复镜像情形，确认不会被描边涂黑。实际 Metal 窗口另检查风格化 + 全后处理的连续呈现、缩放和错误输入恢复。

每个 RGB 对照帧检查平均通道误差 <0.5、差值 >3 的像素 <1%。图像保存于 `/tmp/guava-native-stylized`。默认场景与多项材质/动画参数的对照最大差为 1；连续历史后少量边缘差值另由逐帧门限检查，不能据此声称所有帧逐像素相同。

本机执行 85 项 NativeRHI XCTest、28 项 NativeRenderer XCTest（包含追加的薄片背面用例），以及 9 项 shader catalog/生产风格化 GPU Swift Testing。总计 37 帧新增实际 RGB 对照；所有检查通过。Slang 工具链 5 项 Python 测试和 Swift 结构检查通过，既有 46 项超限指标未增加。

```sh
GUAVA_WGPU_BACKEND=metal GUAVA_RUN_GPU_SMOKE_TESTS=1 \
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.|ShaderCatalogTests|RenderBackendGPUSmokeTests/(stylized|materialDoubleSided)'
python3 scripts/check-swift-maintainability.py --report
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/test-rhi-shader-toolchain.py
```

## Release 负载

`--scene stylized` 使用完整 post 探针、toon 着色、描边、纸张处理和透明物体，持续移动相机。两条 renderer 接收相同 packet，测量中要求描边/纸张通道实际 pass 帧数、draw 数一致且非零；禁止 WGPU 复用不透明 snapshot。

```sh
swift build -c release --package-path Engine --product NativeRHIPassProbe --jobs 4
GUAVA_WGPU_BACKEND=metal Engine/.build/release/NativeRHIPassProbe \
  --scene stylized --width 1920 --height 1080 --frames 180 --warmup 30 --repeats 3 \
  --output /tmp/guava-native-stylized-1080
```

Apple M1 本机 Release，Metal 验证关闭，30 帧预热，3×180 帧测量：

| 分辨率 / renderer | CPU frame p50 / p95 (µs) | 完成批次 p50 / p95 (ms/frame) |
|---|---:|---:|
| 1280×720 NativeRHI Metal | 1201.542 / 1341.625 | 3.608 / 3.627 |
| 1280×720 WGPU Metal | 942.208 / 1160.792 | 4.846 / 4.854 |
| 1920×1080 NativeRHI Metal | 842.625 / 1685.583 | 5.848 / 5.848 |
| 1920×1080 WGPU Metal | 885.167 / 1281.792 | 7.737 / 8.481 |

完成批次含每三帧等待 GPU，反映该负载的吞吐，不是 GPU timestamp 或显示 FPS。CPU 每项 540 个样本，批次每项 3 个样本。批次 p50 分别降低约 25.6% / 24.4%；720p CPU p50/p95 及 1080p CPU p95 仍高于 WGPU，默认切换前还须结合完整粒子/UI 场景评估 CPU 开销。

720p RGB 平均通道误差 0.001254，最大通道差 32，>3 像素 51/921600（0.005534%）；1080p 分别为 0.001504、37、191/2073600（0.009211%）。均通过现有平均误差 <0.5、>3 像素 <1% 的门限，并非所有像素完全相同。

测量中每条路径均执行描边 540 帧/3240 draws、纸张 540 帧/540 draws；深度、base、阴影、天空、SSAO、网格、TAA、透明、Bloom、tonemap、FXAA 每项均执行 540 帧。持续运动按生产规则跳过 SSR，不复用不透明 snapshot。原始环境、时间分布、pass 帧数/draw 数和误差见 [720p 报告](benchmarks/native-stylized-m1-720.json) / [1080p 报告](benchmarks/native-stylized-m1-1080.json)。

## 默认切换前剩余范围

EngineHost 默认仍使用 WGPU。粒子 GPU 模拟、Editor/GuavaUI 纹理/命令互操作和 DXIL 产物仍须完成。全部功能、画面对照与性能门限完成后再切换默认 renderer，然后移除 WGPU 运行时与参考依赖。
