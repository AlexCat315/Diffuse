# Clangd Qt 集成快速开始

## ✨ 问题解决概述

已成功集成 Zig 引擎和 Qt Editor 的编译信息到 clangd，使其能够识别所有库和头文件。

## 🚀 快速开始（3 步）

### 1️⃣ 生成编译数据库
```bash
cd packages/engine
zig build compile-commands
```

这会自动：
- ✅ 配置 Qt CMake 项目
- ✅ 构建 Qt Editor：生成 `packages/editor_qt/build/compile_commands.json` (11 entries)
- ✅ 生成引擎编译数据库：生成 `compile_commands.json` (248+ entries)
- ✅ 合并两个数据库：生成最终的 `compile_commands.json` (259+ entries)

### 2️⃣ 安装 Clangd VS Code 扩展
- 打开 VS Code
- 搜索并安装 **"Clangd"** (by llvm-vs-code-extensions)

### 3️⃣ 禁用 IntelliSense
在 `.vscode/settings.json`：
```json
{
  "C_Cpp.IntelliSenseEngine": "disabled"
}
```

## ✅ 验证

打开 Qt 文件，应该看到：
- ✅ Qt 类提示（`QMainWindow`, `QWidget` 等）
- ✅ 函数补全
- ✅ 定义跳转 (`F12` or `Cmd+Click`)

## 📂 集成方式详解

### 编译数据库结构
```
compile_commands.json (6796 lines)
├── [1-248]    引擎文件（Zig）
│   ├── PlutoVG, STB, LunaVG
│   ├── Jolt Physics
│   ├── Recast/Detour Navigation
│   ├── SoLoud Audio
│   └── Vulkan C binding
└── [249-259]  Qt Editor 文件（CMake）
    ├── MainWindow.cpp/h
    ├── ViewportWidget.mm
    ├── SceneTreeWidget.cpp/h
    ├── InspectorWidget.cpp/h
    ├── EngineClient.cpp/h
    ├── Theme.cpp/h
    ├── MacOS.mm/h
    └── AutoMOC生成文件
```

### 文件配置

| 文件 | 作用 | 修改日期 |
|------|------|---------|
| `CMakeLists.txt` | 启用 `CMAKE_EXPORT_COMPILE_COMMANDS` | ✅ |
| `build.zig` | 集成 CMake + Python 合并 | ✅ |
| `build/merge_compile_commands.py` | 合并两个数据库 | 新建 |
| `.clangd` | Clangd 配置 | 新建 |
| `docs/clangd-qt-integration.md` | 完整文档 | 新建 |

## 🛠️ Qt 库识别示例

编译命令中包含：
```bash
/usr/bin/c++ \
  -DQT_CORE_LIB \
  -DQT_GUI_LIB \
  -DQT_NETWORK_LIB \
  -DQT_WEBSOCKETS_LIB \
  -DQT_WIDGETS_LIB \
  -I/opt/homebrew/opt/qt/lib/QtCore.framework/Headers \
  -I/opt/homebrew/opt/qt/lib/QtGui.framework/Headers \
  ...
```

## 🔧 如果 Qt 库未被识别

1. **重新生成编译数据库**
   ```bash
   rm packages/editor_qt/build/compile_commands.json
   cd packages/engine && zig build compile-commands
   ```

2. **重启 Clangd**
   - `Cmd+Shift+P` → "Clangd: Restart Language Server"

3. **清除缓存**
   ```bash
   rm -rf ~/.cache/clangd/
   ```

## 📋 工作流程

### 添加新的 Qt 源文件
```bash
# 1. 添加文件到 CMakeLists.txt（如果需要）
# 2. 重新生成编译数据库
cd packages/engine && zig build compile-commands
```

### 更新 Qt 库版本
```bash
# CMake 会自动检测 Qt 位置（/opt/homebrew/opt/qt/）
cmake --build packages/editor_qt/build
```

## 📚 更多信息

详见 `docs/clangd-qt-integration.md` 了解：
- 手动生成流程
- 故障排查
- 编译数据库结构详解
- Clangd 高级配置

---

**状态**：✅ 集成完成  
**支持**：Qt 6.x + C++20 + Zig Engine  
**最后更新**：2026年4月9日
