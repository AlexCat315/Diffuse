# Android NativeRHI / GuavaUI

Swift 6.4.0、Android NDK r30、ARM64、Android API 28 起的原生验证入口。`Sources` 中的符号链接直接编译 Engine NativeRHI 与 GuavaUI 绘制器，Swift 包依赖复用 GuavaUI Portable / Text。应用运行桌面 `GuavaUIDemo --shared-counter` 和浏览器使用的同一份 `SharedCounterView`，包括 Compose、State、ViewGraph、Yoga、事件分发和 DrawList。

文字经共享的 HarfBuzz / FreeType / FontAtlas 管线生成字形，由 NativeRHI Vulkan 绘制。Java 宿主负责 Surface、vsync、触摸、IME 和生命周期；应用内容中的标题、按钮、计数与输入文字都由 GuavaUI 绘制。此包不引入桌面宿主的 SDL、物理和图像解码二进制依赖。

## 工具链

使用 Swift.org 的 **6.4.0 release** 工具链，Android SDK 版本必须完全匹配。已装 Xcode 自带 Swift 不能代替相应的开源交叉编译 SDK。

```sh
swift sdk install https://download.swift.org/swift-6.4.0-release/android-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_android.artifactbundle.tar.gz --checksum 21fb555122a3d801ad943d48df7ebffdd8824de61c25c180bb792d3edaee0b43
swift sdk list
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
```

Android SDK 需要 platform-tools；构建 APK 还需要 `platforms;android-36`、`build-tools;36.1.0` 和 JDK（已用 JDK 21 验证）。NDK r30 在 SDK manager 中的版本为 `30.0.16248370`。主机需要 CMake、Ninja 和 Python 3；截图验收脚本还需要 Pillow。Slang 使用仓库固定的 2026.19，可通过 `python3 scripts/bootstrap-rhi-slang.py` 安装。

先初始化字体子模块：

```sh
git submodule update --init GuavaUI/third-party/freetype GuavaUI/third-party/harfbuzz
python3 -m venv Engine/build/android-validation/verify-venv
Engine/build/android-validation/verify-venv/bin/python -m pip install Pillow
```

构建脚本用 NDK 从仓库固定的 FreeType / HarfBuzz 源码构建 ARM64 静态库，生成 Text 包使用的 artifact bundle；输出位于 `Engine/build/android-validation/fonts/`。不会修改上游源码或覆盖桌面字体依赖。脚本校验 Swift release 版本，并通过 `GUAVA_TEXT_ARTIFACT_ROOT` 将 Android 字体产物传给本次 Swift 构建。`GUAVA_SWIFT_EXECUTABLE` 可指定匹配 SDK 的 Swift 可执行文件。

