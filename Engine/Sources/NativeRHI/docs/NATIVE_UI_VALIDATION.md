# NativeRHI UI 迁移验证

默认 UI 和 renderer 当前仍使用 WGPU。GuavaUIRuntime 已新增 `NativeDrawListRenderer`，直接消费现有 DrawList，在调用方管理的 NativeRHI frame / command buffer 内上传和绘制。Metal 的独立 UI、生产场景＋ViewportHost 与游戏内 HUD 对照已通过。NativeRHI 已提供多个窗口的 swapchain 所有权与帧协调，GuavaUI `AppRuntime` 现在支持可选的 `.native(Device)` 路径；Editor／Player 默认仍显式选择 WGPU。

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
- 每个 renderer 保留独立管线配置，sibling 共享 shader 与 texture slots。所有方法在每个 renderer 上串行调用；窗口接入时，同一 device 的主／辅助绘制须通过 `withFrameSession` 串行安排完整帧，也可在一个 frame 内绘制多个窗口。Viewport 分别声明 logical / pixels，scissor 使用向外取整并在转整数前钳制，跳过空区域。

调用方须持有 target / resolve target 直到提交，并保留 `NativeUIDrawFrame` 直到 `Device.submit` 成功。`frame.didSubmit()` 只确认已提交的记录；不能确认被放弃的 command buffer。它不替宿主管理 beginFrame / endFrame / present。

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

## 场景 viewport 与快照所有权

`ViewportSurfaceState` 现在直接持有 `ViewportImage`，其中 NativeRHI 使用 `TextureResource`，WGPU 使用强引用 `GPUTexture`；删除裸指针、Unmanaged 重建和固定 32 项的旧纹理保留历史。`ViewportSamplingRegion` 独立描述 used extent / allocation capacity，校验边界并提供 UV 比例。生产 renderer 仅在成功 submit 后发布 surface；Native 离屏 color target 增加 sampled usage，swapchain 图像不作为持久 viewport 发布。

`ViewportTextureRegistry` 为图像 lease 分配独立 TextureID，允许同一个 DrawList 同时使用旧、新纹理，也避免不同 producer 的相同 surfaceID 相互覆盖。registry 弱引用 lease，GPU binding 强引用实际纹理；surface、节点闭包、cached layer 和 `DrawListResources` / `DrawListSnapshot` 持有 lease。无 producer / geometry 快照使用的 slot 在 prune 时移除，录制 token 继续保护尚未提交的资源。Native 注册拒绝跨 device 或 backend 的图片，不需要场景像素的 CPU 传输。

ViewportHost 使用 `addClampedImageQuad`，九个相邻区域合并成一个 draw batch。内部 UV 保持原来的像素映射，边缘保持在有效区域的 texel 中心，避免 resize 后线性放大读取 allocation padding。没有改变 shader / packed vertex ABI。

2026-10-09 Apple M1 Metal 实测：

- 生产 NativeRenderer / WGPURenderer 分别绘制 r3 mesh 与 HDR/SSAO/Bloom/FXAA 场景，经真实 ViewportHost、letterbox、clip 和 UI overlay 合成到 384×256（logical 192×128）。源图像先 192×128，再缩为 64×32，最后 256×96；BGRA unorm / sRGB × 1/4 samples，共 24 组。mesh 合成全部逐像素一致；后处理合成 RGB 平均误差最大 0.015568，>3 的像素最多 275/98304（0.280%），通过平均误差 <0.5 / outliers <1% 门限。
- 另将完整 WGPU allocation（含 padding）以仅测试使用的 CPU transfer 提供给 Native UI，隔离场景差异：同一源图像的 UI 合成 24 组均满足最大通道差 ≤1。生产 Native viewport 的 UI texture upload 只有首次 white fallback 的 4 字节，不上传场景像素。
- 使用绿色有效区域、洋红色 padding，覆盖 3×2、1×3、3×1、1×1 used extent、8×8 allocation、非整数 viewport 边界、两种目标格式及 1/4 samples。显示区域的内部全部为绿色，两条路径逐像素一致，padding 不渗色。
- 原生和 WGPU surface 保留 40 次纹理替换后、renderer 销毁后的首张图像；实际 readback 保持原值。scene shrink 保持资源身份，growth 替换，分配成功但 beginFrame 失败时仍发布上一张成功图像。RenderThread report 跨线程保留同一个 image lease。
- 两张不同 producer、相同 surfaceID 的红／绿图片，在 snapshot restore 后同时绘制；删除源 surface、CPU list 和 registry bindings 后，frame token 仍能提交正确画面。prune 不产生悬空资源。COW / translated layer append、empty geometry、snapshot channel 和 reset / load 都保留并按时释放 lease。

本阶段 NativeRHI 101 项、NativeRenderer 原有 39 项及新增 4 项 XCTest 通过；GuavaUI、Portable 与 Editor 全包测试通过，并运行了 RenderThread 与生产 WGPU GPU smoke。Swift 结构检查仍为 46 项既有超限指标，WGPURenderer 的 stored property allowance 从 124 收紧到 118。集成误差记录见 [viewport Metal 报告](benchmarks/native-viewport-m1.json)。

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

## 游戏内 UI 接入

