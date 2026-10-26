[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# GuavaStudio

> 基于 Swift 构建、以 AI Agent 驱动的综合创作工作站：文本与代码编辑、游戏开发、动画制作和视频剪辑。

[GuavaUI SDK](https://github.com/AlexCat315/GuavaUI) 是独立项目，按 `Editor/guava.json` 声明的版本由 `./guava` 拉取到被忽略的 `GuavaUI/` 检出目录；它拥有 UI、NativeRHI、平台服务和 CLI。Studio 拥有场景、三维渲染、物理、脚本及其 UI 适配器。

---

-   🇬🇧 **英文版**: [README.md](README.md)

## 构建

### 前置依赖

- Swift 6.4.1 (Swift toolchain)
- CMake 4.4.4
- C/C++ 编译器：
  - macOS: Xcode 27.0 / Command Line Tools
  - Linux: GCC 或 Clang
  - Windows: Visual Studio 2026 (C++ workload)
- Git
- 图形后端：macOS 使用系统 Metal；Windows 默认 DX12，需要 Windows SDK，shader 编译需要 DXC；Linux 与 Windows 的 Vulkan 后端使用 SDK 固定的头文件，运行时加载系统图形驱动。

### 第一次构建

```bash
git clone https://github.com/AlexCat315/GuavaStudio.git
cd GuavaStudio
git submodule update --init --recursive
./guava studio native-bootstrap
./guava build Editor --mac
```

`./guava` 会先拉取 `Editor/guava.json` 声明的 SDK 版本到被忽略的 `GuavaUI/` 目录，也支持用 `GUAVA_SDK_ROOT` 选择本地检出。`guava studio native-bootstrap` 随后安装 SDK 发布的原生依赖，构建 Studio 的 FFmpeg、OpenEXR/Imath，并准备固定版本的 Wasmtime；Windows 下自动初始化 MSVC 工具链。

后续日常开发只需要：

```bash
./guava build Editor --mac
```

> **强制重编译原生依赖**：`./guava studio native-bootstrap --force`

### 按包独立构建

```bash
./guava internal build-package Engine    # 引擎核心
./guava build Editor    # 编辑器（运行: ./guava run Editor）
./guava internal build-package GuavaMcp --product GuavaMCP # MCP 服务
```

SDK 的共享核心、跨平台调试服务、浏览器原型与示例位于 [GuavaUI 仓库](https://github.com/AlexCat315/GuavaUI)。

应用开发统一使用 [Guava CLI](https://github.com/AlexCat315/GuavaUI/blob/main/Tools/Guava/README.md)：`./guava create app MyApp` 创建共享桌面 / Android / iOS 项目，`./guava run MyApp --mac` 或 `./guava run MyApp --android` 选择宿主；`build --release`、`test`、`clean` 使用同一项目配置。Editor 也是应用，可用 `./guava build Editor --mac`。桌面目标需在匹配主机构建；iOS / iPadOS 使用 Xcode、SDL/UIKit 生命周期和 Metal，可通过 `./guava build MyApp --ios`、`./guava run MyApp --ios --simulator UDID` 构建和运行；真机添加 `--device ID --team TEAM_ID`。Web 完整应用宿主仍在开发。Android 使用 Swift 6.4.1 与 NativeRHI Vulkan，可运行完整 GuavaUI Gallery，并将项目场景、资源和 Swift 游戏脚本静态编译为 APK。工具链、真机验证和签名导出命令见 [Android 接入说明](Platforms/Android/README.md)。

---

## 第三方依赖

| 库 | 形式 | 来源 |
|----|------|------|
| Yoga | SwiftPM 源码编译 | SwiftPM `facebook/yoga` 3.2.1 |
| FreeType | CMake 源码编译 → `.artifactbundle` | SDK 检出 `third-party/freetype` |
| HarfBuzz | CMake 源码编译 → `.artifactbundle` | SDK 检出 `third-party/harfbuzz` |
| SDL3 | SDK 发布包 / CMake 源码编译 | SDK 检出 `Runtime/third-party/sdl3` |
| Imath | CMake 源码编译 | submodule `Engine/third-party/imath` |
| OpenEXR | CMake 源码编译 | submodule `Engine/third-party/openexr` |
| Natsel | Swift Package Manager | 跟随 `AlexCat315/Natsel` main，锁文件记录实际提交 |
| Wasmtime | 固定版本静态 C API；iOS 使用 Pulley | Bytecode Alliance 49.0.2，SHA-256 校验 |
| FFmpeg | 固定版本 LGPL 静态库和桌面工具 | 官方 8.1.3 源码，SHA-256 校验 |

构建模式：每个 SPM 包的 native 依赖都在自己的 `<package>/third-party/` 下，CMake 编译产物落到 `<package>/vendor/`（gitignored），SPM 通过 `.binaryTarget(path:)` 消费。

---

## 项目结构

```
GuavaStudio/
├── Engine/Sources/       渲染 / 场景 / 物理 / 资产 / AI 运行时 / 观察总线 / 影视管线
├── GuavaUI/              独立 SDK 检出（被忽略；源码见 GuavaUI 仓库）
├── Editor/Sources/       创作工作站（文档、媒体时间线、场景、Agent）
├── GuavaMcp/Sources/    MCP 服务器（暴露 Guava 能力给 LLM agent）
└── .github/workflows/    CI 矩阵与 release
```

---

## 许可证

GuavaStudio 以 [Apache License 2.0](LICENSE) 开源。第三方依赖各自遵循其上游许可证，归属信息见 [NOTICE](NOTICE)。

应用开发从 [GuavaUI 安装与第一个应用](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/getting-started.md) 开始；统一 CLI 提供 SDK 选择、工具链检查、应用创建和开发会话。官网与文档站位于独立的 [GuavaWebsite 仓库](https://github.com/AlexCat315/GuavaWebsite)。

日志统一使用 swift-log；配置、文件轮转、Android logcat、Inspector 回放与 API 使用见 [日志系统](https://github.com/AlexCat315/GuavaUI/blob/main/Logging/README.md)。


Editor 的文本/代码和视频工作流共用现有 Agent 工具入口。视频时间线支持裁剪、排序、帧预览、播放和 MP4 导出；FFmpeg 负责解码/重采样/导出，SDL 负责设备输出。详见 [工作站边界](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture/workstation.md)、[媒体系统](Engine/Media/README.md)和 [GuavaUI 组件标准](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/standard.md)。