参考 [Swift 官方安装说明](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、[NDK 下载](https://developer.android.com/ndk/downloads)。

## 真机验证

在仓库根目录执行，设备必须完成 USB 调试授权。多个设备时指定 `--serial`；`--android-sdk` / `--ndk` 可覆盖自动发现路径。

```sh
python3 scripts/android/validate.py --serial DEVICE_SERIAL
python3 scripts/android/build-app.py --serial DEVICE_SERIAL --install
Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-demo.py --serial DEVICE_SERIAL
```

- `validate.py` 构建 ARM64 Swift 可执行程序，编译 Vulkan 1.1 / SPIR-V 1.3 的测试 shader，推送到独立的 `/data/local/tmp` 目录并实际运行。七项检查全部通过才成功；返回本次 JSON 和 PPM 像素报告，成功后清理设备上的本次临时目录。
- `build-app.py` 生成并校验 debug APK，`--install` 安装并启动 **GuavaUI SharedCounter**。Swift 静态 runtime、NDK 的 `libc++_shared.so` 与 shader 资源一起打包。
- `verify-demo.py` 对已安装应用执行 SharedCounter 验收：真实触摸与拖出取消、计数重组、亮暗主题、字形像素变化、IME、Unicode、Activity 重建、前后台恢复、横竖屏窗口布局及空闲时停止 GPU 提交。每次运行建立独立的 `demo-run-*` 目录，成功时保存 JSON 快照报告、截图与本进程日志。
- `smoke-app.py` 保留为较小的窗口生命周期冒烟入口；完整 SharedCounter 验收使用 `verify-demo.py`。

验收会强制重启 demo，清空本次内存状态。英文输入先确认真实 Android IME 已绑定 `DemoInputConnection`，再通过 `adb input` 注入按键；测试设备上的输入法需要 Space 确认候选词。中文预编辑、提交、取消及 Unicode 边界检查由仅供 debug APK 的 `com.guava.probe.DEMO_INPUT` 广播调用同一个 InputConnection，不能将这些回调检查等同于所有系统输入法的人工验收。

横竖屏检查改变的是应用的方向请求；平板的系统兼容模式可能以竖向窗口加左右留白呈现。验收使用真实 Surface 的屏幕偏移计算触摸与截图坐标。成功结束时恢复应用的传感器方向选择；中途失败时可执行 `adb -s DEVICE_SERIAL shell am start -n com.guava.probe/.MainActivity --ei orientation -1` 恢复。脚本不修改系统的方向、GPU 驱动选择或全局调试设置。

所有本机输出位于忽略的 `Engine/build/android-validation/`，包括 `GuavaAndroidProbe.apk`、字体库、各次 `run-*/results/report.json` 与 `demo-run-*/report.json`。APK 使用仅供验证的 debug 签名，启用调试快照和输入回放广播；生产应用需要独立的发布配置。

## 宿主与状态边界

`DemoScene` 安装共享组件，并拥有 Compose、布局、焦点和事件分发；`DemoTypography` 加载设备的 Roboto / Noto CJK 字体，使用共享文字管线；`SurfaceSession` 管理 RHI、swapchain、字体图集上传与呈现。JNI 使用 UTF-16 传递文字，保留中文和补充平面字符。

`DemoSurfaceView` 通过 Choreographer 跟随 vsync。场景没有输入、重组或树更新时不提交 GPU 帧；`onPause` 释放 surface 会话和 GPU 资源，返回应用后重新创建。计数、主题和已提交 note 作为共享组件检查点保存，在 Surface 或 Activity 重建时恢复；焦点、IME 预编辑和 GPU 对象是临时状态，不进入检查点。检查点也经 `onSaveInstanceState` 写入 Activity Bundle。

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
| SharedCounter Compose / State / 输入 | 22 个真机验收检查点通过，包括计数、主题、按钮路由、IME 和重建后状态恢复 |
| FreeType / HarfBuzz / R8 字体图集 | 真实计数字形像素随 State 改变；英文及中文绘制通过，最终场景缺失字形为 0 |
| GuavaUI Portable / Text 主机回归 | Portable 96 项、Text 12 项测试通过 |

22 个检查点之外，验收脚本还断言拖出取消、亮暗主题背景像素、计数字形截图变化、IME 绑定以及空闲帧计数不增长。成功的报告包含每个检查点的组件状态、控件布局、字体统计、帧计数和会话 ID。接入字体工具链后，七项 NativeRHI GPU/布局探针再次在真机通过。

当前使用核心 render pass 接口，framebuffer/render pass 对象保留到提交 fence 完成；无需 dynamic rendering。Vulkan 1.1 驱动必须有时间线信号量扩展。UI 离线 shader 统一生成 SPIR-V 1.3；其他场景 shader 仍有 SPIR-V 1.5 与 LocalSizeId，不能直接认为完整游戏渲染器已支持这台 GPU。RHI 会在创建 shader 前拒绝超过设备版本的 SPIR-V 和未启用 maintenance4 的 LocalSizeId。

Surface 采用 identity transform，让系统合成器旋转窗口坐标中的图像。先前直接使用 `currentTransform` 会错误承诺 shader 已完成预旋转；真实截图验证并修正了这个问题。完整游戏可后续增加显式预旋转契约，减少系统合成开销，参考 [Android Vulkan 方向处理](https://developer.android.com/games/optimize/vulkan-prerotation)。

本轮没有启用 Khronos validation layer；验证依据是真实提交、完整数据/像素断言及窗口生命周期。设备上的 graphics/compute/transfer 使用同一通用 queue family，不能据此确认独立队列族同步。Windows/Linux 宿主、DX12、Vulkan RT/mesh 仍需各自的验证。

SharedCounter 的 note 是在末尾追加、按字素删除的输入示例；完整 TextField 的光标、选择、撤销、滚动避让和无障碍语义尚未接入。当前字体入口读取两个设备系统字体路径；彩色 Emoji 和通用 Android 字体发现尚未实现。测试中的 🚀 检查 UTF-16 传输和删除，随后删除该字符，不代表彩色 Emoji 渲染已通过。

本轮按约定完成 SharedCounter，没有移植完整组件 Gallery。完整游戏还需要接入持续更新的游戏循环、图像/SDL/物理/音频依赖、场景 shader 的移动 GPU profile / 固定工作组策略，以及 APK 资源与 release 签名发布流程。这里的实际 GPU、窗口和共享 UI 验证已建立可复用的移植基础，尚不把桌面 Player/Editor 声明为可直接导出 Android。
