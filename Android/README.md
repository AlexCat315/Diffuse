# Android NativeRHI / GuavaUI / GameRuntime

Android 宿主直接依赖生产 Engine、GuavaUI Runtime / Compose / Gallery 和 GameRuntime。使用 Swift **6.4.1 release**、Android NDK r30、ARM64 和 API 28 起的系统接口；渲染使用 NativeRHI Vulkan。桌面与 Android 共用组件、项目场景、Swift 游戏脚本、物理、图像解码和 HUD 实现。

## 工具链

Swift 工具链与 Android SDK 必须完全匹配，Xcode 自带 Swift 不能代替对应的开源交叉编译工具链。

```sh
swift sdk install https://download.swift.org/swift-6.4.1-release/android-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_android.artifactbundle.tar.gz --checksum a356b79f8f1daa6ae3a66f4c556966ca20c0208b3659805cf30a83a0a31d6772
swift sdk list
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
```

使用方构建需要 CMake、Ninja、JDK 21，以及匹配的 Swift 6.4.1 release；无需 Python。Android SDK 需要 `platform-tools`、`platforms;android-36`、`build-tools;36.1.0`，NDK 版本为 `30.0.16248370`。`--android-sdk` / `--ndk` 可覆盖自动发现路径；`GUAVA_SWIFT_EXECUTABLE` 可指定 Swift 可执行文件。Swift CLI 当前面向 macOS / Linux 构建主机；Windows 主机尚未接入。

```sh
git submodule update --init Engine/third-party/sdl3 Engine/third-party/jolt GuavaUI/third-party/freetype GuavaUI/third-party/harfbuzz
```

`Android/Tools` 是不依赖 UI / 引擎二进制的独立 Swift 工具包。它直接调用 SwiftPM、CMake、JDK 和 Android SDK，不调用 Python。原生依赖从仓库固定源码构建 SDL3、Jolt、lunasvg / plutovg、WebP、FreeType 和 HarfBuzz。Android artifact bundles 位于忽略的 `Engine/build/android-validation/native/vendor` 和 `fonts-cmake/vendor`，通过 `GUAVA_ENGINE_ARTIFACT_ROOT` / `GUAVA_TEXT_ARTIFACT_ROOT` 选择，保持桌面 archives 独立。Swift runtime 静态链接；FoundationNetworking 的 OpenSSL / zlib 也显式链接，并在链接阶段拒绝未解析符号。SDL 的 Java 类随应用打包，JNI 初始化由宿主转交 SDL。

