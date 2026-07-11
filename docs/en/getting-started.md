---
path: /en/docs/getting-started
title: Installation and quick start
description: Prepare the toolchain, compile native dependencies, and start Guava Editor.
locale: en
translationKey: docs.getting-started
category: Start
order: 20
kind: doc
---

# Installation and quick start

The first build prepares native dependencies. Day-to-day builds can then use SwiftPM directly.

## Prerequisites

- Swift 6.1 or newer
- CMake 3.20 or newer
- Git and Python 3
- Xcode Command Line Tools on macOS
- GCC or Clang on Linux
- Visual Studio 2022 with the C++ workload on Windows

## First build

```bash
git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive
python bootstrap.py
swift build --package-path Editor
```

Force a native rebuild with `python bootstrap.py --force`.

## Start the editor

```bash
swift run --package-path Editor EditorApp
```

Open a project directory directly:

```bash
swift run --package-path Editor EditorApp --project-dir /path/to/project
```
