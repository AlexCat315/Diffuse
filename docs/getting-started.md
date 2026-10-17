---
path: /zh/docs/getting-started
title: '创建第一个 GuavaUI 应用'
description: '创建第一个 GuavaUI 应用 — GuavaStudio documentation'
locale: zh
translationKey: getting-started
category: guides
order: 100
kind: doc
---

# 创建第一个 GuavaUI 应用

Guava CLI 管理应用创建、构建、运行、测试、缓存和调试会话；Guava SDK 提供 Engine、GuavaUI、平台宿主和模板。应用开发者使用 `import GuavaUI`，业务代码放在 `Sources/AppContent`。

当前提供**源码 SDK**安装，尚未发布预编译 CLI / 原生 SDK 下载包。首次安装需要 Git 和 Swift 6.4.1；共享 C/C++ 依赖由 `guava setup` 在 SDK 中构建一次，多个应用共用。CLI 与 SDK 应使用同一仓库版本。

## 1. 安装主机工具

先按 [Swift 官方安装说明](https://www.swift.org/install/) 安装 **Swift 6.4.1**。macOS / Linux 可以用 Swiftly 管理版本，已安装 Swiftly 时运行：

```sh
swiftly install 6.4.1
swiftly use 6.4.1
swift --version
```

macOS 还需要 Apple Command Line Tools（`xcode-select --install`），以及 Git、CMake、Ninja；安装了 Homebrew 时可运行 `brew install git cmake ninja`。Apple 的安装界面需要用户完成。

Windows 需要 Swift 官方页面列出的 Visual Studio C++ 工具和 Windows SDK，再安装 Swift；使用 Developer PowerShell。Linux 需要本机 C/C++ 编译器、CMake、Ninja、pkg-config，以及窗口系统开发包、Vulkan SDK 和可用驱动。不同发行版请按其包管理器安装；`guava doctor --linux` 提供诊断入口。

## 2. 安装 CLI 与源码 SDK

如果已经有这个仓库，直接从仓库根使用 `./guava` 即可，无需下载或发布 SDK：

```sh
./guava setup --mac
./guava run GuavaUI/Examples --mac
./guava run Editor --mac
```

在 `GuavaUI` 目录对应命令是 `../guava run Examples --mac`。`zsh: command not found: guava` 表示独立命令尚未安装或不在 PATH；源码入口与下面的用户目录安装流程都可以使用。

使用 Swiftly 时，如果 `swift --version` 仍显示系统编译器，可设置 `export GUAVA_SWIFT_EXECUTABLE="$HOME/.swiftly/bin/swift"` 后再执行上述命令。

```sh
git clone --recurse-submodules https://github.com/AlexCat315/GuavaStudio.git "$HOME/.guava/source"
cd "$HOME/.guava/source"
# 可先 git checkout 某个已发布版本；此时还需更新其 submodules。
Tools/Guava/install.sh
export PATH="$HOME/.local/bin:$PATH"
guava sdk list
guava setup --mac
```

Windows 对应入口是 `Tools/Guava/install.ps1`，默认安装到 `%LOCALAPPDATA%\Guava\bin`，将其加入 PATH。Linux 最后一步使用 `guava setup --linux`。安装脚本登记当前源码 SDK；安装位置可通过脚本参数指定，用户 SDK 状态可通过 `GUAVA_HOME` 指定。

已经安装 CLI 后，可以安装另一个固定版本的源码 SDK：

```sh
guava sdk install https://github.com/AlexCat315/GuavaStudio.git --revision COMMIT_OR_TAG
guava setup --mac
# 或使用已有 checkout：
guava sdk use /path/to/GuavaStudio
guava sdk list
```

`install` 按 Git 提交存放在 `~/.guava/sdks/<commit>`，包含该提交的子模块；选择状态保存在 `~/.guava/sdk.json`。选择 SDK 影响随后创建的应用。现有应用继续使用自己的 `guava.json`，不会被全局切换静默升级。

`doctor` 汇总检查结果和安装步骤；`setup` 在检查通过后准备源码 SDK 的桌面原生依赖。它们不会替用户接受 Apple / Android 许可证，也不会自动切换全局编译器。

## 3. 创建、运行与测试

在希望保存应用的目录执行：

```sh
guava create app HelloGuava --platforms mac,android
cd HelloGuava
guava run --mac
guava test
guava run --mac --devtools
guava run --mac --profile --devtools
guava build --mac --release
guava clean
```

Windows / Linux 创建时选择 `win` / `linux`，在对应主机运行。省略 `--platforms` 会生成桌面、Android 和 iOS 的五种原生平台配置，但只需要安装实际开发目标的工具。iOS/iPadOS 通过 `guava run MyApp --ios --simulator UDID` 构建运行，真机提供 `--device ID --team TEAM_ID`；完整 Web 应用宿主仍在开发。

默认模板没有桌面可执行目标；CLI 将启动包生成到 `.guava/build/desktop/launcher`。`Sources/AppContent/App.swift` 提供共享根视图，`Assets` 是共享资源。只有自定义桌面宿主才需要在 `targets.desktopExecutable` 指定自己的可执行产品，例如 Editor。

## 4. 按需增加 Android 工具链

Android 目标额外需要 JDK 21、Android SDK（platform-tools、API 36、build-tools 36.1.0）、NDK r30（30.0.16248370）和与编译器完全匹配的 Swift Android SDK 6.4.1。Gradle Wrapper 由应用携带，无需全局安装 Gradle；Android Studio 是可选的管理入口。当前 Android 构建主机支持 macOS / Linux，目标为 arm64-v8a、API 28+。

安装 [Android Command-line Tools](https://developer.android.com/studio) 后可以使用 [sdkmanager](https://developer.android.com/tools/sdkmanager) 安装所需组件并交互式审阅许可证：

```sh
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0" "ndk;30.0.16248370"
sdkmanager --licenses
# 使用官方发布页的下载地址和 checksum 安装匹配的 Swift Android SDK。
swift sdk list
guava doctor --android
guava setup --android
guava devices --android
guava run --android --device SERIAL --devtools
```

可用 `ANDROID_HOME`、`ANDROID_NDK_HOME`、`JAVA_HOME`、`GUAVA_SWIFT_EXECUTABLE` 或 CLI 参数选择已有工具链。`doctor` 会列出具体缺项。手机需要授权 ADB 与 USB 安装。

`Platforms/Android` 是应用拥有的标准 Gradle 项目，Manifest、资源和 Java 扩展由应用维护；共享 Java/JNI 宿主由 SDK 的 `:guavaRuntime` 提供。Gradle preBuild 与 CLI 使用同一套 Swift 准备流程。

## 工具链范围

| 目标 | 应用开发所需增量工具 |
| --- | --- |
| macOS | Swift 6.4.1、Apple SDK、Git、CMake、Ninja |
| Windows | Swift 6.4.1、Visual Studio C++ / Windows SDK、Git、CMake、Ninja、Vulkan SDK / 驱动 |
| Linux | Swift 6.4.1、C/C++、Git、CMake、Ninja、窗口系统开发包、Vulkan SDK / 驱动 |
| Android | Swift / Git / CMake / Ninja / make + JDK 21、Android SDK / NDK r30、匹配的 Swift Android SDK；不要求 Node |
| iOS / iPadOS | macOS、完整 Xcode、Swift、make、CMake、Ninja、Rust 与对应 iOS target |
| 浏览器原型 | 单独的 Swift / Wasm SDK 配对、Node、CMake、Ninja，验证时还需要 Chromium；并非普通桌面 / Android 应用的前置条件 |

源码 SDK 会带来原生编译工具的安装负担。未来发布预编译 SDK 时，应把原生依赖随各主机/目标架构打包；Swift 编译器和目标平台 SDK 仍是编译用户代码的工具，不能被 CLI 的安装名义隐藏。
