# Diffuse 媒体运行库

`MediaRuntime` 独立于场景、UI 和 SDL。FFmpeg 8.1.3 从官方源码构建并校验 SHA-256；构建禁用 GPL、nonfree、网络协议和外部自动探测。设备播放由 AudioRuntime/SDL 接入，不启动 ffmpeg 子进程。桌面剪辑导出使用同次构建的 `ffmpeg` 可执行文件，通过 argv 调用。

```sh
swift run --package-path Tools/Developer cove-dev media
swift test --package-path Engine/Media
# 移动目标复用相同 API：
swift run --package-path Tools/Developer cove-dev media --platform ios-arm64-simulator
ANDROID_NDK_HOME=/path/to/ndk swift run --package-path Tools/Developer cove-dev media --platform android-arm64
```

构建需要 sh、GNU make 和 C 编译器；Windows 使用 MSVC Developer 环境与 MSYS2 的 sh/make（不是 MinGW 编译器）。iOS 需要 Xcode。Android 需要 NDK，API 28+。所有目标的库和头文件位于 `vendor/FFmpeg.artifactbundle`，variant 可以同时存在；`COVE_MEDIA_ARTIFACT_ROOT` 可选择相对于此包的其他产物目录。`--check` 验证已暂存文件的完整性。

```swift
import MediaRuntime
let pcm = try AudioFile.decode(fileURL)        // 48 kHz Float32 stereo，最多 128 MiB
let stream = try AudioReader(url: fileURL)     // 长音频按块读取
while let buffer = try await stream.nextBuffer() { /* 交给应用的音频输出 */ }
let video = try VideoReader(url: fileURL)
let frame = try await video.frame(at: 1.25)    // RGBA 与时间戳
```

原生库提供 WAV、MP3、AAC/M4A、FLAC、Ogg/Vorbis/Opus 音频解码，以及 MP4/MOV、Matroska/WebM、AVI 中的 H.264、HEVC、MPEG-4、VP8/VP9 软件解码。解码能力取决于已启用的 codec，不以文件扩展名保证成功。禁止远程 URL；损坏文件、缺失流、错误 seek 和 resident 大小超限返回具体错误。

`AudioFile` 用于驻留音效，`AudioReader` 用于流式处理。`AudioRuntime.MediaPlayer` 将 `AudioReader` 与 `VideoReader` 接入 SDL，按播放时钟向调用方交付视频帧；取消调用 Task 会释放设备和解码状态。游戏 AudioSource/BGM 使用 FFmpeg PCM 和短 SDL 队列，支持实际声道 pan 和 pitch。

`MediaComposition` 只保存项目相对源路径、裁剪范围与输出视频规格。播放位置、解码器、纹理、任务和设备都不进入 JSON。桌面 `MediaExporter` 支持顺序裁剪拼接、尺寸/帧率归一化、缺失音轨补静音，输出 MPEG-4 + AAC MP4。输出通过临时文件完成后移动，不覆盖已有文件。此阶段尚无多轨转场、硬件解码、代理媒体或移动端导出。

发布工作站必须一起交付 `ffmpeg`、许可证、provenance 与构建说明。源码 URL 与固定哈希在 `Tools/Developer` 的 `MediaStaging`；完整官方源码、许可证及各原始静态 archive 保留在构建缓存/产物中，可使用同一脚本重新构建或重新链接。FFmpeg 的 LGPL 条款独立于第一方 Apache-2.0 代码，见 [官方许可证说明](https://ffmpeg.org/legal.html)。

源码下载优先使用 MacPorts distfiles 镜像，并回退至其他镜像和上游站点。所有来源必须匹配同一官方发行包的固定 SHA-256，版本、构建选项和许可证不因镜像而改变。