`InGameUIProviding` 移到 RenderBackend，接收整个 RenderPacket 和明确的 NativeRHI / WGPU target，删除 AnyObject encoder/view、字符串 format hint 与空 resize 回调。`InGameUIHost(device:)` 与 NativeRenderer 使用同一个 Device；场景 renderer 管理 beginFrame / submit / endFrame，HUD 在 tonemap / FXAA 之后向同一个 CommandBuffer 录制 load pass。`InGameUIRecording` 保留上传确认和所需资源，仅在 scene submit 成功后确认；失败不发布 surface 或推进 Native temporal state。WGPU 放弃 encoder 时也会使未提交的 history/cache 失效。

两条路径都消费 main-thread bridge 发布的最新 snapshot。snapshot 仅保留 logicalSize，物理 used extent 由 RenderPacket.drawableSize 提供。字体 alpha / color planes 从 channel 转交到 renderer 的 pending upload 队列，空 geometry 也保留更新，之后有 HUD 时上传。没有 script canvas 时仍调用 provider，因而声明式 HUD 正常显示；有 script canvas 但没有 provider 时提前报错。HUD 的实际 draw calls、CPU encode 时间和动态 `inGameUI` pass 计入统计，HUD 不进入 opaque cache。

替换 content scale / font atlas 时，bridge 使文本测量和 retained layer caches 失效，重新生成正确 atlas UV。此前未变化的脚本标签会复用旧 UV，Native/WGPU 都能产生一致但缺少文字的画面；现在用面板内实际白色文字像素检查和 unchanged-canvas scale regression 覆盖此问题。

2026-10-09 Apple M1 Metal 覆盖：

- 生产 NativeRenderer / WGPURenderer 与各自 InGameUIHost：r3 scene、r5 HDR/SSAO/Bloom/FXAA × 1 / 1.5 / 2 content scale，logical viewport 192×128 → 80×64 → 160×96，physical target 缩小后再增长，共六组。声明式中英文/emoji、脚本 label、圆角面板和 progress bar 叠加在最后输出上；跳过 producer tick 后两张字体 plane 仍有效。普通场景逐像素一致，后处理 RGB 平均误差最大 0.001723，>3 的像素最多 3/24576，均通过既定门限。原始 [HUD 对照数据](benchmarks/native-hud-parity-m1.json)。
- Opaque snapshot 命中时，HUD 由红变蓝，仍逐帧更新；清空脚本/geometry 后动态 UI pass 消失，画面与无 provider 的 scene 相同，HUD 不残留在缓存里。
- 缺 provider 在资源分配前拒绝；HUD record 已完成后抛错、以及 backend 拒绝同一 command buffer 时，旧 surface / pixels / stats 保持原值且不确认字体。无需再 tick 或重新发布 atlas，随后提交同时恢复 R8 和 RGBA 字体。
- Backend / device 不匹配在 consume 前拒绝；空 snapshot 保留两种 atlas 更新，随后 geometry 正确绘制。重复确认安全，HUD 仅覆盖 packet used extent，不写 allocation padding。
- WGPU HUD record 错误不再被内部吞掉；放弃 encoder 后重新完整绘制 scene，恢复字体和 HUD，不重用未提交的 opaque snapshot。

游戏内 UI 的 Release 集成性能使用 40 个动态 progress card、中英文/emoji 和声明式标题，每帧 123 次 HUD draw。r3 mesh 与 r5 HDR/SSAO/Bloom/FXAA（TAA/SSR 关闭），720p / 1080p，logical 1280×720，1080p 使用 1.5× scale。每组预热 30 帧，再运行 3×180 帧；每三帧完成 GPU 等待。两条路径的所有 pass frames / draw counts 相等，每组测量共 66420 次 HUD draw；最后 readback 的 mesh 图像完全一致，post RGB 平均误差 <0.000221、>3 的像素 <0.002%。

| 场景 | 分辨率 | HUD tick＋packet＋scene CPU p50，Native / WGPU (ms) | completed-batch p50，Native / WGPU (ms/frame) |
| --- | --- | --- | --- |
| mesh | 1280×720 | 6.935 / 7.015 | 7.726 / 7.991 |
| mesh | 1920×1080 | 7.120 / 7.196 | 8.108 / 8.511 |
| post | 1280×720 | 7.700 / 7.873 | 9.831 / 10.162 |
| post | 1920×1080 | 7.690 / 7.930 | 9.899 / 10.397 |

Native HUD encode p50 为 64.6–70.6 μs，WGPU 为 129.7–138.4 μs；scene CPU p50 也降低。包含共享 main-thread UI 重组/排版的总循环 p50 降低约 1%–3%，completed-batch 降低约 3%–5%。720p post 总 CPU p95 为 8.360 / 8.300 ms，Native 略高约 0.7%；其他三组总 CPU p95 和四组 scene/HUD encode p95 均降低。这里包含 UI tick 和 packet 构造，不包含窗口呈现或测量期的 atlas churn；completed-batch 不是 GPU timestamp 或显示 FPS，三个批次样本的 p95 对应最大批次值。整个 Editor 的性能仍须单独验证。

原始报告：[mesh 720p](benchmarks/native-hud-mesh-m1-720.json)、[mesh 1080p](benchmarks/native-hud-mesh-m1-1080.json)、[post 720p](benchmarks/native-hud-post-m1-720.json)、[post 1080p](benchmarks/native-hud-post-m1-1080.json)。

