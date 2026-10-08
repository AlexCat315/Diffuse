# Image / AsyncImage

`Image` 绘制已就绪纹理或同步文件/资源；`AsyncImage` 负责有边界的文件或 HTTP 图片请求，并把阶段交给调用方提供内容。`AsyncImageThumbnail` 保留缩略图入口，内部复用同一加载器与节点生命周期。

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

解码在 worker 完成，捕获的宿主调度器负责 GPU 上传和阶段发布。节点更换 URL/尺寸/密度/策略/重试身份时取消旧请求；结果通过 generation 校验，卸载后丢弃。失败不会因每次 body 更新反复重试；改变 `retryID` 发起重试，已成功的相同缓存键可以直接复用。

逻辑尺寸限定 1–4096 点，按有限有效显示密度请求物理缩略图，单轴最多 8192 像素。缓存键包含文件规范路径或完整远程 URL（包括 host/query）以及物理尺寸。后台先检查源尺寸再解码，保留宽高比；SVG 按请求物理尺寸栅格化，不受原始像素大小限制。位图不做无意义放大。fill 使用两倍缩略图边界再中央裁切，极端长宽比图片仍可能损失有效清晰度。

fit 在容器内等比居中；fill 将 UV 裁为中央区域，绘制矩形始终限定在容器内；stretch 使用完整 UV 改变比例。圆角、mask 与普通颜色纹理使用相同几何。缺失本地文件返回简洁的 `fileNotFound`，示例有明确占位、错误提示与重试。

测试覆盖：真实 HTTP 404、无 Content-Length 的超额数据、取消、来源替换、队列发布、卸载、失败重试、远程缓存身份；缩略图宽高比、源/目标像素限额、SVG HiDPI；fill 顶点边界与 UV。原生画廊展示 fit/fill/stretch、实际远程照片、缺图/空来源和恢复。

剩余限制：缓存尚无淘汰与 GPU 释放策略；相同键的在途下载未合并；不提供动画 GIF/WebP 播放、EXIF 方向归一化或渐进解码。没有扩展名的远程 SVG 尚未按响应 MIME 判断；PNG/JPEG 等常规位图及 WebP 通过内容识别。底层常规位图解码可能先分配完整源图再缩小，源像素上限限制峰值，不能宣称已支持任意大图的低内存解码。
