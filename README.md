[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Guava Engine

> 基于 Swift 构建的 AI-Native 3D 游戏与影视引擎。

---

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
python bootstrap.py
swift build --package-path Editor
```

`bootstrap.py` 跨平台统一：编译 Engine + GuavaUI 的 C/C++ 原生依赖（CMake），Windows 下自动初始化 MSVC 工具链。

后续日常开发只需要：

```bash
swift build --package-path Editor
```

> **强制重编译原生依赖**：`python bootstrap.py --force`

### 本地运行官方网站

项目官网与文档门户位于 `website/`，使用 Vue 3、TypeScript 和 Vite：

```bash
cd website
npm install
npm run dev
```

运行 `npm run build` 可完成内容校验、类型检查、测试和静态站点构建。

### 按包独立构建

```bash
swift build --package-path Engine    # 引擎核心
swift build --package-path GuavaUI   # UI 框架（运行示例: swift run GuavaUIDemo）
swift build --package-path Editor    # 编辑器（运行: swift run GuavaEditor）
swift build --package-path guava-mcp # MCP 服务（运行: swift run GuavaMCP）
```

---

## 第三方依赖

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
| Wasmtime | 固定版本官方 C API 动态库 → `.xcframework` | Bytecode Alliance release（SHA-256 校验，macOS） |

构建模式：每个 SPM 包的 native 依赖都在自己的 `<package>/third-party/` 下，CMake 编译产物落到 `<package>/vendor/`（gitignored），SPM 通过 `.binaryTarget(path:)` 消费。

---

## 项目结构

```
Guava-Engine/
├── Engine/Sources/       渲染 / 场景 / 物理 / 资产 / AI 运行时 / 观察总线 / 影视管线
├── GuavaUI/Sources/      声明式 UI 框架（Compose API + wgpu 渲染器）
├── Editor/Sources/       桌面编辑器（状态机、面板、AI 宿主）
├── guava-mcp/Sources/    MCP 服务器（暴露 Guava 能力给 LLM agent）
├── website/              Vue 3 官方网站、文档与社区门户
├── docs/                 架构、路线图、组件与蓝图文档
└── .github/workflows/    CI 矩阵与 release
```

---

## 许可证

Guava Engine 以 [Apache License 2.0](LICENSE) 开源。第三方依赖各自遵循其上游许可证，归属信息见 [NOTICE](NOTICE)。
