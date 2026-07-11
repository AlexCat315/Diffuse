---
path: /zh/docs/getting-started
title: 安装与快速开始
description: 准备工具链、编译原生依赖并启动 Guava Editor。
locale: zh
translationKey: docs.getting-started
category: 开始
order: 20
kind: doc
---

# 安装与快速开始

第一次构建需要完成原生依赖编译，之后日常开发可直接使用 SwiftPM。

## 前置依赖

- Swift 6.1 或更高版本
- CMake 3.20 或更高版本
- Git 与 Python 3
- macOS：Xcode Command Line Tools
- Linux：GCC 或 Clang
- Windows：Visual Studio 2022 C++ 工作负载

## 首次构建

```bash
git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive
python bootstrap.py
swift build --package-path Editor
```

`bootstrap.py` 会构建 Engine 与 GuavaUI 使用的 C/C++ 依赖，并将结果放在各包的 `vendor/` 目录。需要重新构建时运行：

```bash
python bootstrap.py --force
```

## 启动编辑器

```bash
swift run --package-path Editor EditorApp
```

也可以直接指定项目目录：

```bash
swift run --package-path Editor EditorApp --project-dir /path/to/project
```

## 独立构建包

```bash
swift build --package-path Engine
swift build --package-path GuavaUI
swift build --package-path Editor
swift build --package-path guava-mcp
```
