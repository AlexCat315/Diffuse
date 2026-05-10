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

**不需要** Homebrew、`brew install`，**不需要**任何运行时系统包。

### 第一次构建

```bash
git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive

# 构建 native 第三方依赖（SDL3 / OpenEXR / Imath 从源码编译；wgpu-native 从上游 release 下载）
cmake -S third-party -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native --parallel --target SDL3-static
cmake --install build/native
cmake --build build/native --parallel --target stage_ocio_openexr

# Swift 构建
cd Editor && swift build
```

后续日常开发只需要 `swift build`，CMake 步骤只在首次或升级第三方依赖时跑。

### 第三方依赖

| 库 | 形式 | 来源 |
|----|------|------|
| Yoga | SPM path-based 依赖 | submodule `GuavaUI/Sources/CYoga/upstream` |
| FreeType | SPM 源码编译 | submodule `GuavaUI/Sources/CFreeType/upstream` |
| HarfBuzz | SPM 源码编译 | submodule `GuavaUI/Sources/CHarfBuzz/upstream` |
| SDL3 | CMake 源码编译 → `.artifactbundle` | submodule `third-party/sdl3` |
| Imath | CMake 源码编译 | submodule `third-party/imath` |
| OpenEXR | CMake 源码编译 | submodule `third-party/openexr` |
| wgpu-native | 配置时从 gfx-rs 公开 release 下载 | 无 submodule（Rust 项目，CMake 无法源码编译） |

所有 native 产物输出到 `Engine/vendor/`（gitignored），各开发者机器自行构建。