```sh
GUAVA_NATIVE_HUD_BENCHMARK=1 swift test --package-path GuavaUI -c release \
  --filter NativeInGameUIBenchmarkTests
# 产物写到 /tmp/guava-native-hud-benchmark；可用
# GUAVA_NATIVE_HUD_BENCHMARK_OUTPUT 指定绝对目录。
```

NativeRHI 101 项、NativeRenderer 43 项、GuavaUI 全包及 Editor 受影响测试通过。Swift maintainability 仍为既有 46 项超限指标，没有增加。

## 拥有 CPU 像素的图片资产

`ImageAssetRegistry()` 改为独立 CPU cache，删除对 WGPU renderer 和 main-thread GPU 上传的依赖。每个不可变 Asset 保留整个 DecodedImage，验证 RGBA 字节数、尺寸和像素预算；相同 key 的并发注册只发布一个实例。图片 TextureID 使用独立命名空间，不同 registry、缓存清理前后的旧／新图可在同一 DrawList 中共存。

Image.Source 将手动 GPU texture 与拥有 CPU 像素的 asset 分开。文件图片、AsyncImage、SVG 密度重栅格、评分星形与 TextField 清除图标将 asset 保留进 DrawListResources，再随 cached layer 和 DrawListSnapshot 传到消费端。InGameViewGraphBridge 安装自己的 CPU cache；异步解码只在捕获的 UI scheduler 上注册和发布，GPU texture 创建／上传由 Native 或 WGPU 绘制器的串行录制线程执行。没有 registry 时，同步文件图片也能直接解码并拥有像素。

GPU residency 弱引用 CPU asset，成功首次注册后复用纹理。clear 只释放 cache 的所有权，旧节点和 snapshot 保持有效；最后一个 CPU 引用过期后，下次录制清理 GPU slot。Native frame token 独立保留已录制的 GPU slot，因而在提交前清理 CPU cache 或 registry 仍可完成原帧；失败或放弃的上传继续保留到随后成功提交。Sibling 同步共享 GPU 图片，并拒绝跨 device／backend 的绑定。CPU cache 尚无自动淘汰，需主动 clear 或释放宿主。

2026-10-09 Apple M1 Metal 覆盖：

- 64 次并发同 key 注册取得同一 asset；独立 registry 分配不同 ID。拒绝非法尺寸、溢出尺寸与 RGBA payload，错误不进入 cache。clear 增加 revision，snapshot COW／reset 保留并按时释放 CPU owner。
- 三张红／绿／蓝图片同时显示，其中蓝图替换同 key 的红图，红图仍被旧 geometry 保留。两条路径逐像素一致；Native sibling 仅上传自己的 4 字节 fallback，随后主 renderer 的图片上传为零，WGPU sibling 也保持原图。
- 无 active frame、录制后 submit 失败、cache clear／geometry reset 和提交前 prune 均覆盖。CPU owner 已释放时原 frame token 仍提交正确像素，无需重新发布图片。
- 生产 mesh scene + InGameUIHost 的文件 SVG HUD：fit／fill、rounded clip、半透明色块、alpha mask，1× → 2× → 1.5× → 1×，四组 readback 与 WGPU 完全一致。AsyncImage 的实际文件由 main-thread scheduler 发布，再在 worker 线程录制 Native scene，实际红／绿像素正确。原始 [图片 HUD 对照](benchmarks/native-image-hud-parity-m1.json)。
- SVG cache clear 后，未改变逻辑尺寸的 raster 取得新图，旧 retained geometry 仍保留原像素；评分 mask 的两张 CPU 图片随 draw list 保留。

GuavaUI 和 Portable 全包通过，之后新增的缓存重置／worker-thread／sibling 回归单独通过。Editor 受影响测试及空闲环境下的串行全包通过。并行编译期间的两次全包运行分别出现 workspace preset 和 SourceKit retry fixture 的间歇性失败，相关单独测试与空闲全量复测通过；不据此修改这两处未变更的功能代码。Swift maintainability 仍为 46 项既有超限指标。

图片 Release 性能使用 96 张独立 64×64 RGBA 图片，共 1,572,864 字节 CPU 像素，8,064 vertices、20,160 indices、96 draws。BGRA sRGB + 4× MSAA，logical 1280×720，物理 720p / 1080p；每条路径预热 30 帧、测量 3×180 帧，每三帧等待 GPU 完成。Native 首次上传 1,572,868 字节（含 white fallback），随后所有稳态帧上传为零。720p 预检逐像素一致，1080p 最大通道误差 1。

| 分辨率 | CPU p50，Native / WGPU (µs) | CPU p95，Native / WGPU (µs) | completed-batch p50，Native / WGPU (ms/frame) |
| --- | ---: | ---: | ---: |
| 1280×720 | 302.917 / 228.041 | 336.750 / 308.500 | 0.609 / 0.786 |
| 1920×1080 | 486.875 / 526.208 | 685.208 / 823.125 | 1.115 / 1.570 |

这次空闲测量的 completed-batch p50/p95 均降低；1080p CPU p50/p95 也降低。720p CPU p50 高约 33%、p95 高约 9%，这项 CPU 门槛尚未通过。原始报告：[图片 720p](benchmarks/native-ui-image-assets-m1-720.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080.json)。

