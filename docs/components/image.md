# Image / AsyncImage

`Image` 绘制已就绪纹理或同步文件/资源；`AsyncImage` 负责有边界的文件或 HTTP 图片请求，并把阶段交给调用方提供内容。只需要占位内容时用 `AsyncImage(url:width:height:) { placeholder }`：加载完成显示图片，空/加载/失败时显示同尺寸占位（原 `AsyncImageThumbnail` 已合并进来）。

```swift
AsyncImage(url: photoURL, width: 160, height: 100,
           contentMode: .fill, retryID: retryID) { phase in
    switch phase {
    case .success(let image): AnyView(image.cornerRadius(8))
    case .loading: AnyView(Text("Loading…"))
    case .failure: AnyView(Text("Image unavailable"))
    case .empty: AnyView(Text("No image"))
    }
}
```

默认策略为 15 秒超时、20 MiB 文件/下载上限、3200 万源像素上限，可通过同步 `inout ImageLoadingPolicy` 调整。HTTP 同时检查状态、已知 Content-Length 与实际流式累积大小；本地文件在读取前后检查大小。取消也覆盖任务创建前的竞态。支持 file/http/https。

解码在 worker 完成，捕获的宿主调度器负责注册 CPU 图片和阶段发布。`ImageAssetRegistry()` 不需要 GPU renderer；不可变图片随节点、DrawList 和 snapshot 保留，NativeRHI 绘制器在各自的录制线程首次上传，后续帧复用纹理。节点更换 URL/尺寸/密度/策略/重试身份时取消旧请求；结果通过 generation 校验，卸载后丢弃。失败不会因每次 body 更新反复重试；改变 `retryID` 发起重试，已成功的相同缓存键可以直接复用。

文件图片在没有 registry 时也可直接解码。`Image(source: .asset(asset), width:height:)` 接收拥有 CPU 像素的图片；`Image(textureID:width:height:)` 仍可使用宿主手动注册的 GPU 纹理。`registry.clear()` 释放缓存引用，已保留的节点与在途帧仍能显示旧图；相同键的新图取得独立 TextureID，可与旧图同时绘制。最后一个 CPU 引用释放后，绘制器在下次录制时清理对应 GPU slot；尚未提交的 frame token 保留它使用的 GPU 资源。

逻辑尺寸限定 1–4096 点，按有限有效显示密度请求物理缩略图，单轴最多 8192 像素。缓存键包含文件规范路径或完整远程 URL（包括 host/query）以及物理尺寸。远程响应的已知图片 MIME 优先于 URL 扩展名（忽略大小写及参数）；缺失、未知或通用 MIME 回退到重定向后的最终 URL 扩展名，本地文件沿用文件扩展名。无扩展名的 `image/svg+xml` 响应也能解码。后台先检查源尺寸再解码，保留宽高比；SVG 按请求物理尺寸栅格化，不受原始像素大小限制。位图不做无意义放大。fill 使用两倍缩略图边界再中央裁切，极端长宽比图片仍可能损失有效清晰度。

fit 在容器内等比居中；fill 将 UV 裁为中央区域，绘制矩形始终限定在容器内；stretch 使用完整 UV 改变比例。圆角、mask 与普通颜色纹理使用相同几何。缺失本地文件返回简洁的 `fileNotFound`，示例有明确占位、错误提示与重试。

测试覆盖：真实 HTTP 404、无 Content-Length 的超额数据、取消、来源替换、队列发布、卸载、失败重试、远程缓存身份；缩略图宽高比、源/目标像素限额、SVG HiDPI；fill 顶点边界与 UV。原生画廊展示 fit/fill/stretch、实际远程照片、缺图/空来源和恢复。

## 缓存、合并、动画与方向

