# NativeRHI UI 迁移验证

默认 UI 和 renderer 当前仍使用 WGPU。NativeRHI 已补齐 GuavaUI 所需的纹理局部上传、打包 RGBA 顶点和 MSAA color resolve；这批工作提供底层能力，尚未接入 DrawListRenderer、Editor viewport 或窗口宿主，也不代表 UI 画面对照与性能门槛已通过。

## 已实现的基础能力

- `TextureUploadRegion` 保留 width/height 与具有独立默认值的 origin。region 相对于 `TextureSubresource` 指定的 mip/layer；三种后端写入同一矩形，保留周围像素。所有 first-party 调用与测试使用新 API。
- `VertexFormat.unorm8x4` 读取打包 RGBA，归一化到四个 Float；顶点 buffer 的 stride/offset 仍由 layout 指定。
- Graphics pipeline 声明 sample count，默认 1。MSAA resource、所有 color/depth attachments 和 pipeline 的采样数必须一致。Metal、Vulkan 和 DX12 使用各自原生的采样数支持检查。
- Color target 可指定单采样 resolve destination。Metal 使用 multisampleResolve／storeAndMultisampleResolve；Vulkan dynamic rendering 使用 average resolve；DX12 在 pass 结束时转换 RESOLVE_SOURCE／RESOLVE_DEST 后执行 ResolveSubresource，再按 store 丢弃 source。整数格式不支持 average resolve，明确拒绝。
- Resolve destination 作为 attachment write 进入提交规划器。普通 copy、上传和读回拒绝 multisampled texture，调用方先 resolve。附件重复、extent/format/sample 不匹配会报错；失败录制可在同一帧重新提交有效命令。

## 本机覆盖

2026-10-09，Apple M1，Slang 2026.19，Metal 实际提交与 readback：

- R8、RGBA8、BGRA sRGB、RGBA16Float 的 2-layer / 3-mip texture：在多个非零 origin 更新矩形，使用额外行距 padding；验证六个 subresources 的全部字节，未改写的边界、mip、layer 保持原值。拒绝越界更新，纹理内容保持完整。
- RGBA8／BGRA8 及两种 sRGB color targets：通过 Slang shader 读取 UInt32 打包颜色，分别执行 1× 与 4× raster。中心像素符合颜色／sRGB 转换，4× 的轮廓具有非零、非满值的 alpha coverage；resolved image 在同一 command buffer 随后复制并读取。
- 两个连续 pass 验证 MSAA store、load 与第二次 resolve；第二个 pass 丢弃 source，resolved pixels 仍正确。
- RGBA16Float 的 4× HDR clear + depth attachment：resolve 精确保留半浮点通道值；目的纹理具有三个 mips，已初始化的 mip1 保持不变。混用 1× depth 与 4× color 被拒绝。
- 错误 resolve extent、format、source samples、资源 alias、pipeline samples 以及 MSAA upload/readback/buffer copy 被拒绝。之后同一 frame 提交有效 clear/resolve，结果正确。
- 平台无关的附件验证与边界溢出检查，以及 resolve 后跨 queue 采样的 release/acquire、timeline 依赖。

本轮 NativeRHI 97 项 XCTest、NativeRenderer 39 项 XCTest 与 shader 工具链 8 项 Python 测试通过。Swift maintainability 检查通过，现有 46 项超限指标未增加。新增能力不包含 UI 性能基准，现有场景对照的通过也不能替代 UI 对照。

Windows/Linux 的 Vulkan 与 Windows 的 DX12 实现及对应测试入口已同步编写，本轮没有在这些平台编译或运行。macOS 不提供 Vulkan／MoltenVK 路径。

```sh
SLANGC="$PWD/Engine/vendor/slang/bin/slangc" swift test --package-path Engine --jobs 4 \
  --filter 'NativeRHITests\.|NativeRendererTests\.'
python3 scripts/check-swift-maintainability.py --report
```

## 后续门槛

接入 Native DrawList renderer，覆盖字体图集增量更新、color glyph、普通图片、mask、逻辑坐标／像素缩放、scissor、alpha/sRGB/HDR 混合和 MSAA；使用真实 GuavaUI DrawList 与 WGPU 逐像素对照。随后迁移具有可靠资源所有权的 viewport 纹理桥、in-game UI、主／辅助窗口宿主，并测量同等工作量的帧性能。完成全部功能／画面／性能门槛后才切换默认值和删除 WGPU。
