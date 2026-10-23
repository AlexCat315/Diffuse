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

Guava CLI 管理应用创建、构建、运行、测试、缓存和调试会话；独立的 [GuavaUI SDK](https://github.com/AlexCat315/GuavaUI) 提供 UI、NativeRHI、平台宿主和模板。GuavaStudio 提供编辑器、场景、物理和脚本。应用开发者使用 `import GuavaUI`，业务代码放在 `Sources/AppContent`。

CLI 和桌面原生依赖通过 GuavaUI GitHub Releases 分发。安装 CLI 不需要 Swift；编译应用需要 Swift 6.4.1 和对应平台工具。项目通过 `toolchain.sdkVersion` 固定 SDK 版本。

## 1. 安装主机工具

先按 [Swift 官方安装说明](https://www.swift.org/install/) 安装 **Swift 6.4.1**。macOS / Linux 可以用 Swiftly 管理版本，已安装 Swiftly 时运行：

```sh
swiftly install 6.4.1
swiftly use 6.4.1
swift --version
```

macOS 还需要 Apple Command Line Tools（`xcode-select --install`），以及 Git、CMake、Ninja；安装了 Homebrew 时可运行 `brew install git cmake ninja`。Apple 的安装界面需要用户完成。

Windows 需要 Swift 官方页面列出的 Visual Studio C++ 工具和 Windows SDK；CLI 自动加载其编译环境。Linux 需要本机 C/C++ 编译器、pkg-config 和窗口系统开发包。Vulkan 头文件随 SDK 提供，运行时使用系统图形驱动。`guava doctor` 提供诊断入口。

## 2. 安装 CLI 与 SDK

如果已经有这个仓库，直接从仓库根使用 `./guava` 即可，无需下载或发布 SDK：

```sh
./guava setup --mac
./guava run GuavaUI/Examples --mac
./guava run Editor --mac
```

在 `GuavaUI` 目录对应命令是 `./guava run Examples --mac`。Studio 的原生依赖准备使用 `./guava studio native-bootstrap`。`zsh: command not found: guava` 表示独立命令尚未安装或不在 PATH。

使用 Swiftly 时，如果 `swift --version` 仍显示系统编译器，可设置 `export GUAVA_SWIFT_EXECUTABLE="$HOME/.swiftly/bin/swift"` 后再执行上述命令。

```sh
curl -fsSL https://github.com/AlexCat315/GuavaUI/releases/latest/download/install.sh -o /tmp/guava-install.sh
sh /tmp/guava-install.sh
# 重新打开终端后：
guava --version
guava sdk install 0.1.0
guava setup --mac
```

Windows 使用同一 Release 的 `install.ps1`，入口位于 `%LOCALAPPDATA%\Guava\bin`。macOS / Linux 入口位于 `~/.local/bin`。安装器维护用户 PATH，重新打开终端生效。Linux 最后一步使用 `guava setup --linux`；用户安装状态可通过 `GUAVA_HOME` 指定。

已经安装 CLI 后，可以安装另一个固定版本的源码 SDK：

```sh
guava sdk install 0.1.0
guava setup --mac
# 或使用已有 checkout：
guava sdk use /path/to/GuavaUI
guava sdk list
guava self update
```

SDK 存放在安装根目录的 `sdks/VERSION`，选择状态保存在该目录下的 `sdk.json`。项目仍使用自己的固定版本；本地开发覆盖写入忽略的 `.guava/sdk.json` 或通过 `GUAVA_SDK_ROOT` 指定。`self update` 校验下载包并切换 CLI 入口，保留旧版本目录。

`doctor` 汇总检查结果和安装步骤；`setup` 准备 SDK 的预编译桌面原生依赖。源码开发可使用 CMake、Ninja 和 Zig 构建依赖。它们不会替用户接受 Apple / Android 许可证，也不会自动切换全局编译器。

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
| Windows | Swift 6.4.1、Visual Studio C++ / Windows SDK、Git、图形驱动 |
| Linux | Swift 6.4.1、C/C++、Git、窗口系统开发包、图形驱动 |
| Android | Swift / Git / CMake / Ninja / make + JDK 21、Android SDK / NDK r30、匹配的 Swift Android SDK；不要求 Node |
| iOS / iPadOS | macOS、完整 Xcode、Swift、make、CMake、Ninja、Rust 与对应 iOS target |
| 浏览器原型 | 单独的 Swift / Wasm SDK 配对、Node、CMake、Ninja，验证时还需要 Chromium；并非普通桌面 / Android 应用的前置条件 |

桌面发布包覆盖 macOS arm64、Windows x86_64 和 Linux x86_64。Swift 编译器和目标平台 SDK 仍用于编译应用代码。