- **淘汰**：`ImageAssetRegistry(limits:)` 默认 256 MiB / 2,048 项，按最近使用（`cached` 与注册都会刷新）淘汰 CPU 像素；最新注册的条目即使单独超出预算也会保留并返回。`limits` 可运行时调整并立即收缩，`cachedBytes`/`cachedCount` 可观测。被淘汰的资产仍由持有它的节点与帧保留。
- **在途合并**：同一服务与缓存键（含重试身份）的并发请求共享一次下载与解码；每个等待者各自取消，最后一个等待者离开才取消共享任务，完成后条目移出，后续请求命中缓存或重新开始。
- **动画**：GIF（stb_image）与带动画标志的 WebP 解码为合成后的整帧序列（WebP 未依赖 libwebpdemux，桥接层自行解析 RIFF 的 ANMF 块并按混合/处置标志合成）。帧按缩略图尺寸缩放，总帧数受同一源像素预算约束（最多 300 帧）；≤10ms 的帧按浏览器惯例显示 100ms。`AsyncImage` 在共享动画调度器上播放，循环次数用尽后停在最后一帧，减少动态效果时停在首帧；已解码的动画按缓存键记忆，重新挂载不必重新下载。
- **EXIF 方向**：JPEG 的 APP1 Exif Orientation（1–8）在可移植解码路径上读取并旋转/镜像像素；缩略图边界按直立后的尺寸计算。
- **渐进预览**：下载每累积 64 KiB，macOS/iOS 共用 CoreGraphics + ImageIO 增量源，尝试解码当前前缀（渐进 JPEG、交错 PNG）。先读取源尺寸并执行 `maximumSourcePixels` 预算，再创建有尺寸上限的缩略图，应用 EXIF 方向并保持比例、不放大；头信息不足或尚不可解码的前缀返回 nil，继续等待下载。预览资产不写缓存，最终结果替换预览；取消/切换来源仍受请求 generation 校验。Linux/Windows 等无 ImageIO 的平台只显示最终图片。
- `ImagePipelineTests` 覆盖 LRU 淘汰、共享解码与取消、EXIF 读取与变换、两帧 GIF 解码与播放计时；`AsyncImageTests` 继续覆盖生命周期。

本轮回归：`AsyncImageTests.remoteVector` 通过本机 HTTP 和生产图片服务验证无扩展名 SVG、误导扩展名、通用 MIME 回退及重定向；`formatFallbacks` 覆盖 MIME 大小写/参数。`ProgressiveImageTests` 使用真实渐进 JPEG 的第一个扫描前缀验证预览像素、EXIF 旋转、比例、不放大、源像素预算和非法尺寸。Gallery Image 的 Remote 模式可编辑 URL，便于用自己的图片服务验证。对比图按可用宽度换列，加载图与操作区按宽度/字号切换纵横布局；`ImageLayoutTests.matrix` 覆盖 390/720/1280、100%/200% 与 LTR/RTL 的图片、URL 字段和 Retry 边界。

剩余限制：非 Apple 平台没有渐进解码；动画帧一次性解码到内存（受像素预算约束），不做流式帧解码。PNG/JPEG 等常规位图及 WebP 继续通过内容识别。底层常规位图解码可能先分配完整源图再缩小，源像素上限限制峰值，不能宣称已支持任意大图的低内存解码。动画自动化覆盖 GIF 与播放计时，WebP 动画合成仍需独立像素验收；渐进 JPEG 已有上述像素回归，交错 PNG 与真实 iOS 设备仍需取样。

## 本轮验收（2026-10-20）

- `swift test --package-path GuavaUI --no-parallel --filter Image`：32 项 Swift Testing 与 3 项 XCTest 通过，覆盖解码、资产、异步请求、缓存、动画与本轮预览。Gallery 既有 `GalleryTests|AdaptiveShellTests` 8 项通过；新增 `ImageLayoutTests` 通过 12 组宽度/字号/方向组合。
- DevTools 在 390×820 touch/200%、720×820 mixed/dark/100%、1280×820 pointer/RTL/200% 输入本机无扩展名 SVG URL，显式查询输入值并确认四个 `Loaded image` 语义（含异步来源）。Retry、Missing → Retry → Remote 均得到预期加载/失败/恢复状态。镜像确认 200×140 加载图、换列后的对比图及 URL/操作边界，窄屏操作纵排，宽屏与 RTL 正确并排。
- 渐进 JPEG 原生取样先发送 202,040 / 366,385 字节，在未结束的 HTTP 响应中已显示红/绿预览；释放剩余数据后更新为最终图片。原生输入使用 `guava-dev devtools query-ui/input-ui/capture-ui`，没有使用系统 UI 自动化。
- `GuavaUIRuntime` / `GuavaUICompose` 使用本机模拟器依赖、iPhoneSimulator 27.1 SDK，以 `arm64-apple-ios16.0-simulator` 完成 SwiftPM 构建，覆盖预览平台分支与生产下载调用。
- 以上窗口与像素回归在 macOS 执行；iOS 实机读屏、网络与画面仍需设备验收。