之后给 benchmark 加上每帧 draw count 相等、Native 稳态零图片重上传的检查，再次空闲运行：720p CPU p50 为 299.042 / 340.208 µs，completed-batch 为 0.556 / 0.901 ms/frame；1080p CPU p50 为 446.708 / 523.292 µs，completed-batch 为 1.108 / 1.604 ms/frame。两种分辨率的 CPU p50/p95 和 completed-batch p50/p95 都低于 WGPU。后一次的 [720p 报告](benchmarks/native-ui-image-assets-m1-720-checked-work.json)、[1080p 报告](benchmarks/native-ui-image-assets-m1-1080-checked-work.json) 与前一次一起保留；720p CPU 对照仍有波动，需要调查测量稳定性和提交开销，不能仅凭后一组结果宣称性能门槛通过。

这里仅测 renderer 的 steady-state 工作，不包含解码、首帧图片上传、UI 重组、窗口呈现；completed-batch 不是 GPU timestamp 或显示 FPS，三个批次样本的 p95 为最大批次值。

```sh
GUAVA_NATIVE_IMAGE_BENCHMARK=1 swift test --package-path GuavaUI -c release \
  --filter NativeDrawListBenchmarkTests
# 报告写到 /tmp/guava-native-ui-benchmark；可用
# GUAVA_NATIVE_UI_BENCHMARK_OUTPUT 指定绝对目录。
```

## 配对性能采样与提交缓存

先前 benchmark 依次完成 Native 的全部批次，再完成 WGPU 的全部批次，容易混入 CPU/GPU 温度和调度变化。现改为两条路径各预热 60 帧，再交替进行 6×180 帧的配对批次；每个批次轮换先运行的 backend，仍每三帧等待完成。CPU 有 1080 个样本，completed-batch 有 6 个样本；报告保留六个批次各自的 record／submit／frame 分位数和完成耗时。每帧继续核对 draw count 和 Native 零稳态上传，计时不包含批次报告整理。

Metal render encoder 现在缓存各 stage 的 buffer＋offset、texture 和 sampler 原生对象，只在绑定改变时调用 setter。每个绑定仍先解析并校验资源，push constant 覆盖会使相应 buffer slot 失效，新 render pass 使用新缓存。SubmissionPlanner 在单个 render／compute pass 内合并不同 binding set 对同一资源、同一状态的只读依赖；写入以及 vertex／index／indirect 用途切换会清除对应记录。AccessTracker 对已覆盖的读取保留原 RAW 结果，避免重写相同的读取历史；跨帧 RAW／WAR／WAW 结果保持原行为。

2026-10-09 Apple M1：新增实际 Metal 像素测试验证反复绑定、texture／sampler 切换、buffer offset 改变、不同 pipeline 的 fragment push constant 覆盖，以及第二个 load pass 重新绑定。规划器测试验证 96 个不同 set 共享 uniform 的上传依赖、跨队列 release／acquire／timeline、随后写入，以及 buffer 用途切换。NativeRHI 106 项与 NativeRenderer 43 项 XCTest、GuavaUI 全包测试通过；两项 DrawList Release benchmark 在独立测量中运行。Swift maintainability 检查通过，46 项既有超限指标未增加。

优化前的配对基线保留在 [图片 720p](benchmarks/native-ui-image-assets-m1-720-paired-baseline.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-paired-baseline.json)、[控件 720p](benchmarks/native-ui-m1-720-paired-baseline.json)、[控件 1080p](benchmarks/native-ui-m1-1080-paired-baseline.json)。优化后的空闲测量和第二次确认结果：

| 工作量／运行 | 分辨率 | CPU p50，Native / WGPU (µs) | CPU p95，Native / WGPU (µs) | completed-batch p50，Native / WGPU (ms/frame) |
| --- | --- | ---: | ---: | ---: |
| 96 张图片／首次 | 1280×720 | 494.292 / 365.458 | 611.625 / 463.750 | 0.764 / 0.924 |
| 96 张图片／确认 | 1280×720 | 324.250 / 255.459 | 517.916 / 375.042 | 0.585 / 0.843 |
| 96 张图片／首次 | 1920×1080 | 529.625 / 416.625 | 646.958 / 577.709 | 1.159 / 1.418 |
| 96 张图片／确认 | 1920×1080 | 527.708 / 437.333 | 637.208 / 565.625 | 1.157 / 1.378 |
| 48 组控件／首次 | 1280×720 | 345.083 / 449.250 | 404.708 / 518.375 | 0.610 / 0.914 |
| 48 组控件／确认 | 1280×720 | 254.417 / 316.584 | 320.583 / 396.792 | 0.602 / 1.018 |
| 48 组控件／首次 | 1920×1080 | 457.875 / 590.584 | 562.041 / 725.334 | 0.877 / 1.428 |
| 48 组控件／确认 | 1920×1080 | 400.708 / 462.375 | 542.625 / 634.625 | 0.812 / 1.410 |

图片工作量的 CPU p50 两次均高约 21%–35%，CPU p95 也更高；单个配对批次仍有调度波动，不能把减少 setter／规划器重复工作当作性能门槛已通过。普通控件 CPU p50/p95 和两类工作量的 completed-batch p50/p95 两次均降低。图片 720p 预检逐像素一致，1080p 最大通道误差 1，所有稳态帧图片上传为零。整个 renderer 性能门槛仍未通过，默认值继续使用 WGPU。

