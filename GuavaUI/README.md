# GuavaUI

GuavaUI 是 Guava Engine 的 Swift 声明式界面库。组件、平台运行时和可序列化工作区分别位于 Compose、Runtime 和 Workspace 模块。

运行组件画廊：

```sh
swift run --package-path GuavaUI GuavaUIDemo
swift run --package-path GuavaUI GuavaUIDemo --component textField
swift run --package-path GuavaUI GuavaUIDemo --component workspace
swift run --package-path GuavaUI GuavaUIDemo --component dataTable
```

画廊默认打开由真实组件组成的 Dashboard，提供 72 个 Story、搜索、尺寸切换、100–200% 文字缩放、禁用示例、明暗主题和独立重置。Theme 页可现场修改字体族、body 字号、图标和圆角，并操作局部主题下的输入框与按钮。示例代码在 `Sources/GuavaUIGallery/`，宿主代码在 `Sources/GuavaUIDemo/`。Story 数量不是独立组件数量。

Android 使用方可通过脚手架创建独立 Swift Package，在 `ApplicationContent.makeRoot() -> some View` 返回自己的根视图；Android 宿主负责 Vulkan、文本、触摸、IME 和生命周期。创建及构建入口：

```sh
swift run --package-path Android/Tools GuavaAndroid create --directory /absolute/path/to/MyApp --application-id com.example.myapp --name 'My App'
swift /absolute/path/to/MyApp/android.swift --install --serial DEVICE_SERIAL
```

创建、构建与安装均由 Swift 工具完成，无需 Python。运行前需要 Swift 6.4.0 release 及匹配的 Android SDK / NDK、JDK、CMake 和 Ninja，详见 [Android 接入说明](../Android/README.md#使用自己的-guavaui-根视图)。[GuavaUIStarter](../examples/GuavaUIStarter/README.md) 提供同一模板的可编辑项目。新的 Swift 工具和使用方入口本轮尚未编译 / 真机验收。

应用可以全局或局部设置 `Theme`，普通文字和输入默认继承 body；显式语义角色或任意值优先。`ThemeExtension`、`SemanticFontRef`、`SemanticColorRef`、`SemanticIconSize` 和 `ThemeMetric` 允许定义自己的设计系统，`IconTheme` 支持尺寸槽与资源替换。`AppConfig.textScaler` 与屏幕 DPI 独立，主窗口和辅助窗口共用宿主偏好。[设计系统契约](../docs/components/design-system.md)说明完整 API、覆盖优先级与系统适配边界。

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

[与 GPUI Kit 的逐项审计及缺失清单](../docs/guava-ui/gpui-kit-audit.md)明确区分已有能力、基础实现与缺失组件。

验证：

```sh
python3 scripts/check-swift-maintainability.py
swift test --package-path GuavaUI
swift test --package-path Editor
```

[Portable 核心](Portable/README.md)与[浏览器原型](Browser/README.md)可独立使用。浏览器原型尚未提供全部原生组件画廊。
