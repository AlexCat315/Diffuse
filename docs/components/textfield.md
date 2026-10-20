# TextField

`TextField` 绑定不可变 `TextBuffer`，普通输入和代码编辑共用光标、选区、输入法与撤销逻辑。存储、逻辑行索引与 UTF-8/UTF-16 转换由 Rope 负责；绘制只测量可见行及其邻近行。

```swift
@State private var query = TextBuffer.empty
@State private var source = TextBuffer("let answer = 42\n")

TextField("Search…", text: $query) { input in
    input.behavior.clearable = true
    input.events.onSubmit = { search(query.stringValue) }
}

TextField(text: $source) { input in
    input.layout.axis = .vertical
    input.layout.wrapsLines = false
    input.codeEditing.showsLineNumbers = true
    input.codeEditing.indentationWidth = 4
}.textFieldStyle(.editor).font(.monospaced(size: 15)).lineHeight(24)
    .frame(width: 640, height: 400)
```

## 编辑器外观

`TextField` 是多行文本与代码编辑的统一入口，不存在独立的 `CodeEditor` 类型。代码行号、缩进、诊断、补全和语法颜色是可选能力，由 `codeEditing` 配置开启；关闭后就是普通软换行文本编辑器。Gallery 的 **Text Editor** 页用同一个字段演示两种模式。

- 行号 gutter 默认透明，不画整块底色，也不画竖分隔线；行号与正文使用同一字体和 baseline，右对齐，正文与行号末端间距至少 24pt（大字号时不少于一 em）。至少预留三位数字，9→10→100 行时正文起点不跳动；更大文档按实际位数增长。需要底色或颜色时传 `codeEditing.lineNumberGutterColor` / `lineNumberColor`。
- 当前行使用贯穿编辑器宽度的低对比度中性色 band，当前行号同步提亮；不再画 accent 矩形描边。所有行和 band 使用同一个 `resolvedLineHeight`。
- 缩进参考线在前一级缩进列的空白处绘制，避免贴住代码首字形；tab 与 spaces 共用列宽。相邻行及内部空行合并为连续 0.5pt 中性细线，不再每行留上下断口；横向滚动与正文使用同一坐标，只保留可见深度。软换行的续行回到正文起点，不画穿过续行单词的引导线。只检查可见行及有界缩进前缀，避免大文档扫描。
- 括号匹配在光标所在或前一个字符上查找 pair，高亮两个括号；跳过字符串、行注释和块注释中的括号。匹配窗口限制在 caret 前后 64 KiB，避免大文档每帧扫描全文。
- 开启行号时垂直内边距至少 8pt，首行/末行不再贴住输入框边缘。
- 文档头（文件名、语言 badge、Code mode）和状态栏（Ln/Col、Spaces/Wrap、UTF-8）由调用方组合；字段本身只负责编辑表面。两者只用背景层级与留白区分，不画水平分隔线。
- 外层容器负责圆角和裁剪；`.textFieldStyle(.editor)` 使用统一 `surfaceSunken` 平面，去掉嵌套输入框边框。焦点由 caret、选区与代码当前行表达。该样式只负责表面，普通表单字段继续使用默认样式；字体与行距仍由调用方/主题声明，Gallery 和生产 ScriptCodeEditor 默认使用 15pt 等宽字体、24pt 行距。
- `codeEditing.syntaxColorAtUTF8Offset` 是唯一语法颜色入口。Gallery Text Editor 默认用轻量 Swift lexer 给关键字、类型、字符串、数字和注释着色；超过 30 万 UTF-8 字节的压力样例会关闭高亮，生产脚本编辑器仍走 Tree-sitter/LSP。

Gallery 的操作栏、文档头和状态信息会换行，控件采用带完整标签的 Checkbox；compact 代码预览软换行，宽屏代码保留横向浏览，普通文本一直软换行。代码/普通文本切换保留同一个输入节点、草稿与历史，不因展示模式重建编辑会话。

## 编辑器视觉与交互验收