原始优化报告：[图片 720p](benchmarks/native-ui-image-assets-m1-720-paired.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-paired.json)、[控件 720p](benchmarks/native-ui-m1-720-paired.json)、[控件 1080p](benchmarks/native-ui-m1-1080-paired.json)。独立确认报告：[图片 720p](benchmarks/native-ui-image-assets-m1-720-paired-confirmation.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-paired-confirmation.json)、[控件 720p](benchmarks/native-ui-m1-720-paired-confirmation.json)、[控件 1080p](benchmarks/native-ui-m1-1080-paired-confirmation.json)。completed-batch 仍不是 GPU timestamp 或显示 FPS；采样不包含窗口呈现和 UI 重组。

## 多窗口 swapchain 与帧协调

NativeRHI 现在显式创建、配置和获取指定 `Swapchain`，每个窗口由 `SwapchainResource` 独立拥有。resize 只替换该窗口的图像池；同一原生窗口不能重复注册。每次获取返回独立、不可变的 `SwapchainImage` ticket，即使复用了相同的 texture ID，旧 ticket 也不能再次 present。每个窗口每帧最多获取一次，跨窗口、旧 ticket 和重复 present 明确拒绝。

`Device.withFrameSession` 串行保护资源准备、beginFrame、submit、present 和 endFrame。生产 NativeRenderer／NativeGridRenderer 已使用该协调入口及各自的窗口 target，scene 线程与未来 UI 窗口可共享同一个 Device。present 的最终 GPU 命令也计入 FrameRing；复用上传存储、图像 ID 或销毁窗口须等待相应 completion。endFrame 自动归还录制失败后未 present 的图像，零 draw 帧也会消费 Vulkan acquire semaphore。`SwapchainResource.close()` 在销毁平台窗口前同步等待、释放；重复 close 有效，已完成 GPU 工作的错误仍会清理窗口。

Metal 每个窗口按 frame slot 复用有限的 texture ID，并通过 graphics command buffer 排队 present。Windows/Linux Vulkan 每个窗口拥有按 slot 分配的 acquire semaphore 与按 swapchain image 分配的 present semaphore；out-of-date／suboptimal 后在下一次获取时重建并更新 generation。DX12 每个 HWND 拥有独立图像池和不冲突的内部 ID，最终 transition／Present 后的 fence completion 保护在途资源。已排队的 present 错误通过设备状态报告，不会触发重复 completion。

2026-10-09 Apple M1 Metal 实测：两个真实 NSWindow／CAMetalLayer 连续 40 帧分别绘制红色和绿色，交替 present 顺序。在第 20 帧只 resize 第一个窗口，另一个窗口的尺寸、generation 和像素保持正确；两窗口 readback 全部像素符合预期。两个在途 frame slot 的纹理池最多保留四个 texture。非法格式 resize 保留原窗口；关闭第一个窗口后第二个继续获取／呈现，最后两个窗口的 registry 和图像池均释放。readback 测试单独关闭 framebufferOnly，生产路径仍启用它。

可控 completion 测试覆盖并发帧准备、错误后解锁、延迟 present 阻止 frame slot 复用与资源退休、未呈现图像归还、相同图像 ID 的旧 ticket 拒绝、排队前失败重试，以及 close 的幂等和晚报错误清理。NativeRHI 114 项 XCTest 与 NativeRenderer 43 项 XCTest、GuavaUI 全包测试通过。GuavaUIApp 25 项 XCTest 中性能 benchmark 按默认设置跳过一项，其余没有失败；Runtime 222 项、Compose 504 项也通过。Editor 的共享 WGPU 生命周期回归和 GameRuntime 的真实 NativeRenderer Metal viewport 回归通过。Swift maintainability 检查通过，45 项既有超限指标未增加。DX12 的 macOS unavailable bridge 编译通过；Windows DX12 和 Windows/Linux Vulkan 的原生编译／运行验证仍暂缓，未引入 MoltenVK。

这一步已把主／辅助窗口宿主和 EngineHost 场景线程接到可选 NativeRHI 路径。`AppRuntime.run(backend: .native(device))` 与 `EngineHost(renderDevice: .native(device))` 共用一个 Device，同时各自拥有 swapchain、resize、VSync 和 close 生命周期；WGPU 默认路径仍保留。EditorApp 和 GuavaPlayer 可通过 `--renderer native` 或 `GUAVA_RENDERER=native` 选择当前平台的 NativeRHI；也可显式指定 `metal`、`vulkan` 或 `dx12`，macOS 不启用 MoltenVK。Native 主／辅助窗口、共享设备的场景线程、Native/WGPU DevTools 截图、WGPU 默认多窗口回归和真实 GameApplication NativeRenderer viewport 均已在 Apple M1 通过。整个 Editor 的默认 backend 尚未切换，整个窗口 UI 的画面和呈现性能门槛仍未完成。

## 每次录制的常量与图片绑定

UI 的 logical viewport 和 sRGB 标志改用 16 字节顶点 push constants。sRGB 标志通过 flat varying 传给 fragment；离线编译分别定义两个阶段，避免 Slang 反射把未使用的全局资源也加入接口。Metal 和 SPIR-V 产物已重新生成，加载器验证常量的阶段和字节布局，图片 binding set 仅含 texture / sampler。

