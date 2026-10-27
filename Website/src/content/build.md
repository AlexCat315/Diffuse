# 构建指南

本指南介绍如何从源码构建 Diffuse 工作站。

## 前置依赖

- **Swift 6.4.1**（Swift 工具链）
- **CMake 4.4.4**
- C/C++ 编译器：
  - macOS：Xcode 27.0 / Command Line Tools
  - Linux：GCC 或 Clang
  - Windows：Visual Studio 2026（C++ 工作负载）
- Git
- 图形后端：macOS 使用系统 Metal；Windows 默认 DX12，shader 编译需要 DXC；Linux 与 Windows 的 Vulkan 后端使用 SDK 固定头文件，运行时加载系统驱动。

## 第一次构建

```bash
git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
./cove studio native-bootstrap
./cove build Editor --mac
```

先安装 Cove SDK；`./cove` 会选择 `Editor/cove.json` 声明的共享版本，也支持用 `COVE_SDK_ROOT` 选择本地开发源码。

`cove studio native-bootstrap` 会：

- 安装 SDK 发布的原生依赖
- 构建 Studio 的 FFmpeg、OpenEXR / Imath
- 准备固定版本的 Wasmtime
- 在 Windows 下自动初始化 MSVC 工具链

## 日常开发

```bash
./cove build Editor --mac
```

> 强制重编译原生依赖：`./cove studio native-bootstrap --force`

## 按包独立构建

```bash
./cove internal build-package Engine            # 引擎核心
./cove build Editor                             # 编辑器（运行：./cove run Editor）
./cove internal build-package CoveMcp --product CoveMCP  # MCP 服务
```

## 运行编辑器

```bash
./cove run Editor
```

## 目标平台

Editor 本身也是一个应用，可像普通应用一样选择宿主：

```bash
./cove build Editor --mac
./cove build Editor --ios
```

Android 使用 Swift 6.4.1 与 NativeRHI Vulkan，可将项目场景、资源与 Swift 游戏脚本静态编译为 APK。

## 构建模式说明

每个 SPM 包的原生依赖都位于各自的 `<package>/third-party/` 下，CMake 编译产物落到 `<package>/vendor/`（gitignored），SPM 通过 `.binaryTarget(path:)` 消费。
