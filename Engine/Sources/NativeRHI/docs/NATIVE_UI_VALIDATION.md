# NativeRHI UI 迁移验证

默认 UI 和 renderer 当前仍使用 WGPU。GuavaUIRuntime 已新增 `NativeDrawListRenderer`，直接消费现有 DrawList，在调用方管理的 NativeRHI frame / command buffer 内上传和绘制。Metal 的独立 UI 绘制画面对照已通过；Editor viewport、in-game UI 与主／辅助窗口宿主尚未接入。

## 已实现的基础能力

- `TextureUploadRegion` 保留 width/height 与具有独立默认值的 origin。region 相对于 `TextureSubresource` 指定的 mip/layer；三种后端写入同一矩形，保留周围像素。所有 first-party 调用与测试使用新 API。
- 正常帧通过 `TextureBufferUpload` 记录矩形上传，包含具有独立默认值的 buffer offset 与 mip/layer。Metal blit、Vulkan VkBufferImageCopy 和 DX12 CopyTextureRegion 接收相同区域。Frame upload storage 可供 vertex/index 输入使用；字体不再要求帧外同步上传。
- `VertexFormat.unorm8x4` 读取打包 RGBA，归一化到四个 Float；顶点 buffer 的 stride/offset 仍由 layout 指定。
- Graphics pipeline 声明 sample count，默认 1。MSAA resource、所有 color/depth attachments 和 pipeline 的采样数必须一致。Metal、Vulkan 和 DX12 使用各自原生的采样数支持检查。
- Color target 可指定单采样 resolve destination。Metal 使用 multisampleResolve／storeAndMultisampleResolve；Vulkan dynamic rendering 使用 average resolve；DX12 在 pass 结束时转换 RESOLVE_SOURCE／RESOLVE_DEST 后执行 ResolveSubresource，再按 store 丢弃 source。整数格式不支持 average resolve，明确拒绝。
- Resolve destination 作为 attachment write 进入提交规划器。普通 copy、上传和读回拒绝 multisampled texture，调用方先 resolve。附件重复、extent/format/sample 不匹配会报错；失败录制可在同一帧重新提交有效命令。

## DrawList 绘制器

- Slang UI shader 保留既有 WGSL 的 sentinel 约定：solid、R8 glyph、RGBA image 与 image alpha mask；使用 packed 20-byte UIVertex、UInt32 indices、batch firstIndex、linear/clamp sampler、straight alpha blend 和目标格式对应的 sRGB 转换。
- Metal／SPIR-V 目标产物与反射已离线生成并随 Runtime 打包。使用 `BindingLayoutDescriptor(reflecting:)` 合并 stage visibility，同时拒绝 slot、space 与 buffer ABI 冲突。DXIL 使用相同生成入口；本机缺少 DXC，尚无 UI DXIL 产物。
- 字体 alpha / color planes 和普通纹理更新先转移到 registry-owned Data，再记录进正常 frame。初次局部注册先清零全图；成功 submit 后通过 frame token 确认相应 sequence，失败或放弃记录仍可重试。较旧 token 的确认不会删除随后排入的更新。空 DrawList 仍执行 attachment clear / load / resolve。
- `TextureResource` 持有 device 与原生 texture 所有权，释放时沿用设备的在途帧延迟销毁。外部图片注册检查同一 device、single-sample 2D sampled texture 与 encoded RGBA8/BGRA8 格式；frame token 和 sibling registry 强引用资源，resize / unregister 不产生悬空指针。线性 HDR / sRGB-source 需要独立的采样约定，目前明确拒绝。
- 每个 renderer 保留独立管线配置，sibling 共享 shader 与 texture slots。所有方法在每个 renderer 上串行调用；窗口接入时，同一 device 的主／辅助绘制须由宿主串行安排在一帧内。Viewport 分别声明 logical / pixels，scissor 使用向外取整并在转整数前钳制，跳过空区域。

调用方须持有 target / resolve target 直到提交，并保留 `NativeUIDrawFrame` 直到 `Device.submit` 成功。`didSubmit(frame)` 只确认已提交的记录；不能确认被放弃的 command buffer。它不替宿主管理 beginFrame / endFrame / present。

## 本机覆盖

2026-10-09，Apple M1，Slang 2026.19，Metal 实际提交与 readback：