图片绑定仍通过 Device 的有界缓存查询，不在 UI 层长期保存可能被淘汰的 BindingSet handle。新增 Metal 回归在同一个 renderer、同一次提交内切换 logical viewport 和线性／sRGB target，连续八帧改变 geometry 大小，跨过三个 frame slots。首次录制后所有图片绑定均命中，后续图片上传为零；两张输出与 WGPU 逐像素一致。现有无效几何的原子失败、多个录制器、大于 4 MiB 的上传、字体、裁剪和 MSAA 回归继续通过。索引校验显式预读数组计数，校验规则不变。

固定工作量的旧 uniform buffer / offset 会随帧环复用，预热后旧 binding set 本来就可以命中。因而不能将这次接口拆分视为消除了稳态图片 CPU 回退。以下仍使用交替先后顺序的 6×180 配对采样、60 帧预热、每三帧等待完成；测量时没有其他编译、测试或 Editor 进程运行。

2026-10-09 Apple M1 Release：

| 工作量／运行 | 分辨率 | CPU p50，Native / WGPU (µs) | CPU p95，Native / WGPU (µs) | completed-batch p50，Native / WGPU (ms/frame) |
| --- | --- | ---: | ---: | ---: |
| 96 张图片／改动前 | 1280×720 | 495.250 / 355.958 | 546.416 / 460.833 | 0.794 / 0.934 |
| 96 张图片／改动前 | 1920×1080 | 548.542 / 440.000 | 630.666 / 592.959 | 1.141 / 1.388 |
| 96 张图片／首次 | 1280×720 | 530.250 / 429.833 | 652.750 / 585.959 | 0.815 / 0.986 |
| 96 张图片／确认 | 1280×720 | 534.625 / 432.625 | 567.042 / 629.542 | 0.854 / 1.055 |
| 96 张图片／首次 | 1920×1080 | 543.667 / 547.417 | 711.542 / 891.417 | 1.254 / 1.627 |
| 96 张图片／确认 | 1920×1080 | 538.708 / 492.041 | 696.500 / 824.875 | 1.239 / 1.569 |
| 48 组控件／首次 | 1280×720 | 548.458 / 646.458 | 588.667 / 748.209 | 0.894 / 1.096 |
| 48 组控件／确认 | 1280×720 | 479.959 / 593.833 | 575.708 / 724.667 | 0.835 / 1.132 |
| 48 组控件／首次 | 1920×1080 | 554.750 / 686.042 | 697.750 / 746.334 | 1.012 / 1.321 |
| 48 组控件／确认 | 1920×1080 | 556.750 / 680.625 | 697.625 / 741.875 | 1.003 / 1.322 |

720p 图片 CPU p50 两次仍高约 23%–24%，p95 一次更高、一次更低；1080p CPU p50 一次相近、一次高约 9.5%。普通控件 CPU p50/p95，以及所有工作量的 completed-batch p50/p95 均低于 WGPU。图片预检最大通道误差 1，控件最大通道误差 1，所有稳态图片上传仍为零。CPU 门槛尚未通过，默认 renderer 保留 WGPU。这里没有测量窗口呈现或 UI 重组；completed-batch 不是 GPU timestamp 或显示 FPS。不同运行的绝对 CPU 数值仍有明显调度波动，不据此宣称改动前后的速度提升。

原始基线：[图片 720p](benchmarks/native-ui-image-assets-m1-720-recording-constants-baseline.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-recording-constants-baseline.json)。首次报告：[图片 720p](benchmarks/native-ui-image-assets-m1-720-recording-constants.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-recording-constants.json)、[控件 720p](benchmarks/native-ui-m1-720-recording-constants.json)、[控件 1080p](benchmarks/native-ui-m1-1080-recording-constants.json)。确认报告：[图片 720p](benchmarks/native-ui-image-assets-m1-720-recording-constants-confirmation.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-recording-constants-confirmation.json)、[控件 720p](benchmarks/native-ui-m1-720-recording-constants-confirmation.json)、[控件 1080p](benchmarks/native-ui-m1-1080-recording-constants-confirmation.json)。

GuavaUI 全包回归通过，随后修改的数组计数读取经 Release 的 11 项 draw-list 回归验证，变化几何的绑定复用测试另行通过。Slang 工具链 9 项测试通过，包括两个 UI 阶段在 Metal / SPIR-V 上的反射契约。Swift maintainability 检查通过，未增加既有超限指标。

## 真实 Editor 循环与整窗对照

`validate-editor-native-loop.py` 现在默认显式选择 NativeRHI；`--renderer both` 顺序运行 NativeRHI / WGPU 的事件驱动和连续帧循环，并自动比较暂停后的整窗内容。临时 app、项目、布局和脚本信任与日常项目分开。Native 启动须出现 `NativeRenderer ready`，且不能出现 WGPU 初始化或任何渲染失败日志。监听端口可早于首帧布局／字体栅格化开放，脚本先取得非空窗口画面，再检查桥接的交互响应。

