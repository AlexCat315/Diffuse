# GuavaUI 浏览器 Wasm 原型

浏览器和桌面现在运行同一份 `SharedCounterView` Compose 源码，以及真实的
ViewGraph、节点树、Yoga 布局、输入分发、State/Binding 和 DrawList。
FreeType/HarfBuzz 字体管线也已共用，浏览器文字绘制为真实的图集字形四边形。
Inspector 读取真实节点和失效记录，支持状态检查点、状态差异、输入录制和回放。

## 构建与运行

使用 Swift 6.4.0，以及**版本完全匹配**的官方 Wasm SDK：

macOS 的 Xcode Swift 编译器即使也标记为 6.4，仍可能与官方 SDK 的预编译模块
不兼容。此时应使用同版本的 swift.org 发布工具链，并把它的 `usr/bin` 放在
当前构建命令的 `PATH` 最前；无需更改系统默认工具链。

```bash
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d
git submodule update --init GuavaUI/third-party/freetype GuavaUI/third-party/harfbuzz

cd GuavaUI/Browser
npm ci
npm run build
npm run serve
```

打开 <http://127.0.0.1:8080>。在 macOS/Linux 主机编译；`dist/` 包含浏览器运行
依赖，无需运行时 CDN。主机还需 CMake、Ninja、Python 3，以及 Swift 工具链里的
clang/clang++/llvm-ar。`build_fonts.py` 增量构建现有子模块，不修改上游源码。
Yoga/HarfBuzz 禁用 C++ 异常；FreeType 字体校验使用 SDK 的 `libsetjmp` 和 Wasm
异常处理指令，因此浏览器需支持 Wasm exception handling。原生编译设置不受影响。

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
| `GuavaUIText` | FreeType FontAtlas、HarfBuzz TextShaper、FontCollection 字素回退 |
| `GuavaUIScene` | Node/RenderTree、Yoga、Recomposer、动画、焦点、捕获和事件分发 |
| `GuavaUIComposeCore` | View/ViewBuilder、ViewGraph、CompositionLocal、Box/Row/Column |
| `GuavaUIDevToolsScene` | 从实际节点树生成 Inspector 快照 |
| `GuavaUIDevToolsProtocol` | 消息结构、会话校验、订阅、状态差异、输入录制格式 |

桌面 Runtime/Compose/DevTools 继续导出这些类型。浏览器不编译 SDL、SwiftNIO
socket、引擎视口或 GPU 原生依赖。完整的主题控件库仍在桌面 Compose 模块中。

浏览器字体从 `dist/fonts/` 加载到 Swift 拥有的内存，按字素选择完整覆盖的字体，再按
字体/脚本分段交给 HarfBuzz。中文、阿拉伯文连写、天城文重排和单色 Emoji 均走这条
管线。字体与许可证见 [Text/Fonts](../Text/Fonts/README.md)，约 21 MiB。
字体加载失败会明确显示错误；未覆盖字符显示主字体的缺字形。

R8 图集缓存按字体、字号和像素比例区分，只导出脏矩形。WebGPU 上传到真实的
2048×2048 字体纹理，Canvas2D 则裁剪、着色同一图集；不调用 Canvas `fillText`。
图集满时重置并重绘整帧。快照的 `atlasFull` 表示单帧仍超出容量，届时需要更大图集
或分页。Canvas2D 三角形颜色插值仍不完全等同于 GPU 光栅化。

目前支持脚本分段的自动方向，但没有完整的 Unicode 段落双向算法；混合 LTR/RTL
段落仍需 bidi/itemization。彩色 Emoji、完整文本选择/编辑与跨平台字体发现尚未移植。

## 输入与调试

鼠标按下/释放、拖出取消、指针捕获、Tab 焦点和 Enter/Space 按钮操作都通过真实的
EventDispatcher。文字输入示例支持追加 Unicode 文本、按字素 Backspace、粘贴和
IME 预编辑/提交；它是一个简单的末尾编辑示例，尚未移植桌面完整 TextField 的选择、
光标导航和撤销。隐藏的 DOM 输入桥为浏览器 IME 提供焦点与候选窗口位置。

现有 Inspector 通过同源 `MessageChannel` 连接 `browser://guava`，无需浏览器监听
TCP。桌面 Inspector 连接 `ws://127.0.0.1:9229/`。两者使用同一套消息校验。

- **Pick component**：开启后点击实际画面，选择文字、容器或控件；拾取点击不会触发
  应用按钮，Esc 取消。面包屑可选择父容器。布局面板显示 margin/border/padding、
  内容尺寸和 Flex 参数，修改四边 padding、背景色、前景色后立即重排重绘。
- **Undo / Redo / Clear selected / Clear all**：撤销、重做和清除临时样式覆盖；
  每个颜色和 padding 也可单独 Reset。重组保留覆盖，清除恢复应用最新样式；
  断开连接或开发重载会丢弃覆盖和历史。这些修改保存在内存中。
  协议、坐标和限制见 [场景编辑协议](../DevTools/protocol-inspection.md)。

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

