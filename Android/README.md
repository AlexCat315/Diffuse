# Android NativeRHI / GuavaUI / GameRuntime

Android 宿主直接依赖生产 Engine、GuavaUI Runtime / Compose / Gallery 和 GameRuntime。使用 Swift **6.4.0 release**、Android NDK r30、ARM64 和 API 28 起的系统接口；渲染使用 NativeRHI Vulkan。桌面与 Android 共用组件、项目场景、Swift 游戏脚本、物理、图像解码和 HUD 实现。

## 工具链

Swift 工具链与 Android SDK 必须完全匹配，Xcode 自带 Swift 不能代替对应的开源交叉编译工具链。

```sh
swift sdk install https://download.swift.org/swift-6.4.0-release/android-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_android.artifactbundle.tar.gz --checksum 21fb555122a3d801ad943d48df7ebffdd8824de61c25c180bb792d3edaee0b43
swift sdk list
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk-r30
```

主机需要 CMake、Ninja、Python 3，以及匹配的 Swift 6.4.0 release。已用 macOS ARM64 和 JDK 21 验证。Android SDK 需要 `platform-tools`、`platforms;android-36`、`build-tools;36.1.0`，NDK 版本为 `30.0.16248370`。`--android-sdk` / `--ndk` 可覆盖自动发现路径；`GUAVA_SWIFT_EXECUTABLE` 可指定 Swift 可执行文件。

```sh
git submodule update --init Engine/third-party/sdl3 Engine/third-party/jolt GuavaUI/third-party/freetype GuavaUI/third-party/harfbuzz
python3 -m venv Engine/build/android-validation/verify-venv
Engine/build/android-validation/verify-venv/bin/python -m pip install Pillow
```

构建脚本从仓库固定源码构建 SDL3、Jolt、lunasvg / plutovg、WebP、FreeType 和 HarfBuzz。Android artifact bundles 位于忽略的 `Engine/build/android-validation/native/vendor` 和 `fonts/vendor`，通过 `GUAVA_ENGINE_ARTIFACT_ROOT` / `GUAVA_TEXT_ARTIFACT_ROOT` 选择，保持桌面 archives 独立。Swift runtime 静态链接；FoundationNetworking 的 OpenSSL / zlib 也显式链接，并在链接阶段拒绝未解析符号。SDL 的 Java 类随应用打包，JNI 初始化由宿主转交 SDL。

参考 [Swift Android SDK 官方说明](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、[Swift 6.4 发布说明](https://www.swift.org/blog/swift-6.4-released/)、[SDL Android 宿主约定](https://wiki.libsdl.org/SDL3/README-android)。

## Gallery 与真机验收

在仓库根目录执行，设备须完成 USB 调试授权。多设备时指定 `--serial`。

```sh
python3 scripts/android/build-app.py --install --serial DEVICE_SERIAL
Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-gallery.py --serial DEVICE_SERIAL
Engine/build/android-validation/verify-venv/bin/python scripts/android/verify-demo.py --serial DEVICE_SERIAL
python3 scripts/android/validate.py --serial DEVICE_SERIAL
```

默认 APK 运行完整 **GuavaUI Gallery（72 个页面）**。可用 `--component textField` 选择入口，或用 `--demo counter` 运行共享的 SharedCounter。Gallery 与桌面使用同一 `GalleryView` 和所有 story，没有另一份 Android 组件实现。

`verify-gallery.py` 遍历完整目录，为每页保存真实屏幕截图、像素检查和语义快照；另检查 Checkbox、Slider、长按 ContextMenu、TextField 选择替换 / 中文预编辑、前后台状态保留和手指滚动。`--pages` 可运行选定页面。语义快照来自共享 AccessibilityTree，包含可见控件的角色、标签、值和裁剪后的几何。

`--interactions-only` 可单独重跑组件交互。手指滑动转换为具有开始 / 改变 / 结束阶段的点单位滚动；长按在抬起时依据实际手势时长和移动距离确认，避免慢帧延迟事件投递后把滑动误判为长按。外接鼠标滚轮和键盘导航走共享事件路由。

`verify-demo.py` 回归 SharedCounter 的触摸、重组、字形像素、亮暗主题、IME、UTF-16 / 字素删除、Activity 重建、横竖屏、前后台和空闲停帧。`validate.py` 独立运行七项 GPU / 布局探针，检查 transfer、compute、1x / 4x raster、DrawList、深度、scissor 和数据读回。截图脚本需要 Pillow。

真机报告与截图分别放在 `gallery-run-*`、`demo-run-*`、`game-run-*`、`run-*/results`。脚本通过 debug APK 的输入广播调用同一 InputConnection / 游戏按键路径。英文输入另外确认真实系统 IME 已连接；回调回放不等同于所有输入法的人工验收。测试会重新启动验证应用；方向检查只调整应用请求，结束时可用 `--ei orientation -1` 恢复传感器方向。

## 导出完整游戏 APK

导出入口接受普通 Guava 项目目录。项目的 `.guava/editor-scene-manifest.json` 必须使用当前场景格式，脚本绑定必须可解析。

```sh
python3 scripts/android/export-game.py \
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
python3 scripts/android/export-game.py \
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
