# Diffuse 媒体运行库

`MediaRuntime` 独立于场景、UI 和 SDL。通用 demux/decode 由 Cove 的 `cove-media` 承担（`ffmpeg-sys-next =9.0.1`，FFmpeg 9.x 静态库编入 `OUT_DIR`，不写共享前缀）；Diffuse 只保留剪辑时间线、合成与导出策略。

设备播放与音频解码由 `cove-media` 播放器接线（后续批次）。桌面剪辑导出使用外部 FFmpeg 9.x 命令行工具，通过 argv 调用：**`cove-media` 的 FFmpeg 构建带 `--disable-programs`，`OUT_DIR` 里没有 `ffmpeg`/`ffprobe`**，因此工作站需要安装 FFmpeg 9.x，或用 `COVE_FFMPEG_EXECUTABLE`/`COVE_FFPROBE_EXECUTABLE` 指定。

## 探测与导出

`FFmpegTools::{executable, ffprobe}` 依次查找：环境变量覆盖、可执行文件旁的 `Tools/`、上一级的 `Helpers/`、系统 `PATH`。`MediaAsset::inspect` 用一次 `ffprobe -show_format -show_streams -of json` 得到时长、视频尺寸和音轨信息；非本地文件一律拒绝。

`MediaComposition` 只保存项目相对源路径、裁剪范围与输出视频规格。`MediaExporter` 支持顺序裁剪拼接、尺寸/帧率归一化、缺失音轨补静音，输出 MPEG-4 + AAC MP4；导出前用 `inspect` 预检范围与音轨，输出通过临时文件完成后移动，不覆盖已有文件。

## 测试

```sh
cargo test -p diffuse-media -- --test-threads=1
```

6 个测试覆盖 WAV/M4A/MP4 的流信息探测、composition JSON 往返、真实 FFmpeg 拼接导出与错误枚举。同步 PCM 拉取与逐帧 seek 曾由 `CFFmpegBridge` 提供，已随 FFmpeg 8.1.3 底座一起删除；这部分能力由 `cove-media` 播放器接线时重建。

许可证：FFmpeg 的 LGPL 条款独立于第一方 Apache-2.0 代码，见 [官方许可证说明](https://ffmpeg.org/legal.html)。固定版本 SHA-256、provenance 与各平台 LGPL 分发材料按批次 85 的决策不再由 Diffuse 维护。
