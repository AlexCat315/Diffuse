# GuavaUI 浏览器 Wasm 原型

这个原型把真实的 guavaUI Swift 核心编译为 WebAssembly，在浏览器中处理状态、
点击命中、几何生成和调试协议，再由 WebGPU 绘制。计数器、重置、主题切换、
节点选择以及状态检查点均可交互验证。

## 构建与运行

使用 Swift 6.4.0，以及**版本完全匹配**的官方 Wasm SDK：

```bash
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d

cd GuavaUI/Browser
npm ci
npm run build
npm run serve
```

打开 <http://127.0.0.1:8080>。编译工作在 macOS/Linux 主机上进行；生成的静态
文件可由支持 Wasm 的浏览器加载。`dist/` 包含所有运行依赖，不依赖运行时 CDN。

默认生成带 DWARF 的 debug 构建。可用 `GUAVA_WASM_CONFIGURATION=release npm run build`
生成较小的发布构建，或用 `GUAVA_WASM_SDK` 指定另一个已安装的匹配 SDK。
普通 Swift 运行时和 Foundation 会增加二进制体积；这个版本优先验证复用和调试。

WebGPU 需要安全上下文（本地 localhost HTTP 可用）。没有可用的 WebGPU 设备或
设备丢失时，会使用 Canvas2D 绘制**同一份 Swift 生成的顶点与索引**。
可用 `?renderer=canvas2d` 强制回退，或 `?renderer=webgpu` 要求 WebGPU。

## 实际复用范围

`../Portable/Sources/GuavaUICore` 是桌面与浏览器共同使用的实现：

- `State` / `Binding` / `DynamicProperty`；
- `Color`、`UIRect`、20 字节的 `UIVertex`；
- `DrawList` 的批次合并、裁剪、圆角和几何生成；
- 同一份 WGSL。UI 纹理使用显式零级采样，满足浏览器的控制流一致性检查。

原型的布局、输入适配与节点描述位于 `Sources/GuavaUIBrowserPrototype/main.swift`。
它通过小型 C ABI 导出向浏览器提供帧缓冲和 JSON；导出缓冲在对应的下一次更新前
有效，JavaScript 在调用下一次 Wasm 操作前复制数据。

**完整 Compose/ViewGraph、Yoga 布局、FreeType/HarfBuzz、原生窗口和引擎视口尚未移植。**
首版文字由浏览器字体绘制，Canvas2D 回退的三角形颜色插值也不等同于 GPU 光栅化。
后续可以在这个可运行入口上逐步接入这些模块。

## 调试

页面嵌入现有 GuavaUI Inspector，通过同源 `MessageChannel` 连接 `browser://guava`，
使用同一份 `guava-devtools/0.1` 消息结构，无需浏览器监听 TCP 端口。
可以检查节点、选择按钮、查看失效记录、捕获状态、修改检查点并恢复。
计数器状态要求 `count` 为 0…999999 的字符串，`dark` 为 `true`/`false` 字符串。

原型耗时样本记录 Swift 帧构建和序列化耗时；GPU 提交/呈现时间尚未接入，因此
`presentMs` 和独立的 `layoutMs` 为零。原生帧镜像与日志采集未在这个浏览器宿主中提供。

浏览器控制台的 `guavaDebug.snapshot` 可查看当前帧，`guavaDebug.request(...)`
可发送协议请求。Swift 源码断点需要另行配置支持 Swift 的 DWARF 调试扩展及源码映射，
可参考 [Swift Wasm 调试说明](https://book.swiftwasm.org/getting-started/debugging.html)。
源码断点、热重载、事件录制与完整 Compose 检查目前不属于此原型的已实现功能。

## 可重复验证

从仓库根目录开始：

```bash
swift test --package-path GuavaUI/Portable
swift build --package-path GuavaUI/Portable
cd GuavaUI/Browser
python3 -m pip install -r requirements-dev.txt
python3 -m playwright install chromium
npm run verify
```

验证脚本启动临时静态服务器和原生 DevTools probe，检查实际画面像素、鼠标与按钮输入、
状态恢复、Inspector 连接、重连和窗口缩放。它同时检查真实的原生 WebSocket 服务。
可用 `python3 verify.py --require-webgpu` 强制验证 GPU 路径，或 `--skip-native`
只验证浏览器；`GUAVA_CHROMIUM` 可以指定 Chromium 可执行文件。

本次在 Linux、Swift 6.4.0 上通过了桌面 `GuavaUIApp` 编译、46 项相关桌面回归
测试、7 项 Portable 测试，以及 Canvas2D 和真实 WebSocket 的浏览器检查。
当前云环境的 Chromium 在独立 WebGPU 清屏示例中也会丢失设备或呈现透明画布，
因此 **WebGPU 画面的严格像素验收尚未通过**；可先用 `?renderer=canvas2d` 运行。
Windows 已加入 CI 测试矩阵，本次没有在 Windows 主机上实测。
