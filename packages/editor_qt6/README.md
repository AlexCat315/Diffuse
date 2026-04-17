# Guava Editor Qt6 (Minimal)

这个目录提供一个可编译、可运行、可最小自检的 Qt6 编辑器壳层工程。

当前路线：QML/Qt Quick 为主，非必要不上 Widgets。

## 依赖

- CMake 3.21+
- C++20 编译器（Clang/GCC/MSVC）
- Qt6.5+（Core/Gui/Qml/Quick/QuickControls2/WebSockets）

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

可选：指定引擎地址（默认 `ws://127.0.0.1:9100`）

```bash
./build/guava_editor_qt6 --engine-url ws://127.0.0.1:9100
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

- 240fps + 浮动层叠加验证：

```bash
./build/guava_editor_qt6 --benchmark-viewport --benchmark-seconds 5
```

输出示例：

```text
BENCHMARK viewport_fps=253.10 target=240 overlay=ok
```

通过标准：

- 程序可编译
- 自检命令返回 0
- CTest 中 qt6_smoke 通过
- benchmark 命令返回 0（表示 fps >= 240 且 overlay=ok）