控制台 `guavaDebug.snapshot` 查看当前帧与字形/UTF-8 cluster/字体 ID，
`guavaDebug.gpuInfo` 查看适配器，`guavaDebug.request(...)` 发送调试请求。
C ABI 缓冲区仅在下一次对应更新前有效，JavaScript 会先复制再调用其他 Wasm 导出。
Swift 源码断点需要支持 Swift 的 DWARF 调试扩展和源码映射；此处未提供完整 Swift
调试器，可参考 [Swift Wasm 调试说明](https://book.swiftwasm.org/getting-started/debugging.html)。

Inspector 的 **Source & recomposition** 现在记录 ViewBuilder 表达式的 Swift 文件、
行列号，支持 **Open source** 跳转 VS Code/Cursor；远端构建可在 **Editor path mapping**
配置构建路径和本地路径前缀。它显示所属用户组件的真实重组次数、最近/平均/累计/最大耗时，
以及 State 属性名、可观察字段、父组件和 CompositionLocal 更新原因。
**All components** 支持排序、选择组件和 **Reset statistics**；首次挂载单列，临时样式编辑
与布局变化不计为 body 重组。耗时包含子组件协调，不包含 Yoga/GPU，不应把父子行相加。
显式 `return` 或具体 Body 类型可能不自动捕获，使用 `.sourceLocation()` 补充准确位置。
详见 [源码与重组说明](../DevTools/README.md#source-location-and-component-recomposition)。

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
swift test --package-path GuavaUI/Text # 先构建原生字体依赖，见 ../Text/README.md
swift build --package-path GuavaUI/Portable
cd GuavaUI/Browser
python3 -m pip install -r requirements-dev.txt
python3 -m playwright install chromium
npm run build
npm run verify
npm run verify:dev
```

浏览器脚本在 1×/2× 比例检查实际图集文字和几何像素、输入、真实节点、失效追踪、状态差异、录制回放、
Inspector 重连、缩放和原生 WebSocket。文字检查包含中文/Emoji 与合成的浏览器 IME
事件，以及 Latin 连字、阿拉伯文、天城文和字体回退；真实操作系统输入法仍需人工验收。
新增验收覆盖实际画面拾取、非交互文字、布局移动与修改后的真实颜色像素、重组保留、
撤销/重做、清除及断开恢复，也通过真实原生 WebSocket 验证同一套编辑面板。
分析验收覆盖准确 Swift 表达式行号、编辑器链接、Unicode/Windows 远端路径映射、
真实 State 重组次数/原因/耗时和统计重置；原生 WebSocket 使用真实 Compose scope 验证。
状态观察验收覆盖仅暴露 count/dark、真实 State 更新、重组/布局/绘制时间线、
组件定位、trace 导出、停止录制和断开/重连清理。像素检查使用浏览器实际呈现的
截图，避免 WebGPU 在呈现后复制画布时读到已失效的纹理。
开发脚本验证真实 Swift 编译、错误恢复与状态保留，
会临时修改宿主源码并在退出时还原。

`python3 verify.py --require-webgpu` 强制 WebGPU 像素验收；
`--require-hardware-gpu` 还拒绝软件适配器，严格模式不会强制 SwiftShader。
`--skip-native` 只验证浏览器，`--screenshot` 在严格模式保存 WebGPU 画面。
`--dist .build/release-preview` 可对指定 release 构建目录执行相同验收。
`GUAVA_CHROMIUM` 指定 Chromium 路径，`GUAVA_CHROMIUM_ARGS` 是附加启动参数的 JSON 数组。
CI 覆盖共享字体、Linux/Windows Portable 和浏览器流程，并上传构建产物。

仓库还提供手动触发的 `GuavaUI hardware WebGPU acceptance` 工作流。配置带
`self-hosted, linux, x64, guava-webgpu` 标签、可用物理 GPU/驱动、Chromium 系统依赖及
CMake/Ninja/Python/Node 的 runner 后，从 Actions 手动运行，它会严格检查适配器和
文字/几何像素，保存日志与 WebGPU 截图。

此前 Linux/Swift 6.4.0 的完整桌面测试集、7 项字体集成测试、Portable、1×/2× 图集像素
和真实 WebSocket 检查通过。该云容器没有 `/dev/dri`，物理 GPU 预检得到 `vendor=google`、
`architecture=swiftshader`、`isFallbackAdapter=true`、`lost=true`，严格硬件验收按预期拒绝
该环境。macOS 上已通过 Canvas2D 1× 与 WebGPU/SwiftShader 2× 的实际呈现像素和
状态观察/时间线验收，debug/release Wasm 均运行同一套检查；
**物理 GPU 的严格验收仍待可用桌面环境完成**。
开发重载与 debug/release Wasm 构建也已验证通过。

The shared Inspector also supports explicitly exposed State summaries and an
opt-in CPU timeline. `count` and `dark` are exposed by the shared demo; the note
text remains private from observation. Compose/commit, layout and text/draw-list
spans share one monotonic clock. Timeline export measures CPU generation, while
WebGPU submission remains owned by JavaScript.

`python3 verify.py --native-only` validates the real native WebSocket host and
Inspector without building Wasm or requiring a GPU. Install Playwright/Chromium
and build `GuavaUIDevToolsProbe` first. Full `verify.py` additionally exercises the
Wasm renderer and input pipeline.

For a live macOS GPU/mirror check, run `GUAVA_DEVTOOLS=1 swift run --package-path
GuavaUI GuavaUIDemo --shared-counter` from the repository root, then
`python3 GuavaUI/Browser/verify_native_demo.py`. This checks live State values,
actual padding-driven Yoga layout, CPU timeline spans, Metal mirror pixels and
remote pointer input. The app remains running after the check.
The check restores the original checkpoint. Add `--require-presented` to require
primary swapchain submission; unlock the Mac and show the native window first.