参考 [Swift Android SDK 官方说明](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、[Swift 6.4 发布说明](https://www.swift.org/blog/swift-6.4-released/)、[SDL Android 宿主约定](https://wiki.libsdl.org/SDL3/README-android)。

## 使用自己的 GuavaUI 根视图

创建独立应用，无需修改引擎里的 Gallery 或 Android 宿主：

```sh
swift run --package-path Android/Tools GuavaAndroid create \
  --directory /absolute/path/to/MyApp \
  --application-id com.example.myapp --name 'My App'
cd /absolute/path/to/MyApp
swift android.swift --install --serial DEVICE_SERIAL
```

脚手架包含可编辑的根视图、按钮 / 状态 / 文本输入示例、资源目录、应用配置和构建入口。仓库中的 [GuavaUIStarter](../examples/GuavaUIStarter/README.md) 是同一模板生成的完整项目，可直接打开并修改。

使用方只需在自己的 `GuavaAndroidContent` 模块导出入口：

```swift
import GuavaUICompose
import GuavaUIRuntime

public enum ApplicationContent {
    public static func makeRoot() -> some View {
        MyRootView()
    }
}
```

`MyRootView` 可以来自已有的桌面 / 共享 UI 模块。宿主在 Compose、文本、图像和输入环境中安装根视图，复用 Gallery 的 LayerAware renderer、触摸滚动、长按、TextField IME、窗口密度与生命周期处理。使用方无需自行操作 Device、JNI 或 ANativeWindow。

`guava-android.json` 保存 `application_id` 与 `name`；`Package.swift` 导出名为 `GuavaAndroidContent` 的 library product / module，包目录可任意命名。已有 Swift Package 也可添加上述入口与配置后直接构建：

```sh
swift run --package-path Android/Tools GuavaAndroid build --app /absolute/path/to/MyApp \
  --configuration release --output /absolute/path/to/MyApp.apk
```

项目内 `swift android.swift` 默认输出 `build/Application.apk` 及相邻 JSON 构建报告。可传 `--android-sdk`、`--ndk`、`--application-id`、`--name` 和与游戏导出相同的签名参数。自定义应用具有独立的 Swift 构建缓存，构建工具显式选择应用模块，避免从上一轮 Gallery / 游戏构建继承内容。

SwiftPM resource bundles 自动打包并解包；模板的 `AppResources.bundle` 通过 `PackageResourceBundle` 定位，Debug / Release 通用。移动项目或引擎目录后，设置绝对路径 `GUAVA_ENGINE_ROOT` 即可让 launcher 与 SwiftPM 指向同一引擎。根视图状态在存活进程的暂停 / 旋转间保留，进程死亡后的业务状态持久化由应用负责。系统权限、图标、通知和商店发布需要应用进一步集成。

Swift CLI、使用方脚手架、自定义根视图入口及字体 CMake 构建路径在停止验证后新增，本轮未编译或进行真机验证；下文的验收结果对应迁移前的 Gallery / SharedCounter / CrystalRush。

## Gallery 与真机验收

在仓库根目录执行，设备须完成 USB 调试授权。多设备时指定 `--serial`。

```sh
swift run --package-path Android/Tools GuavaAndroid build --install --serial DEVICE_SERIAL
```

以下仅为仓库内部验收，需要 Python 3；截图比较额外需要 Pillow。使用 GuavaUI 和构建 / 导出应用无需安装它们。

```sh
python3 -m venv Engine/build/android-validation/verify-venv
Engine/build/android-validation/verify-venv/bin/python -m pip install Pillow
Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-gallery.py --serial DEVICE_SERIAL
Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-demo.py --serial DEVICE_SERIAL
python3 scripts/android/validate.py --serial DEVICE_SERIAL
```

默认 APK 运行完整 **GuavaUI Gallery（72 个页面）**。可用 `--component textField` 选择入口，或用 `--demo counter` 运行共享的 SharedCounter。Gallery 与桌面使用同一 `GalleryView` 和所有 story，没有另一份 Android 组件实现。

`verify-gallery.py` 遍历完整目录，为每页保存真实屏幕截图、像素检查和语义快照；另检查 Checkbox、Slider、长按 ContextMenu、TextField 选择替换 / 中文预编辑、前后台状态保留和手指滚动。`--pages` 可运行选定页面。语义快照来自共享 AccessibilityTree，包含可见控件的角色、标签、值和裁剪后的几何。

`--interactions-only` 可单独重跑组件交互。手指滑动转换为具有开始 / 改变 / 结束阶段的点单位滚动；长按在抬起时依据实际手势时长和移动距离确认，避免慢帧延迟事件投递后把滑动误判为长按。外接鼠标滚轮和键盘导航走共享事件路由。

`verify-demo.py` 回归 SharedCounter 的触摸、重组、字形像素、亮暗主题、IME、UTF-16 / 字素删除、Activity 重建、横竖屏、前后台和空闲停帧。`validate.py` 独立运行七项 GPU / 布局探针，检查 transfer、compute、1x / 4x raster、DrawList、深度、scissor 和数据读回。截图脚本需要 Pillow。

Android 由 `Choreographer` 显示刷新回调提供帧时机和动画时间戳，最多保留一个待处理回调；渲染完成后直接请求下次刷新，不追加 sleep。空闲回调跳过 GPU 工作，暂停时取消回调并释放窗口资源，恢复或 Surface 重建时重置动画时钟。Vulkan swapchain 的 VSync 设置只控制呈现模式，与是否持续重绘独立。

可在 Debug / Release APK 启动时显式开启诊断；以下参数不写入场景、checkpoint 或 `launch.json`：

```sh
adb shell am force-stop com.guava.probe
adb shell am start -W -n com.guava.probe/com.guava.probe.MainActivity \
  --es mode gallery --es component introduction \
  --ez benchmark true --ez timings true --ez vsync true
adb logcat -s GuavaAndroid:I
```

`benchmark=true` 在每次显示回调绘制；关闭 benchmark 后保留按需绘制。Debug 默认也不生成语义快照或逐帧写盘；自动化脚本需要启动时显式传入 `--ez snapshots true` 才会在绘制后发布 `files/demo-state.json`。benchmark 始终关闭自动快照，即使 snapshots 为 true。此 Java 诊断选项在 Activity Intent 中跨前后台和配置变更保留，不进入 Swift 场景配置。`vsync=false` 请求后端关闭同步，启动日志报告实际 `presentMode` 和 `displaySynchronized`，回退到 MAILBOX / FIFO 时不能解释为真正关闭同步。Release APK 的页面来自构建配置，运行时 `mode` / `component` 和调试广播仅在 Debug 生效。

`timings=true` 最多记录 1200 条 `android.frame`，包含 Compose / layout / 绘制列表准备、帧槽等待、drawable 获取、atlas 上传、命令录制、队列提交、呈现的 CPU 墙钟耗时，以及几何量。`android.pacing` 每秒报告显示回调、提交帧、空闲回调、按当前刷新率估算的遗漏刷新周期、回调耗时与投递延迟，最多 120 条。它们不代表 GPU 执行耗时或实际屏幕呈现帧率；显式启用后的 Debug 快照开销只计入 callbackWork。Debug 广播可设置运行参数重建场景并开始新的测量；仅切换 snapshots 不重建场景。仓库输入自动化已显式开启自动快照。需要检查状态时，也可发送 `--es demoAction snapshot` 的 `com.guava.probe.DEMO_INPUT` 广播写出一次快照，这不要求 snapshots=true，并可用于 benchmark。

显示时钟与运行时选项的独立主机测试可运行：

```sh
swiftc Android/Sources/GuavaAndroidApp/Frame/Clock.swift \
  Android/Sources/GuavaAndroidApp/Frame/RuntimeOptions.swift scripts/android/frame-clock-tests.swift \
  -o /tmp/guava-android-frame-clock-tests
/tmp/guava-android-frame-clock-tests
```

真机报告与截图分别放在 `gallery-run-*`、`demo-run-*`、`game-run-*`、`run-*/results`。脚本通过 debug APK 的输入广播调用同一 InputConnection / 游戏按键路径。英文输入另外确认真实系统 IME 已连接；回调回放不等同于所有输入法的人工验收。测试会重新启动验证应用；方向检查只调整应用请求，结束时可用 `--ei orientation -1` 恢复传感器方向。

## 导出完整游戏 APK

导出入口接受普通 Guava 项目目录。项目的 `.guava/editor-scene-manifest.json` 必须使用当前场景格式，脚本绑定必须可解析。

```sh
swift run --package-path Android/Tools GuavaAndroid export-game \
  --project examples/CrystalRush \
  --application-id com.guava.game.crystalrush \
  --name 'Crystal Rush' \
  --output Engine/build/android-validation/CrystalRush.apk \
  --install --serial DEVICE_SERIAL

Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-game.py --serial DEVICE_SERIAL
```

导出先调用 `GuavaProjectExport` / `ProjectExporter`，校验场景、绑定及资源依赖，再生成移动端构建输入。每个项目 Swift 脚本独占一个模块，允许多个脚本都使用既有的 `GameScript` 约定；聚合注册器按稳定 asset ID 注册进 GameRuntime。SwiftPM 将这些模块与播放器一起交叉编译、静态链接进 APK。手机无需 Swift 编译器，不依赖桌面动态脚本库。源代码与 `.guava/static-scripts.json` 属于主机构建输入，打包时排除。

APK 包含 Player 可加载的场景 save document、asset index、模型及其外部纹理 / buffer、音频和项目 catalog。应用通过原有 GameApplication / EngineHost 驱动脚本、场景、物理、音频和 NativeRenderer，GuavaUI HUD 与三维画面一起合成。屏幕控制条提供 WASD、Sprint、Start、Restart，可同时按住移动与加速；硬件方向键、键盘和 A / B 手柄按钮也映射到这些输入。`verify-game.py` 专门验收 CrystalRush 的真实场景、中文 HUD、开始、持续移动、重开、后台停帧和横竖屏恢复。

Release 构建与签名：

```sh
swift run --package-path Android/Tools GuavaAndroid export-game \
  --project /absolute/path/to/MyGame \
  --application-id com.example.mygame \
  --output /absolute/path/to/MyGame.apk \
  --configuration release \
  --keystore /absolute/path/to/release.keystore \
  --key-alias mygame \
  --store-password-env GUAVA_ANDROID_STORE_PASSWORD \
  --key-password-env GUAVA_ANDROID_KEY_PASSWORD
```

密码从指定环境变量读取，命令与日志只包含变量名。未提供 keystore 时使用本机生成的开发签名；这也适用于本仓库的 Release 验证包。Release APK 禁用 `debuggable`、验证广播和快照写盘。所有 APK 均经 zipalign（16 KB 页对齐）与 apksigner 校验，并输出相邻 JSON 构建报告。这里只生成 APK，商店 AAB、Play 发布及用户生产签名不在此导出器中。

## 移动 GPU shader

场景 renderer 在 Android 选择 `Shaders/Native/spirv-mobile`，使用 Vulkan 1.1 可接收的 SPIR-V 1.3。七个可配置粒子 compute kernel 具有完整 1…256 固定工作组变体，保留共同反射 ABI，不要求 maintenance4 / LocalSizeId。桌面 Vulkan、Metal、DX12 的 shader profile 保持各自配置。UI 继续使用已有的 SPIR-V 1.3 产物。

```sh
python3 scripts/bootstrap-rhi-slang.py
python3 scripts/compile-native-renderer-shaders.py --targets spirv-mobile
python3 scripts/test-rhi-shader-toolchain.py
```

产物在仓库内随代码交付，APK 只打包对应的 Vulkan target。生成器使用固定 Slang 2026.19；基础编译、工作组变体 ABI 和整个批次全部成功后才发布产物。测试解析所有移动端 SPIR-V，包括每一个工作组变体，检查版本、LocalSizeId 和真实 LocalSize。

## 状态与资源所有权

`AndroidApplication` 拥有 Device、UI renderer、Compose scene 或 GameSession；Activity 使用 non-configuration instance 保留这一对象。`SurfaceSession` 只拥有当前 ANativeWindow 的 swapchain 和 framebuffer。暂停、旋转或 Surface 重建会等待并释放窗口 GPU 资源，保留 Gallery 控件和正在运行的游戏；暂停时清理焦点、预编辑、指针捕获和持续按键，返回后按新窗口大小布局。场景线程与窗口线程通过同一 Device 的 `withFrameSession` 串行安排完整 GPU 帧。

APK 资源解包到应用私有 `files/runtime`，按安装版本替换，避免升级后留下旧资源或旧脚本库。debug 报告及玩家数据位于该目录之外。SharedCounter 的已提交状态与 Gallery 页码写入 Activity Bundle，进程销毁后可恢复；完整游戏模拟和 Gallery 各控件的内存状态只在存活进程中保留。游戏存档仍由项目自己的存档逻辑决定。

UI / backdrop shader 与场景资源统一通过 `PackageResourceBundle` 查找宿主提供的解包根目录，Debug 和 Release 使用同一规则。SwiftPM 生成的 `Bundle.module` 环境覆盖仅在 Debug 生效，不能作为 Release APK 的资源定位入口。

文字使用共享 HarfBuzz / FreeType / FontAtlas，优先采用设备 Roboto / Noto CJK / Symbols；APK 附带现有 Noto Emoji 轮廓字体及 OFL，覆盖设备系统彩色 Emoji 字体以外的符号。轮廓 Emoji 以文字颜色绘制；系统彩色 Emoji 的 PNG strike 尚未接入。IME 的光标、选择、预编辑、提交、删除、剪贴板和撤销使用同一 TextField 编辑状态，覆盖 TextArea / CodeEditor 的共享文本表面。控件语义用于自动化快照；Android TalkBack 桥接尚未实现。

## 验证设备与边界

2026-10-12，2405CRPFDC，Android 16 / API 36，Adreno 710。loader 报告 Vulkan 1.4.0，物理 GPU 驱动为 **Vulkan 1.1.128**，缺少 dynamic rendering / maintenance4，支持 timeline semaphore 和同步扩展。实际能力判断来自物理设备与 feature 查询。使用传统 render pass，不要求 dynamic rendering；NativeRHI 仍要求时间线信号量支持。

已完成完整 Gallery 页面的真实绘制和 CrystalRush 完整场景的真机运行。验证不代表所有组件的所有交互组合、所有第三方项目资源或全部 Android GPU 已覆盖。当前未启用 Khronos validation layer；设备使用同一通用 queue family，独立队列族同步仍需专门设备。Windows / Linux 宿主、DX12、RT / mesh 不由 Android 结果代替。

本轮验收：Gallery **72 页 + 6 项交互**、SharedCounter **22 项**、CrystalRush **8 项**和 NativeRHI **7 项**均通过。CrystalRush Release APK 也已安装，确认场景 / 中文 HUD、触控开始与移动、前后台恢复及禁用调试访问。主机侧 TextField 41 项、ProjectExporter 15 项、shader 工具链 11 项、UI renderer 生命周期 / backdrop 像素 15 项通过。CrystalRush 的胜负、超时、边界和重开另由主机玩法测试覆盖；Android 自动化没有穷举所有玩法路线。