参考 Zed 的同底色行号栏、低对比当前行、舒适字号/行距和克制语法配色，验收关注阅读层次而非复制窗口 chrome。`TextEditorAppearanceTests` 验证三位数范围内稳定的正文起点、行号与正文间距、明暗主题当前行、平面编辑样式及普通表单边框保持。`TextEditorLayoutTests` 覆盖 390/720/1280、100%/200%、明暗主题、触摸控件边界和实际键入后切换模式仍保留草稿；输入、长文档和 LSP UI 由既有测试继续覆盖。

`TextIndentGuidesTests` 覆盖嵌套块、内部空行连续性、滚动窗口的空行上下文、tab、水平可见深度及软换行不压文字。DevTools 另外把 `AudioEngine.swift` 前 55 行载入临时生产编辑器，检查明暗主题的间距及连续引导线；长行样例横移 40pt 后正文和引导线共同移动，行号保持固定。测试临时缓冲区不改实际源码文件。

macOS DevTools 镜像验收：Gallery 1280×820 指针、720×820 深色混合、390×820 触摸 200%；查询字段真实 `textField` 角色，切换到普通文本，输入并显式读取内容，检查换行、边距、状态栏和主题。生产 `EditorApp --script-editor-demo` 的 1280×720 窗口也通过 `input-ui` 替换内容、`query_ui_nodes` 显式读值、Cmd-Z 恢复，再切换明暗主题与定位首行；`capture-ui --settle-ms 400` 实际检查了平整底色、行号、语法颜色、当前行和 caret。所有操作都通过项目 DevTools 执行。

### 调整编辑区高度

`ResizableEditor`、`ResizableTextArea` 和内联 `JsonField` 共用独立的高度调节区：触摸/混合输入高 44pt，指针高 28pt，细小的居中 grip 不占用文本命中区域。`resizeLabel`（JSON 为 `JsonFieldLabels.resize`）由调用方本地化，辅助功能暴露命名 slider，数值为实际正文视口高度；支持 increment/decrement/setValue。

拖动下边缘调整高度，Escape 撤回本次拖动；键盘 Up/Down 减少/增加 16pt，Shift 或 Page Up/Down 为 64pt，Home/End 到达上下限，Tab 继续导航。指针聚焦不自动画键盘焦点框，键盘调节时显示焦点；高度变化后滚动容器会显露新的 grip 位置，普通滚轮仍可自由滚动。禁用、切换输入密度和卸载均释放拖动捕获；无效或过小的范围仍保证完整编辑区和命中区。

`ResizableEditor` 的高度参数包含调节区；`ResizableTextArea` 的参数表示正文高度。两者保留临时高度、文本节点及草稿，不把拖动状态写入文档。`EditorHeightTests` 覆盖 108 组尺寸/字号/输入/主题组合及实际输入、辅助动作、禁用清理和滚动显露。DevTools 在 390×820 触摸 200% JSON、720×820 深色混合 TextArea、1280×820 指针 TextEditor 中执行拖动、Escape、键盘和显式读值，再检查镜像的留白、边界及焦点。snippet tab-stop 与超长单行分段布局仍见下方边界。

## 存储与边界

- `TextBuffer(_:)` 从文件/程序化字符串建立 Rope；`.stringValue` 是完整文档序列化操作，应放在保存、解析 JSON 或提交 authored settings 的边界。
- `characterCount`、`utf8Length`、`utf16Length`、`lineCount` 来自缓存指标；行定位与三种坐标转换走树索引。
- `insert`、`delete`、`replace` 返回共享旧子树的新值。`TextBuffer` 的 `==` 比较修订根身份；`hasSameContents(as:)` 比较精确 UTF-8 内容，跳过共享子树，不需要先物化全文。
- 光标和选区使用 Swift `Character`；高亮/诊断使用 UTF-8 字节；LSP 使用 UTF-16 列。`parserPoint` 专门按 LF 字节计行，避免 CRLF 与 Tree-sitter 的坐标混淆。
- `TextEditHistory` 保存旧根、光标、选区，连续输入合并；撤销/重做不复制全文。历史属于编辑会话，不能作为 authored 文档序列化。

