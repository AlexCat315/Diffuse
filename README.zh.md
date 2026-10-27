[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Diffuse

> 基于 Swift 构建、以 AI Agent 驱动的综合创作工作站：文本与代码编辑、游戏开发、动画制作和视频剪辑。

[CoveUI SDK](https://github.com/AlexCat315/Cove) 是独立项目，按 `Editor/cove.json` 声明的版本全局安装，所有项目共享同一份源码与原生库；它拥有 UI、NativeRHI、平台服务和 CLI。Studio 拥有场景、三维渲染、物理、脚本及其 UI 适配器。

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
git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
./cove studio native-bootstrap
./cove build Editor --mac
```

先安装 Cove SDK；`./cove` 选择 `Editor/cove.json` 声明的共享版本，也支持用 `COVE_SDK_ROOT` 选择本地开发源码。`cove studio native-bootstrap` 随后安装 SDK 发布的原生依赖，构建 Studio 的 FFmpeg、OpenEXR/Imath，并准备固定版本的 Bun 桌面插件运行时；Windows 下自动初始化 MSVC 工具链。

后续日常开发只需要：

```bash
./cove build Editor --mac
```

> **强制重编译原生依赖**：`./cove studio native-bootstrap --force`

### 按包独立构建

```bash
./cove internal build-package Engine    # 引擎核心
./cove build Editor    # 编辑器（运行: ./cove run Editor）
./cove internal build-package DiffuseMCP --product DiffuseMCP # MCP 服务
```

SDK 的共享核心、跨平台调试服务、浏览器原型与示例位于 [CoveUI 仓库](https://github.com/AlexCat315/Cove)。

应用开发统一使用 [Cove CLI](https://github.com/AlexCat315/Cove/blob/main/Tools/Cove/README.md)：`./cove create app MyApp` 创建共享桌面 / Android / iOS 项目，`./cove run MyApp --mac` 或 `./cove run MyApp --android` 选择宿主；`build --release`、`test`、`clean` 使用同一项目配置。Editor 也是应用，可用 `./cove build Editor --mac`。桌面目标需在匹配主机构建；iOS / iPadOS 使用 Xcode、SDL/UIKit 生命周期和 Metal，可通过 `./cove build MyApp --ios`、`./cove run MyApp --ios --simulator UDID` 构建和运行；真机添加 `--device ID --team TEAM_ID`。Web 完整应用宿主仍在开发。Android 使用 Swift 6.4.1 与 NativeRHI Vulkan，可运行完整 CoveUI Gallery，并将项目场景、资源和 Swift 游戏脚本静态编译为 APK。工具链、真机验证和签名导出命令见 [Android 接入说明](Platforms/Android/README.md)。

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
| Bun | TypeScript 桌面插件运行时 | 固定版本 1.4.4，SHA-256 校验 |
| FFmpeg | 固定版本 LGPL 静态库和桌面工具 | 官方 8.1.3 源码，SHA-256 校验 |

构建模式：每个 SPM 包的 native 依赖都在自己的 `<package>/third-party/` 下，CMake 编译产物落到 `<package>/vendor/`（gitignored），SPM 通过 `.binaryTarget(path:)` 消费。

---

## 项目结构

```
Diffuse/
├── Engine/Sources/       渲染 / 场景 / 物理 / 资产 / AI 运行时 / 观察总线 / 影视管线
├── CoveUI/              CI 中指向共享 SDK 的链接（被忽略）
├── Editor/Sources/       创作工作站（文档、媒体时间线、场景、Agent）
├── DiffuseMCP/Sources/    MCP 服务器（暴露 Diffuse 编辑器能力给 LLM agent）
└── .github/workflows/    CI 矩阵与 release
```

---

## 许可证

Diffuse 以 [Apache License 2.0](LICENSE) 开源。第三方依赖各自遵循其上游许可证，归属信息见 [NOTICE](NOTICE)。

应用开发从 [CoveUI 安装与第一个应用](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/getting-started.md) 开始；统一 CLI 提供 SDK 选择、工具链检查、应用创建和开发会话。官网与文档站位于独立的 [GuavaWebsite 仓库](https://github.com/AlexCat315/GuavaWebsite)。

日志统一使用 swift-log；配置、文件轮转、Android logcat、Inspector 回放与 API 使用见 [日志系统](https://github.com/AlexCat315/Cove/blob/main/Logging/README.md)。


Editor 的文本/代码和视频工作流共用现有 Agent 工具入口。视频时间线支持裁剪、排序、帧预览、播放和 MP4 导出；FFmpeg 负责解码/重采样/导出，SDL 负责设备输出。详见 [工作站边界](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/architecture/workstation.md)、[媒体系统](Engine/Media/README.md)和 [CoveUI 组件标准](https://github.com/AlexCat315/GuavaWebsite/blob/main/docs/components/standard.md)。