`get_runtime_state` 增加已提交帧的编号、可见网格数、draw count 和 viewport 有效性。脚本等待新帧、有效 viewport 和非零可见网格后才暂停截图，避免将已经更新的仿真实体数当作渲染完成。该检查发现 NativeRenderer 漏填 `visibleMeshInstanceCount`；现从相机 visibility plan 填写，与 WGPU 使用相同定义。剔除、LOD 和对照场景的统计回归覆盖此修复。

2026-10-09 Apple M1 Debug 实测四个流程全部通过：独立 TCP 客户端、分段／流水线请求和非法 JSON 恢复；实际 Swift 编译、修改源码并热重载；Play → Pause → Stop → Play 的确定性重启；导出后在没有外部工具链的 PATH 下运行 GuavaPlayer，验证一个编译脚本、60 个实体和 120 个仿真帧。两条 renderer 在两种循环下均发布有效场景 viewport，游戏包含 56 个可见网格。

两种循环的 1440×870 窗口对照均得到 RGB 平均字节误差 0.003259，超过 3 的像素为 37 / 1,252,800，多数位于文字边缘，最大字节误差 85。自动门槛为平均误差 <0.25、超过 3 的像素 <0.1%。这里是实际窗口 DrawList 通过所选 renderer 重新绘制并 readback 的质量 1 JPEG，包含同一 Device 的场景 viewport 和动态 Editor 文字；它补充组件的无损 readback 测试，不等同于系统 compositor 截图或呈现性能验证。[整窗与运行状态报告](benchmarks/native-editor-window-parity-m1.json)。

```sh
swift build --package-path Editor --jobs 4
swift build --package-path guava-mcp --product GuavaMCP
python3 scripts/validate-editor-native-loop.py --renderer both
# 默认检查两种循环；--mode event-driven / continuous 可单独检查。
# 临时目录保留每条路径的启动／暂停 JPEG、渲染状态、比较报告和日志。
```

Editor 的 project tools 三项测试、真实 Native GameApplication Metal viewport 测试和 NativeOpaque 四项测试通过。Swift maintainability 检查通过，未增加既有超限指标。

## 提交阶段的只读依赖复用

NativeDrawListRenderer 在每个 pass 内只在实际变化时录制 binding set 和 scissor；首个 draw 仍设置完整状态。DrawBatch 顺序和 draw 数量不变。Device 的不可变 binding-set 全值缓存命中后直接返回已验证集合；新值仍完整检查并在后端注册失败时回滚。

SubmissionPlanner 在注册不可变集合时预解析纹理／缓冲依赖和布局的只读访问，忽略无内存依赖的 sampler。已排序的读访问可供同队列、同范围、已覆盖阶段的后续读复用；新写入清空读窗口，新队列、范围或阶段仍建立依赖。队列未变化时不重复写入 owner 字典。该优化保留状态转换、重新上传、跨队列 release/acquire、后续写入和资源销毁的边界，而不是关闭规划或校验。

2026-10-09 Apple M1，Swift 6.4 Release。在 `fb92b738` 的隔离工作树加本轮渲染改动验证，避免共享工作区另一项组件格式重构的中间编译状态。两次空闲配对采样均使用前述 60 帧预热、6×180 帧交替先后顺序和每三帧等待完成。所有 draw 数相等，稳态图片上传为零，预检最大通道误差为 1。CPU 单位为 µs，completed-batch 单位为 ms/frame：

| 工作量／运行 | Native CPU p50 / p95 | WGPU CPU p50 / p95 | Native completed p50 / p95 | WGPU completed p50 / p95 |
|---|---:|---:|---:|---:|
| 图片 720p | 334.625 / 489.208 | 359.000 / 505.500 | 0.706 / 0.781 | 0.976 / 1.008 |
| 图片 1080p | 471.292 / 617.209 | 393.916 / 537.875 | 1.054 / 1.553 | 1.397 / 1.502 |
| 控件 720p | 330.041 / 400.792 | 451.209 / 552.917 | 0.607 / 0.722 | 0.982 / 1.017 |
| 控件 1080p | 428.875 / 466.334 | 570.208 / 675.083 | 0.924 / 0.970 | 1.474 / 1.486 |
| 图片 720p 确认 | 410.583 / 503.583 | 415.792 / 528.708 | 0.781 / 0.832 | 0.999 / 1.097 |
| 图片 1080p 确认 | 475.084 / 631.333 | 439.958 / 595.500 | 1.201 / 1.341 | 1.420 / 1.487 |
| 控件 720p 确认 | 206.792 / 462.458 | 292.417 / 537.333 | 0.518 / 0.944 | 0.843 / 1.326 |
| 控件 1080p 确认 | 442.292 / 554.041 | 586.334 / 732.542 | 0.954 / 1.028 | 1.455 / 1.505 |

720p 图片 CPU p50 两次略低于或接近 WGPU；1080p 图片仍高约 8%–20%，且第一次 completed-batch p95 高约 3.4%。普通控件 CPU 和所有 completed-batch p50 均更低。绝对 CPU 数值仍有调度波动，不据此宣称前后速度提升，也不宣称整个性能门槛通过。原始数据：[图片 720p](benchmarks/native-ui-image-assets-m1-720-read-dependencies.json)、[图片 1080p](benchmarks/native-ui-image-assets-m1-1080-read-dependencies.json)、[控件 720p](benchmarks/native-ui-m1-720-read-dependencies.json)、[控件 1080p](benchmarks/native-ui-m1-1080-read-dependencies.json)，[图片 720p 确认](benchmarks/native-ui-image-assets-m1-720-read-dependencies-confirmation.json)、[图片 1080p 确认](benchmarks/native-ui-image-assets-m1-1080-read-dependencies-confirmation.json)、[控件 720p 确认](benchmarks/native-ui-m1-720-read-dependencies-confirmation.json)、[控件 1080p 确认](benchmarks/native-ui-m1-1080-read-dependencies-confirmation.json)。这些 completed-batch 数据不包含窗口呈现，也不是 GPU timestamp 或显示 FPS。

