# Guava Engine

Guava Engine 是基于 Swift 构建的 AI-Native 游戏引擎与影视创作编辑器。

## 构建

### 前置依赖

- Swift 6.1+ (Swift toolchain)
- CMake 3.20+
- C/C++ 编译器：
  - macOS: Xcode Command Line Tools
  - Linux: GCC 或 Clang
  - Windows: Visual Studio 2022 (C++ workload)
- Git

### 第一次构建

```bash
git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive
swift bootstrap.swift
swift build --package-path Editor
```

`bootstrap.swift` 跨平台统一：编译 Engine + GuavaUI 的 C/C++ 原生依赖（CMake），Windows 下自动初始化 MSVC 工具链。

后续日常开发只需要 `swift build --package-path Editor`。

> **强制重编译原生依赖**：`swift bootstrap.swift --force`

### 第三方依赖

| 库 | 形式 | 来源 |
|----|------|------|
| Yoga | CMake 源码编译 → `.artifactbundle` | submodule `GuavaUI/third-party/yoga` |
| FreeType | CMake 源码编译 → `.artifactbundle` | submodule `GuavaUI/third-party/freetype` |
| HarfBuzz | CMake 源码编译 → `.artifactbundle` | submodule `GuavaUI/third-party/harfbuzz` |
| SDL3 | CMake 源码编译 → `.artifactbundle` | submodule `Engine/third-party/sdl3` |
| Imath | CMake 源码编译 | submodule `Engine/third-party/imath` |
| OpenEXR | CMake 源码编译 | submodule `Engine/third-party/openexr` |
| JoltPhysics | CMake 源码编译 → `.artifactbundle` | submodule `Engine/third-party/jolt` |
| wgpu-native | 配置时从 gfx-rs 公开 release 下载 | 无 submodule（Rust 项目，CMake 无法源码编译） |

构建模式：每个 SPM 包的 native 依赖都在自己的 `<package>/third-party/` 下，CMake 编译产物落到 `<package>/vendor/`（gitignored），SPM 通过 `.binaryTarget(path:)` 消费。统一模式，跨平台一致。
