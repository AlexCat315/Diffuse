# GuavaUI

应用代码默认只依赖 `GuavaUI` 产品，并使用一个导入：

```swift
import GuavaUI

try Application.run { Text("Hello, GuavaUI!").padding(24) }
```

窗口、设备、文字、输入、布局、图像上传与帧提交由宿主负责。可运行的最小应用在 [`examples/HelloUI`](../examples/HelloUI)，共享桌面 / Android / iOS 根视图的项目在 [`examples/GuavaUIStarter`](../examples/GuavaUIStarter)。从仓库根目录运行：

```sh
swift run --package-path examples/HelloUI HelloUI
swift run --package-path GuavaUI/Examples GuavaUIDemo
swift run --package-path GuavaUI/Examples GuavaUIDemo --component textField
swift run --package-path GuavaUI/Examples GuavaUIDemo --component web
swift run --package-path GuavaUI/Examples PetDemo
```

框架内部仍按 Compose、Runtime、Text、Portable 划分职责；工作台、DevTools 和原生渲染集成使用显式模块。示例在 `Examples/` 独立包内，正式框架不依赖 Gallery 或 Counter。Counter 的纯 Compose 示例与测试位于 `examples/Counter`，可供浏览器和原生宿主共享。详见[模块边界与迁移](../docs/architecture/module-boundaries.md)。

可选的 `GuavaUIWebView` 产品把平台原生网页视图接入 Compose 布局：GuavaUI 拥有 frame、裁剪与生命周期，浏览器视图由宿主的 `WebViewHost` 提供。macOS 已提供 `AppleWebKitHost`（`WKWebView`）；Windows / Linux / Android 需要各自的后端实现。网页是原生子视图，不进入 DrawList，因此不参与 DevTools 镜像、圆角/透明度合成或 z-order。详见[WebView](../docs/components/webview.md)。

可选的 `GuavaUIAgent` 产品提供通用工具契约、模型工具调用循环、MCP 端点、skills 和 DevTools 诊断查询。纯模型与协议应用可直接使用 Portable 的 `GuavaUIAgentCore`，无需 Editor 或 GPU。详见[通用 AI 底层与应用适配](../docs/architecture/agent-framework.md)。

需要调整默认行为时，配置对应的职责组：

```swift
let configuration = ApplicationConfiguration(title: "My App") {
    $0.typography.fontSize = 18
    $0.rendering.sampleCount = 4
    $0.frames.policy = .eventDriven
}
try Application.run(config: configuration) { MyRootView() }
```

默认按输入、状态和动画重绘，空闲窗口不持续提交帧。`--no-vsync` 请求关闭呈现同步；后端会报告实际模式，MAILBOX / FIFO 回退仍可能同步。`--benchmark` 显式启用持续重绘：

```sh
swift run --package-path GuavaUI/Examples GuavaUIDemo --benchmark
swift run --package-path GuavaUI/Examples GuavaUIDemo --benchmark --no-vsync
GUAVA_FPS_LOG=1 swift run --package-path GuavaUI/Examples GuavaUIDemo --benchmark
```

桌面宿主在 macOS 14 及以上使用 `NSWindow.displayLink`，macOS 13 使用随窗口换屏重新绑定的 `CVDisplayLink`。隐藏或最小化窗口暂停刷新，积压信号合并为最新一帧；呈现后没有额外的一周期 sleep 或忙等。尚未接入原生刷新源的平台会输出警告，并按绝对 deadline 回退；`.fixed(...)` 始终使用软件 deadline。

DevTools 通过 `./guava run GuavaUI/Examples --devtools` 启动并自动连接；应用项目使用 `guava run --devtools`，真机使用 `--android --devtools`。`guava run --profile` 保留优化和按需诊断，`guava devtools` 可连接已有会话。直接启动框架示例时仍可用 `GUAVA_DEVTOOLS=1`。Gallery 的 `--performance-hud` 启用宿主通用 HUD；CPU 帧分解可用 `GUAVA_FPS_LOG=1`，其中呈现时间包含 acquire / submit / present 等待，不等于 GPU 执行时间。

跨平台应用从统一 CLI 开始（仓库中使用 `./guava`；安装后使用 `guava`）：

```sh
./guava create app /absolute/path/to/MyApp --id com.example.myapp --name 'My App'
./guava run /absolute/path/to/MyApp --mac
./guava run /absolute/path/to/MyApp --android --device DEVICE_SERIAL
./guava test /absolute/path/to/MyApp
```