- R8、RGBA8、BGRA sRGB、RGBA16Float 的 2-layer / 3-mip texture：在多个非零 origin 更新矩形，使用额外行距 padding；验证六个 subresources 的全部字节，未改写的边界、mip、layer 保持原值。拒绝越界更新，纹理内容保持完整。
- RGBA8／BGRA8 及两种 sRGB color targets：通过 Slang shader 读取 UInt32 打包颜色，分别执行 1× 与 4× raster。中心像素符合颜色／sRGB 转换，4× 的轮廓具有非零、非满值的 alpha coverage；resolved image 在同一 command buffer 随后复制并读取。
- 两个连续 pass 验证 MSAA store、load 与第二次 resolve；第二个 pass 丢弃 source，resolved pixels 仍正确。
- RGBA16Float 的 4× HDR clear + depth attachment：resolve 精确保留半浮点通道值；目的纹理具有三个 mips，已初始化的 mip1 保持不变。混用 1× depth 与 4× color 被拒绝。
- 错误 resolve extent、format、source samples、资源 alias、pipeline samples 以及 MSAA upload/readback/buffer copy 被拒绝。之后同一 frame 提交有效 clear/resolve，结果正确。
- 平台无关的附件验证与边界溢出检查，以及 resolve 后跨 queue 采样的 release/acquire、timeline 依赖。
- Recorded buffer upload 覆盖四种格式、非零 buffer offset、padded rows、非零 origin、多个 mip/layer；六个 subresources 的全部字节保持预期。非法 buffer range、row pitch、mip/layer 与 origin 被拒绝，同一 frame 随后有效提交成功。
- 真实 GuavaUI DrawList 与 WGPU 同时绘制系统字体的 `Hello 中🙂`、color glyph、圆角与描边、半透明重叠、tinted / cropped images、image mask、缺失图片 fallback、初次局部 R8 纹理、连续 color patches、嵌套 fractional scissor、空 scissor，以及非零 firstIndex。
- 1.5× 缩放下，两个轴、clip 起点／终点、四种分数坐标、1/4 samples，共 32 组接近整数像素边界的裁剪对照完全一致。正常数值沿用既有 Float 运算舍入；Float 溢出时使用 Double 回退，仍在转 Int 前钳制。
- RGBA8、BGRA8、两种 sRGB 及 RGBA16Float × 1/4 samples × 160×120、320×240、240×120，共 30 组逐通道 readback。8-bit 最大误差 1，HDR 最大误差 0.00048828125；没有超过容差（3 / 0.002）的通道。实际 BGRA sRGB 4× 画面也经可视检查。
- 资源生命周期覆盖 no-active-frame、录制放弃、submit 失败、提交期间后续 patch、重复旧 token 确认、resize / unregister / sibling sync、外部图片在 asynchronous submit 期间释放、跨设备拒绝与失败 configure 后继续使用原管线。8 帧不等待 idle 的双 renderer 绘制覆盖不同 logical viewport、超过 4 MiB 的 vertex upload chunk 和 frame-ring 复用。
- 非有限 vertex / scissor、错误 indices / batch ranges 与溢出 viewport 不留下部分 commands；超大有限 scissor 可安全钳制。失败 font registration 保留 atlas dirty state。

本轮 NativeRHI 101 项 XCTest、NativeRenderer 39 项 XCTest、GuavaUI 全包测试与 shader 工具链 8 项 Python 测试通过。Swift maintainability 检查通过，现有 46 项超限指标未增加。

Windows/Linux 的 Vulkan 与 Windows 的 DX12 实现及对应测试入口已同步编写，本轮没有在这些平台编译或运行。macOS 不提供 Vulkan／MoltenVK 路径。

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.'
swift test --package-path GuavaUI --jobs 4
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" python3 scripts/compile-native-renderer-shaders.py --ui-only
python3 scripts/check-swift-maintainability.py --report
```

## 同等工作量的 release 性能

2026-10-09，Apple M1，本机 Metal，validation 关闭。48 个相同 UI widget 共 19,008 vertices、46,080 indices、336 draws，含真实字体／emoji 和图片，BGRA sRGB + 4× MSAA。两条路径都逐帧上传并绘制同一 DrawList；steady-state 字体纹理已上传，每个 renderer 都执行 30 帧 warmup，随后 3×180 帧，每三帧等待 GPU 完成。预检逐像素对照最大差异 1。

| 分辨率 | Native CPU p50 | WGPU CPU p50 | Native completed batch p50 | WGPU completed batch p50 |
| --- | ---: | ---: | ---: | ---: |
| 1280×720 | 274.875 µs | 527.791 µs | 0.533 ms/frame | 1.090 ms/frame |
| 1920×1080 | 371.291 µs | 706.416 µs | 0.832 ms/frame | 1.368 ms/frame |

两种分辨率的 CPU 与 completed-batch p50/p95 均低于 WGPU。结果为独立 DrawList 工作量的 CPU 帧时间和包含 GPU 完成等待的吞吐，不是 GPU timestamp 或显示 FPS，也不包含窗口呈现、UI 树重组／排版及 atlas churn。原始数据见 [720p](benchmarks/native-ui-m1-720.json)、[1080p](benchmarks/native-ui-m1-1080.json)，报告包含 command recording / submit 分段计时。

Render pass 的 immutable binding set 在 planner 中只收集一次依赖；后续 pass 的 storage ordering 与跨 queue release/acquire 保持测试覆盖。Metal 绑定使用 visibility bitmask，资源查找／范围校验一次后绑定到所有所需 stages，避免逐 draw 构造 stage arrays。全部场景和 Metal 多 stage／mesh 回归通过。

```sh
GUAVA_NATIVE_UI_BENCHMARK=1 swift test --package-path GuavaUI -c release --jobs 4 \
  --filter NativeDrawListBenchmarkTests
# 产物默认写入 /tmp/guava-native-ui-benchmark。
# 可用 GUAVA_NATIVE_UI_BENCHMARK_OUTPUT 指定绝对输出目录。
```

## 后续门槛

迁移具有可靠资源所有权的 viewport 纹理桥、in-game UI、主／辅助窗口宿主与多 swapchain 帧协调。补齐 DXIL 生产产物与剩余性能场景；UI 绘制器的独立通过不能替代整个 Editor 和 EngineHost 的功能覆盖。完成全部功能／画面／性能门槛后才切换默认值和删除 WGPU。