## 配置

| Group | 职责 |
| --- | --- |
| `layout` | 水平/垂直输入、软换行、理想宽度、测量时最大行数 |
| `behavior` | disabled、readonly、secure、clearable、最大字符数 |
| `decoration` | 控件密度、前后文字槽、计数器和语义颜色 |
| `codeEditing` | 行号、缩进、共享撤销历史、语法颜色、诊断与补全 |
| `navigation` | 一次性焦点/光标定位请求 |
| `events` | 输入、提交、取消、焦点、hover 与选区通知 |

字体、行高和字距继承主题或显式修饰器。选择区域、光标、输入法下划线和命中测试使用同一套字形 cluster 与行坐标。

## 输入行为

- 单击定位、拖动选择、双击选词；箭头、Shift 扩选；Cmd/Ctrl+A/C/V/X；Option 按词移动/删除。
- Home/End、Cmd+左右定位当前显示行，软换行末端保留在原行；Ctrl+Home/End、Cmd+上下定位文档首尾。Cmd+Backspace 删除到当前行首，在行首时合并上一行。Page Up/Down 按视口行数移动并保留期望列，Shift 可扩选。
- 单行 Return 提交；垂直输入 Return 换行，Cmd/Ctrl+Return 提交。Tab/Shift+Tab 可对所选逻辑行缩进/反缩进。
- IME 预编辑建立局部 Rope 预览，未提交内容不改变文档；候选窗跟随实际光标。
- 未换行输入在光标超出视口时横向滚动，行号 gutter 和前后装饰保持固定；文本、选区、诊断、补全锚点、IME 与指针命中共享滚动坐标。支持横向滚轮；单行输入也可使用纵向滚轮浏览长文本。
- readonly 保留复制、选区和滚动；disabled 停止交互并使用禁用样式；secure 对视觉与可访问性值都遮蔽内容。
- 可访问性全文值按系统请求延迟生成，正常逐帧更新不会序列化整篇文档。

## 代码能力

断点列、行级图标与折叠列使用统一的 [gutter 与折叠](editor-gutter.md) 契约。`codeEditing.gutter` 接收逐文档断点、标记动作和执行位置；`codeEditing.folding` 接收语言服务的逻辑行区间与可选折叠状态 binding。隐藏内容通过视觉行索引投影，源码、撤销和 LSP 坐标保持完整；生产编辑器已接入 Tree-sitter 区间和 LSP 诊断图标。调试运行时后端仍由应用提供。

`TextDiagnostics` 是不可变区间索引；`TextDiagnostic` 记录 UTF-8 范围、级别与消息。波浪线仅覆盖可见行，空范围也有指示。颜色跟随主题的 error/warning/accent/muted。

`codeEditing.onRequestCompletion` 收到 `TextCompletionRequest` 与主线程回复闭包。它在光标/输入停顿 300ms 后请求，也支持 Ctrl+Space；弹窗按前缀过滤，Up/Down 选择、Tab/Return 接受、Escape 关闭。替换范围和额外编辑作为单次撤销操作；旧缓冲区、失焦或销毁后的回复不会重新打开弹窗。

语法服务更新后应修改 `codeEditing.syntaxRevision`，使已经缓存的绘制立即刷新。Editor 的 Swift 高亮使用后台串行 Tree-sitter worker，合并待处理根并丢弃旧结果；首次解析完成前仍能输入和绘制。

`Tooltip(anchor: .point(...) / .range(...))` 可用于 LSP hover 或诊断消息。浮层脱离内容裁剪，沿窗口边界夹紧，并在下面空间不足时翻到锚点上方。

`codeEditing.onRequestHover` 在 F1 时收到当前可见光标的 `TextFieldHoverAnchor`，readonly 同样可查询。生产 `ScriptCodeEditor` 将它与指针 hover 接到真实 LSP；Escape、编辑、滚动、光标移动和失焦会关闭或取消旧 hover。

