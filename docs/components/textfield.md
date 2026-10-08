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
}.font(.mono).frame(width: 640, height: 400)
```

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

`TextDiagnostics` 是不可变区间索引；`TextDiagnostic` 记录 UTF-8 范围、级别与消息。波浪线仅覆盖可见行，空范围也有指示。颜色跟随主题的 error/warning/accent/muted。

`codeEditing.onRequestCompletion` 收到 `TextCompletionRequest` 与主线程回复闭包。它在光标/输入停顿 300ms 后请求，也支持 Ctrl+Space；弹窗按前缀过滤，Up/Down 选择、Tab/Return 接受、Escape 关闭。替换范围和额外编辑作为单次撤销操作；旧缓冲区、失焦或销毁后的回复不会重新打开弹窗。

语法服务更新后应修改 `codeEditing.syntaxRevision`，使已经缓存的绘制立即刷新。Editor 的 Swift 高亮使用后台串行 Tree-sitter worker，合并待处理根并丢弃旧结果；首次解析完成前仍能输入和绘制。

`Tooltip(anchor: .point(...) / .range(...))` 可用于 LSP hover 或诊断消息。浮层脱离内容裁剪，沿窗口边界夹紧，并在下面空间不足时翻到锚点上方。

`codeEditing.onRequestHover` 在 F1 时收到当前可见光标的 `TextFieldHoverAnchor`，readonly 同样可查询。生产 `ScriptCodeEditor` 将它与指针 hover 接到真实 LSP；Escape、编辑、滚动、光标移动和失焦会关闭或取消旧 hover。

## 大文档与限制

20 万行的未换行代码编辑器按可见窗口测量，修改一行保留其他行缓存，undo 直接恢复旧根。软换行采用持久化视觉行索引；未访问行的高度暂按一行估计，测量后校正。特别长的单一逻辑行仍会完整测量该行，尚未实现水平字形分段布局。

横向内容宽度来自已测量窗口和光标，不为寻找全篇最宽行而扫描文档；滚动条范围会随访问其他行调整。原生 200K 行连续输入 30 秒已验证，详细口径与采样见[验证记录](../guava-ui/code-editor-validation.md)。

Tree-sitter 首次解析需要遍历文档，某些编辑也会使语法上下文扩大；后台 worker 保证这些工作不阻塞 UI。当前 completion 使用普通插入文本，未向服务器声明 snippet tab-stop 导航支持。

## 实现位置

- 存储：`TextBuffer.swift`、`RopeStorage.swift`、`RopeEditing.swift`、`RopeLookup.swift`、`RopeDifference.swift`
- 可见行布局：`TextDocumentLayout.swift`、`TextVisualLineIndex.swift`、`TextFieldLayoutEngine.swift`
- 输入会话：`TextFieldEditing.swift`、`TextFieldInputController.swift`、`TextEditHistory.swift`
- 诊断/补全：`TextDiagnostic.swift`、`CompletionPopover.swift`
- 主题样式：`DefaultTextFieldStyle.swift`、`TextFieldOptions.swift`

`TextBuffer` 的 `==` 比较修订根身份；`hasSameContents(as:)` 比较精确 UTF-8 内容并跳过共享子树。独立加载的相同文本可能需要 O(n)，因此在编辑/保存边界计算并缓存结果，不在每帧调用。Script 工作区缓存 dirty 标志，输入后删除回原文也会恢复 clean，不依赖根身份恰好相同。
