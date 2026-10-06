# GuavaUI 浏览器 Wasm 原型

浏览器和桌面现在运行同一份 `SharedCounterView` Compose 源码，以及真实的
ViewGraph、节点树、Yoga 布局、输入分发、State/Binding 和 DrawList。
Inspector 读取真实节点和失效记录，支持状态检查点、状态差异、输入录制和回放。

## 构建与运行

使用 Swift 6.4.0，以及**版本完全匹配**的官方 Wasm SDK：

```bash
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d

cd GuavaUI/Browser
npm ci
npm run build
npm run serve
```

打开 <http://127.0.0.1:8080>。在 macOS/Linux 主机编译；`dist/` 包含浏览器运行
依赖，无需运行时 CDN。Yoga 的 Wasm C++ 编译禁用异常，因为当前 WASI SDK 不提供
C++ 异常展开运行时。原生构建仍沿用原来的编译设置。

用 `GUAVA_WASM_CONFIGURATION=release npm run build` 生成优化构建并移除 DWARF；默认 debug
构建带 DWARF。`GUAVA_WASM_SDK` 可以指定另一对匹配的编译器和 SDK，
`GUAVA_WASM_OUTPUT` 可以指定独立输出目录。

WebGPU 需要安全上下文，本地 localhost HTTP 可用。设备不可用或丢失时，Canvas2D
绘制**同一份 Swift 顶点和索引**。用 `?renderer=canvas2d` 强制回退，或
`?renderer=webgpu` 要求 WebGPU。

## 桌面共用示例

从已完成原生依赖构建的仓库根目录运行：

```bash
GUAVA_DEVTOOLS=1 swift run --package-path GuavaUI GuavaUIDemo --shared-counter
```

桌面入口为 `GuavaUI/Sources/GuavaUIDemo/main.swift`，浏览器入口为
`Sources/GuavaUIBrowserPrototype/main.swift`。两者都安装
`../Portable/Sources/GuavaUISharedDemo/SharedCounterView.swift`。
宿主只负责窗口、绘制后端、文字绘制和输入适配。

## 共享模块

| 模块 | 桌面与浏览器共用的实现 |
| --- | --- |
| `Engine/PlatformCore` | 输入事件、光标、窗口 ID，输入事件可 Codable |
| `GuavaUICore` | State/Binding、颜色、DrawList、顶点、WGSL、字体值及字形布局 |
| `GuavaUIScene` | Node/RenderTree、Yoga、Recomposer、动画、焦点、捕获和事件分发 |
| `GuavaUIComposeCore` | View/ViewBuilder、ViewGraph、CompositionLocal、Box/Row/Column |
| `GuavaUIDevToolsScene` | 从实际节点树生成 Inspector 快照 |
| `GuavaUIDevToolsProtocol` | 消息结构、会话校验、订阅、状态差异、输入录制格式 |

桌面 Runtime/Compose/DevTools 继续导出这些类型。浏览器不编译 SDL、SwiftNIO
socket、引擎视口或 GPU 原生依赖。完整的主题控件库仍在桌面 Compose 模块中。

文字由宿主绘制：桌面使用现有 FreeType/HarfBuzz 字体管线，浏览器目前使用 Canvas
字体。字形布局与字体度量接口已拆到共享核心，FreeType/HarfBuzz 的 Wasm 构建、
字体加载、图集上传和字体 fallback 是下一阶段，尚未接入浏览器。
Canvas2D 回退的三角形颜色插值也不完全等同于 GPU 光栅化。

## 输入与调试

鼠标按下/释放、拖出取消、指针捕获、Tab 焦点和 Enter/Space 按钮操作都通过真实的
EventDispatcher。文字输入示例支持追加 Unicode 文本、按字素 Backspace、粘贴和
IME 预编辑/提交；它是一个简单的末尾编辑示例，尚未移植桌面完整 TextField 的选择、
光标导航和撤销。隐藏的 DOM 输入桥为浏览器 IME 提供焦点与候选窗口位置。

现有 Inspector 通过同源 `MessageChannel` 连接 `browser://guava`，无需浏览器监听
TCP。桌面 Inspector 连接 `ws://127.0.0.1:9229/`。两者使用同一套消息校验。

- **Capture / Restore / Diff**：Diff 比较编辑框里的检查点与当前状态，列出新增、
  删除和变化字段。示例要求 `count` 为 0…999999、`dark` 为 `true`/`false` 字符串；
  `note` 是最多 2048 个字素的字符串。旧检查点省略 `note` 时保留当前文字。
- **Record / Stop / Replay**：记录初始检查点、焦点和输入。回放先恢复检查点，
  再按顺序通过同一个输入分发器执行，每次输入后完成重组和布局。
  回放应使用录制时的视口大小，当前不会缩放指针坐标。
  最多记录 4096 个事件、768 KiB，超出后标记 `truncated`。时间戳用于诊断；当前回放不等待原始间隔。
  桌面录制由发起的连接独占，断开会停止录制。其他桌面宿主需提供录制回调才能启用按钮。
- 树快照包含实际布局、渲染和输入清单；状态写入标注真实 Compose scope。
  帧样本分别测量布局和绘制，浏览器 GPU 呈现时间仍为零。

控制台 `guavaDebug.snapshot` 查看当前帧，`guavaDebug.request(...)` 发送调试请求。
C ABI 缓冲区仅在下一次对应更新前有效，JavaScript 会先复制再调用其他 Wasm 导出。
Swift 源码断点需要支持 Swift 的 DWARF 调试扩展和源码映射；此处未提供完整 Swift
调试器，可参考 [Swift Wasm 调试说明](https://book.swiftwasm.org/getting-started/debugging.html)。

## 开发重载

```bash
npm run dev
```

开发服务器监听共享 Swift、浏览器宿主和 Inspector 文件，自动重编译完整 Wasm。
每个成功构建保存在独立目录，页面只加载完成的构建；重载前保存检查点，加载后恢复。
编译失败时显示错误浮层，旧页面继续可操作，修复后重新加载并保留最新状态。
这是重新构建后的页面重载，不支持修改正在运行的 Swift 实例；只保留宿主检查点里的状态。

## 可重复验证

```bash
swift test --package-path GuavaUI/Portable
swift build --package-path GuavaUI/Portable
cd GuavaUI/Browser
python3 -m pip install -r requirements-dev.txt
python3 -m playwright install chromium
npm run build
npm run verify
npm run verify:dev
```

浏览器脚本检查实际画面像素、输入、真实节点、失效追踪、状态差异、录制回放、
Inspector 重连、缩放和原生 WebSocket。文字检查包含中文/Emoji 与合成的浏览器 IME
事件，真实操作系统输入法仍需人工验收。开发脚本验证真实 Swift 编译、错误恢复与状态保留，
会临时修改宿主源码并在退出时还原。

`python3 verify.py --require-webgpu` 强制 GPU 验收，`--skip-native` 只验证浏览器；
`GUAVA_CHROMIUM` 可以指定 Chromium 路径。CI 覆盖 Linux/Windows Portable 和 Linux
浏览器流程，构建产物作为可下载的 artifact 上传。

本次 Linux/Swift 6.4.0 的完整桌面测试集与 Portable 测试、Canvas2D、真实 WebSocket
及开发重载检查通过。云环境 Chromium 在独立 WebGPU 清屏示例中同样会丢失设备或
呈现透明画布，**真实 WebGPU 画面的严格像素验收仍待可用 GPU 环境完成**。