## 大文档与限制

20 万行的未换行代码编辑器按可见窗口测量，修改一行保留其他行缓存，undo 直接恢复旧根。软换行采用持久化视觉行索引；未访问行的高度暂按一行估计，测量后校正。

### 超长单行

未换行编辑器中超过 8 KiB 的逻辑行按约 4 KiB 一段塑形，段尾优先落在空格之后，段与段首尾相接；每段单独命中共享布局缓存，所以在压缩文件末尾编辑只重新塑形受影响的段。绘制时只保留水平视口两侧各一屏内的字形（行内 x 单调时用二分查找；双向行不裁剪），光标映射用二分查找替代原先逐 cluster 的线性扫描。`SnippetTests.longLine`/`culling` 覆盖 33,000 字符单行的单调字形、精确光标与裁剪窗口。

首次访问长行仍会塑形全部分段，绘制阶段再裁剪；尚未做到只塑形水平窗口。分段优先空格但不保证跨段连字与复杂脚本上下文，缓存命中也受段边界与容量影响，不能据此宣称任意长度单行的恒定编辑成本。

横向内容宽度来自已测量窗口和光标，不为寻找全篇最宽行而扫描文档；滚动条范围会随访问其他行调整。原生 200K 行连续输入 30 秒已验证，详细口径与采样见[验证记录](https://github.com/AlexCat315/GuavaStudio/blob/main/GuavaUI/Tests/GuavaUIComposeTests/CodeEditingUITests.swift)。

Tree-sitter 首次解析需要遍历文档，某些编辑也会使语法上下文扩大；后台 worker 保证这些工作不阻塞 UI。

### Snippet tab-stop

`TextCompletionItem.insertTextFormat = .snippet` 时按 LSP 片段语法展开 `insertText`：`$1`、`${1:占位}`（可嵌套）、`${1|a,b|}`（插入第一个选项）、`$0` 为最终光标，`\$`、`\}`、`\\` 转义，变量只保留默认值。接受后选中第一个 tab stop；Tab 前进、Shift+Tab 后退，到达 `$0`（缺省为插入末尾）时结束。当前 stop 内的编辑会伸缩该 stop 并平移后续 stop；在其外编辑、Escape 或离开最终 stop 会结束会话。同号 stop 只访问首次出现处，不做镜像同步。会话属于节点，不进入撤销或持久化。`SnippetTests` 覆盖解析、会话导航与真实补全接受。语言服务客户端可以据此声明 snippet 支持。

## 实现位置

- 存储：`TextBuffer.swift`、`RopeStorage.swift`、`RopeEditing.swift`、`RopeLookup.swift`、`RopeDifference.swift`
- 可见行布局：`TextDocumentLayout.swift`、`TextVisualLineIndex.swift`、`TextFieldLayoutEngine.swift`
- 输入会话：`TextFieldEditing.swift`、`TextFieldInputController.swift`、`TextEditHistory.swift`
- 诊断/补全：`TextDiagnostic.swift`、`CompletionPopover.swift`
- 主题样式：`DefaultTextFieldStyle.swift`、`TextFieldOptions.swift`

`TextBuffer` 的 `==` 比较修订根身份；`hasSameContents(as:)` 比较精确 UTF-8 内容并跳过共享子树。独立加载的相同文本可能需要 O(n)，因此在编辑/保存边界计算并缓存结果，不在每帧调用。Script 工作区缓存 dirty 标志，输入后删除回原文也会恢复 clean，不依赖根身份恰好相同。

## 响应式与输入密度

TextField 的 style host 和实际输入 surface 在 touch 下共同保留至少 44pt 命中宽高；controlSize 的视觉与 authored minima 保留，切回 pointer 恢复对应密度。touch-only surface 不触发指针 hover 查询或 hover scrollbar chrome；键盘 F1 查询仍可用。