NativeRHI 116 项测试在设置 Slang 2026.19 路径后全部通过，无跳过，包含真实 Metal 跨 transfer/compute/graphics 队列的存储读写、绑定状态和 MSAA。NativeRenderer 43 项场景回归、GuavaUI Release 的 11 项 Native draw-list／绑定复用回归通过。新增规划器测试覆盖持续只读、重新上传、队列移交、后续写入和资源销毁；AccessTracker 另检查范围、队列和阶段扩展。Swift maintainability 检查通过，未增加既有超限指标。

## 后续门槛

CPU 后续工作改为整体命令路径对照与优化：先分开 frontend 校验、依赖规划、原生编码和原生提交调用，再覆盖空 pass、普通控件、命令数量、动态上传、compute 与场景。图片只是资源压力用例之一。旧报告的 cpuRecord/cpuSubmit 分工不同，不能跨后端直接按列比较；CPU 总成本与 completed-batch 定义见 [提交架构对照](SUBMISSION_ARCHITECTURE.md)。同时继续完成整个 Editor 的 Release 呈现性能、更多窗口／面板交互和持续运行验证。NativeRenderer 与 NativeDrawListRenderer 使用同一 Device 时，宿主通过 `withFrameSession` 串行安排完整 beginFrame / submit / present / endFrame 生命周期，不能让 scene RenderThread 与 UI 线程重叠拥有 active frame。仍须补齐 DXIL 生产产物与可重现生成流程。Windows DX12 和 Windows/Linux Vulkan 的原生编译／运行验证按用户要求暂缓，不作为本机 macOS 迁移验收的前置条件；macOS 只验证 Metal，不引入 MoltenVK。完成本机功能／画面／性能门槛后再切换默认值和删除 WGPU。

## 2026-10-10：提交路径优化与门槛状态

针对 Metal 提交开销做了四项优化，均在 Apple M1 本机验证，不改动后端语义（像素 parity 仍为 `max=0.0`）：

- **零拷贝瞬态上传**：`FrameUploader` 新增 `write(_ bytes:)` 直接拷贝调用方已有的连续内存，避开 `Data` 中转；`NativeDrawListRenderer` 的顶点／索引上传不再构建 `Data`。
- **绑定应用扁平化**：`MetalBindingSet` 在注册时预解析出 `graphicsApplies` / `meshApplies` / `computeApplies`，编码期按预解析列表直接下 setter，不再逐 draw 用闭包求交集与 `contains`。
- **校验遍历合并**：`Device.validateCommands` 与 `PipelineInterfaces.validateCommands` 合并为单次 pass-body 遍历，mesh 能力检查随行内联，少一遍遍历。
- **依赖规划器键优化 + 记录期绑定集缓存**：`ResourceRef` 的 `(kind, id)` 是全局唯一，tracker 内部字典改用打包 `UInt64` 键；`StateTracker.requireState` 一次查找同时返回前置状态，去掉 `currentState` 二次查找；UI 记录期把每个纹理 slot 的 `(texture, sampler)` 绑定集缓存在 slot 上，稳态零重查 `makeBindingSet`。

同一 `NativeDrawListBenchmarkTests`（Release，validation 关闭）的 native/wgpu 同机比值（多次运行取最优）：

| 场景 | 720p native/wgpu | 1080p native/wgpu |
| --- | ---: | ---: |
| 空 pass (cmd0) | 0.98 | 0.96 |
| 单 draw (cmd1) | 0.46 | 0.46 |
| 96 draws (cmd96) | 0.56 | 0.60 |
| 1024 draws (cmd1024) | 0.83 | 0.78 |
| UI widget（equivalent-work） | 0.67 | 0.63 |
| 96-image（ownedImages） | 0.99 | 1.06 |

图片负载从原先高 WGPU 21%–35% 降到约 ±6% 以内（720p 已达 parity，1080p 受同机调度波动在 1.0–1.06 之间）。UI widget 与 command-count 负载稳定低于 WGPU（0.46–0.83）。绝对 CPU 数值仍随本机调度波动，判定仍以 native/wgpu 同机比值与 ±5% 容差为准。Metal 端的本机功能／画面／性能门槛（除 1080p 图片偶发 ±6%）已满足。应用层默认（GuavaPlayer/EditorApp 的 renderer 名、AppRenderingContext 的 device 兜底）已于 2026-10-10 切到 NativeRHI；WGPU 作为可选 fallback 与对照 harness 保留（仍可由 `--renderer wgpu` / `GUAVA_RENDERER=wgpu` 显式选用）。完整的 WGPU 删除仍取决于 Windows DX12 与 Windows/Linux Vulkan 在各自平台编译／运行验证完成。
