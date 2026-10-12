# Android NativeRHI / GuavaUI

Swift 6.4.0、Android NDK r30、ARM64、Android API 28 起的原生验证入口。`Sources` 中的符号链接直接编译 Engine NativeRHI、GuavaUI 绘制器与 Portable 包；没有复制后端或另写 Android GPU 绘制器。此包避开 Engine/GuavaUI 桌面宿主的 SDL、物理、字体及图像解码二进制依赖。

## 工具链

使用 Swift.org 的 **6.4.0 release** 工具链，Android SDK 版本必须完全匹配。已装 Xcode 自带 Swift 不能代替相应的开源交叉编译 SDK。

```sh
swift sdk install https://download.swift.org/swift-6.4.0-release/android-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_android.artifactbundle.tar.gz --checksum 21fb555122a3d801ad943d48df7ebffdd8824de61c25c180bb792d3edaee0b43
swift sdk list
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
```

Android SDK 需要 platform-tools；构建 APK 还需要 `platforms;android-36`、`build-tools;36.1.0` 和 JDK。NDK r30 在 SDK manager 中的版本为 `30.0.16248370`。Slang 使用仓库固定的 2026.19，可通过 `python3 scripts/bootstrap-rhi-slang.py` 安装。工具不会修改系统的屏幕方向、GPU 驱动选择或全局调试设置。

参考 [Swift 官方安装说明](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、[NDK 下载](https://developer.android.com/ndk/downloads)。

## 真机验证

在仓库根目录执行，设备必须完成 USB 调试授权。多个设备时指定 `--serial`；`--android-sdk` / `--ndk` 可覆盖自动发现路径。

```sh
python3 scripts/android/validate.py --serial DEVICE_SERIAL
python3 scripts/android/build-app.py --serial DEVICE_SERIAL --install
python3 scripts/android/smoke-app.py --serial DEVICE_SERIAL
```

- `validate.py` 构建 ARM64 Swift 可执行程序，编译 Vulkan 1.1 / SPIR-V 1.3 的测试 shader，推送到独立的 `/data/local/tmp` 目录并实际运行。七项检查全部通过才成功；返回本次 JSON 和 PPM 像素报告，成功后清理设备上的本次临时目录。
- `build-app.py` 生成并校验 debug APK，`--install` 安装并启动 `Guava Vulkan Probe`。Java 只管理 Surface、资源解包和触摸入口；彩色几何由 Swift NativeRHI + GuavaUI 绘制。顶部状态文字使用 Android TextView，尚不代表 GuavaUI 字体系统已移植。
- `smoke-app.py` 对已安装应用分别验证横竖屏创建、触摸重绘、回到桌面后的 surface 释放与返回应用后的重新呈现，保存截图和进程日志。结束时恢复应用的传感器方向选择，不修改系统方向设置。

所有本机输出位于忽略的 `Engine/build/android-validation/`，包括 `GuavaAndroidProbe.apk`、`app-smoke.json`、横竖屏截图与日志，以及各次 `run-*/results/report.json`。APK 使用仅供验证的 debug 签名和静态 Swift runtime；不是生产发布配置。

## 已验证与边界

2026-10-12，设备型号 2405CRPFDC，Android 16 / API 36，Adreno 710。loader 报告 Vulkan 1.4.0，**物理 GPU 驱动仅报告 Vulkan 1.1.128**，缺少 dynamic rendering、maintenance4；支持 `VK_KHR_timeline_semaphore`。因此设备能力判断必须以物理设备及 feature 查询为准。

| 检查 | 结果 |
| --- | --- |
| NativeRHI 默认后端、Android surface 默认值 | Vulkan / ANativeWindow / RGBA8 |
| 纹理上传、transfer 队列复制与读回 | 256 字节全量相等 |
| Compute storage buffer / indirect dispatch | 16 个 UInt32 结果全量相等 |
| Raster、uniform binding、direct / indirect draw、深度、load/store、帧槽复用 | 1x / 4x 均通过，检查中心、背景及 MSAA 边缘像素 |
| GuavaUI DrawList + NativeDrawListRenderer | 1x / 4x 颜色、scissor、保留图像上传与采样像素通过 |
| GuavaUI Scene / Yoga | 布局、脏标记传播与重置通过；ComposeCore 同时完成 Android 编译 |
| ANativeWindow / Vulkan swapchain | 横竖屏呈现、触摸重绘、surface 释放与重建通过 |

当前使用核心 render pass 接口，framebuffer/render pass 对象保留到提交 fence 完成；无需 dynamic rendering。Vulkan 1.1 驱动必须有时间线信号量扩展。UI 离线 shader 统一生成 SPIR-V 1.3；其他场景 shader 仍有 SPIR-V 1.5 与 LocalSizeId，不能直接认为完整游戏渲染器已支持这台 GPU。RHI 会在创建 shader 前拒绝超过设备版本的 SPIR-V 和未启用 maintenance4 的 LocalSizeId。

Surface 采用 identity transform，让系统合成器旋转窗口坐标中的图像。先前直接使用 `currentTransform` 会错误承诺 shader 已完成预旋转；真实截图验证并修正了这个问题。完整游戏可后续增加显式预旋转契约，减少系统合成开销，参考 [Android Vulkan 方向处理](https://developer.android.com/games/optimize/vulkan-prerotation)。

本轮没有启用 Khronos validation layer；验证依据是真实提交、完整数据/像素断言及窗口生命周期。设备上的 graphics/compute/transfer 使用同一通用 queue family，不能据此确认独立队列族同步。Windows/Linux 宿主、DX12、Vulkan RT/mesh 仍需各自的验证。

完整游戏与完整 GuavaUI Android 应用还需要：Android 的持续帧循环与完整输入/IME/无障碍，NDK 构建的字体、图像、SDL/物理/音频依赖，场景 shader 的移动 GPU profile / 固定工作组策略，以及 APK 资源与 release 签名发布流程。这里的实际 GPU 和窗口验证已建立可复用的移植基础，尚不把桌面 Player/Editor 声明为可直接导出 Android。
