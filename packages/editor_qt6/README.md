# Guava Editor Qt6 (Minimal)

这个目录提供一个可编译、可运行、可最小自检的 Qt6 编辑器壳层工程。

## 依赖

- CMake 3.21+
- C++20 编译器（Clang/GCC/MSVC）
- Qt6.5+（Core/Gui/Widgets）

## 构建

```bash
cd packages/editor_qt6
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j
```

如果 CMake 找不到 Qt6，请设置 Qt 安装前缀，例如：

```bash
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/qt/lib/cmake"
```

## 运行

```bash
./build/guava_editor_qt6
```

## 最小验证

- 命令行自检（不弹 UI，适合 CI）：

```bash
./build/guava_editor_qt6 --self-test -platform offscreen
```

- CTest：

```bash
ctest --test-dir build --output-on-failure
```

通过标准：

- 程序可编译
- 自检命令返回 0
- CTest 中 qt6_smoke 通过