业务模块 `AppContent` 导出普通函数 `makeApplicationContent() -> some View`，桌面和 Android 安装同一个根视图；应用 ID / 名称 / SDK 路径集中在 `guava.json`。桌面构建在对应主机运行；Android 需要 Swift 6.4.1 release 与匹配 SDK、NDK r30、JDK 21、CMake 和 Ninja。iOS / Web 尚无完整应用宿主。详见 [Guava CLI](../Tools/Guava/README.md)和 [Android 接入说明](../Platforms/Android/README.md)。

应用可以全局或局部设置 `Theme`，普通文字和输入默认继承 body；显式语义角色或任意值优先。`ThemeExtension`、`SemanticFontRef`、`SemanticColorRef`、`SemanticIconSize` 和 `ThemeMetric` 允许定义自己的设计系统，`IconTheme` 支持尺寸槽与资源替换。`ApplicationConfiguration.typography.scaler` 与屏幕 DPI 独立，主窗口和辅助窗口共用宿主偏好。[设计系统契约](../docs/components/design-system.md)说明完整 API、覆盖优先级与系统适配边界。

运行接入真实 SourceKit-LSP 的代码编辑器：

```sh
swift run --package-path Editor EditorApp --script-editor-demo
```

这个入口复用生产 `ScriptCodeEditor`、后台 Tree-sitter 和语言客户端，在临时项目中展示诊断、补全、hover，以及 200,000 行加载/中部编辑；退出后清理临时项目。Ctrl+Space 请求补全，F1 查看光标处文档，Escape 关闭浮层。画廊的 CodeEditor Story 展示组件状态与样例回复，真实语言服务联调使用这个 Editor 入口。[原生验证记录](../docs/guava-ui/code-editor-validation.md)包含连续输入、帧率、内存和 Instruments 的证据及限制。

TextField 绑定不可变 Rope `TextBuffer`，按职责配置。示例中的 `name` 是 `@State var name: TextBuffer = ""`；全文 `stringValue` 仅用于提交和文件读写边界：

```swift
TextField("Name", text: $name) { input in
    input.behavior.clearable = true
    input.behavior.maxLength = 40
    input.decoration.showWordLimit = true
    input.events.onSubmit = save
}
```

Tree 使用独立配置组，交互会话由组件管理：

```swift
Tree(nodes, children: \.children, configure: { options in
    options.selection.primary = $selectedID
    options.selection.expanded = $expandedIDs
    options.search.query = query
    options.search.text = { $0.name }
}) { node, selected, expanded, depth in
    Text(node.name)
}
```

大数据表格使用由应用持有的 `DataTableModel`，排序和 ID 索引不会在每次渲染中重建。列可以复用 `TableColumn`，并提供验证与提交规则；冻结列、行与列窗口化、多选和单元格编辑见 [DataTable 契约](../docs/components/data-table.md)。画廊可加载 200,000 行、33 列。

头像支持 Unicode 首字母、匿名图标、异步图片与头像组；加载和失败继续显示回退内容。通用 `AsyncImage` 提供显式阶段、取消和重试，旧缩略图接口复用同一加载器。[Avatar 契约](../docs/components/avatar.md)和[Image 契约](../docs/components/image.md)记录尺寸、裁切、资源限制及剩余差距。

macOS 彩色 emoji 接入共享文字排版和独立 RGBA 图集，支持普通文字、输入框、头像与游戏内 HUD。画廊的 `Theme / Typography` 与 `TextField` 有混排/透明度和 Unicode 编辑示例；其他平台彩色字形仍待接入。[文字渲染契约](../docs/components/typography.md)记录密度、缓存、传输与原生验证边界。

[组件覆盖与缺失清单](../docs/components/gaps.md)明确区分已有能力、基础实现与缺失组件，并给出缺失组件的验收规范。

验证：

```sh
swift run --package-path Tools/Developer guava-dev maintainability
swift test --package-path GuavaUI --no-parallel
swift test --package-path GuavaUI/Examples --no-parallel
swift test --package-path Editor
```

原生 UI 测试共享字体、输入等进程级环境；完整回归显式使用 `--no-parallel` 隔离各测试场景，保留全部测试和断言。`FontAtlas` 按同一线程拥有的模型使用。Portable 测试可继续按默认模式运行。

[Portable 核心](Portable/README.md)与[浏览器原型](Browser/README.md)可独立使用。浏览器原型尚未提供全部原生组件画廊。

跨设备布局和组件要求见 [组件标准](../docs/components/standard.md)，空间不足阶梯、手机/平板重排、触摸/键盘/辅助功能与动效实现见[跨平台控件规范](../docs/components/adaptive-spec.md)。`SurfaceReader` 读取空间与输入能力；应用内容不需要直接识别 UIKit、SDL 或 Android 生命周期。
