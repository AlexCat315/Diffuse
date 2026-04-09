# Clangd 配置指南 - Qt Editor 集成

## 概述

本项目现在支持通过合并的 `compile_commands.json` 为 clangd 提供完整的编译信息，涵盖：
- **引擎部分**（Zig 构建系统）：248+ 编译命令
- **Qt Editor 部分**（CMake 构建系统）：11+ 编译命令

## 生成编译数据库

### 方法1：使用 Zig Build（推荐）

```bash
cd packages/engine
zig build compile-commands
```

此命令会：
1. ✅ 配置 Qt CMake 项目
2. ✅ 构建 Qt Editor 以生成其 `compile_commands.json`
3. ✅ 生成引擎的 `compile_commands.json`
4. ✅ 合并两个数据库到根目录的 `compile_commands.json`

### 方法2：手动生成

```bash
# 配置 Qt CMake 项目
cmake -B packages/editor_qt/build -S packages/editor_qt -G Ninja

# 构建 Qt Editor
cmake --build packages/editor_qt/build

# 生成引擎编译数据库（从 packages/engine 目录）
zig build compile-commands

# 合并编译数据库
python3 packages/engine/build/merge_compile_commands.py
```

## 配置说明

### `.clangd` 配置文件

已在项目根目录创建 `.clangd` 文件，配置了：
- ✅ 使用合并的 `compile_commands.json`
- ✅ 支持 Qt 库识别
- ✅ 代码补全、内联提示等功能

### Qt 库识别

Qt 库信息包含在编译命令中：
```
-I/opt/homebrew/opt/qt/lib/QtCore.framework/Headers
-I/opt/homebrew/opt/qt/lib/QtGui.framework/Headers
-I/opt/homebrew/opt/qt/lib/QtWidgets.framework/Headers
...
```

## Clangd 集成步骤

### VS Code 配置

1. **安装 Clangd 扩展**
   - 搜索并安装 "Clangd" (llvm-vs-code-extensions)

2. **禁用内置 IntelliSense**
   ```json
   // .vscode/settings.json
   {
     "C_Cpp.IntelliSenseEngine": "disabled"
   }
   ```

3. **配置 Clangd 路径**
   ```json
   {
     "clangd.arguments": [
       "--query-driver=/opt/homebrew/bin/c++",
       "--header-insertion=iwyu"
     ]
   }
   ```

### 验证 Clangd 识别

在任何 Qt 文件中：
```cpp
#include <QMainWindow>  // ← 应该被识别
```

Hover 时应该看到 Qt 框架的完整补全和定义跳转。

## 故障排除

### 如果 Qt 库未被识别

1. **清理并重新生成**
   ```bash
   rm packages/editor_qt/build/compile_commands.json
   cd packages/engine && zig build compile-commands
   ```

2. **检查合并是否成功**
   ```bash
   tail -50 compile_commands.json | grep -i "qt\|webkit"
   ```

3. **验证 clangd 配置**
   ```bash
   clangd --version
   clangd --compile-commands-dir=. --query-driver=/opt/homebrew/bin/c++
   ```

### Clangd 缓存问题

```bash
# 清除 clangd 缓存
rm -rf ~/.cache/clangd/
```

然后在 VS Code 中：
- 按 `Cmd+Shift+P`
- 搜索 "Clangd: Restart Language Server"

## 编译数据库结构

根目录 `compile_commands.json` 包含：
- 前 248 项：引擎 C/C++ 文件（Zig 构建）
- 后 11 项：Qt Editor 文件、MOC 生成文件（CMake 构建）

```json
[
  {
    "directory": "/path/to/engine",
    "file": "...third_party/lunasvg/plutovg/source/plutovg-blend.c",
    "arguments": ["/usr/bin/clang", "-std=c11", ...]
  },
  // ... 248 more engine commands
  {
    "directory": "/path/to/editor_qt/build",
    "file": "/path/to/editor_qt/src/util/Theme.cpp",
    "command": "/usr/bin/c++ -DQT_CORE_LIB -DQT_WIDGETS_LIB ...",
    "output": "..."
  },
  // ... 10 more Qt commands
]
```

## 自动化

### CMake 配置

在 `packages/editor_qt/CMakeLists.txt` 中已添加：
```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
```

这确保每次 CMake 构建时都会生成 `compile_commands.json`。

### Zig Build 集成

在 `packages/engine/build.zig` 中已配置：
1. CMake 配置和构建步骤
2. 编译数据库生成
3. Python 合并脚本调用

## 维护

当添加新的 Qt 文件时：
```bash
# 自动更新编译数据库
cd packages/engine && zig build compile-commands
```

或手动构建 Qt：
```bash
cmake --build packages/editor_qt/build
python3 packages/engine/build/merge_compile_commands.py
```

---

**注意**：本配置支持 C++20 标准，包括最新的 Qt 6.x 特性。
