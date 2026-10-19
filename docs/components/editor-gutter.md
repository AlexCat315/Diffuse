# 编辑器 gutter 与折叠

统一 `TextField` 的 `codeEditing.gutter` 与 `codeEditing.folding` 提供断点、行级操作和源码折叠。Gallery 的 Text Editor 和生产 `ScriptCodeEditor` 使用同一套布局、输入及可访问性实现。

## 视觉和输入

指针模式从左到右依次为断点列、语义图标列、右对齐行号、折叠箭头和正文。断点/图标列各 24pt，折叠列 20pt；行号末端到正文至少 36pt，包含折叠列及留白。无对应能力时不占该列，三位数字范围内正文起点稳定。gutter 与正文同底色，无整块彩色侧栏或竖向分隔线；断点使用红色实心/空心圆，停用态使用中性色空心圆。折叠箭头保留低对比度，收起后在标题末尾显示 `⋯ 行数`，隐藏断点以小圆点提示，全部停用时使用中性色。

触摸及混合输入改为每行一个 44pt 操作入口，避免相邻小图标误触；行高至少 44pt。菜单包含完整名称、断点启停、行级操作和展开/折叠。指针右键断点列也能启停断点。缩放后的字体、行号和目标位置来自同一布局度量；横向滚动只移动正文和行内摘要，gutter 固定。

源码获得焦点时，F9 添加/删除当前行断点，Shift+F9 启停已有断点。Primary+Alt+Left/Right 收起/展开当前最内层代码块。Tab 从源码进入 gutter 的单一停靠点，方向键/Home/End 在可见操作间移动，下一次 Tab 离开 gutter，Escape 返回源码。gutter 操作恢复源码焦点时取消自动补全，不因操作断点而打开光标原位置的补全菜单；后续键入仍正常请求补全。操作拥有完整名称、断点状态及展开状态，可通过辅助功能动作调用。标签函数由调用方本地化，不拼装固定英文词序。

## 配置与状态

所有行号均为 **从 0 开始的逻辑源码行**，不受软换行或折叠影响。标记的稳定 ID、完整名称、图标和 action 由调用方提供；同一行多个标记进入菜单。

```swift
@State private var source = TextBuffer("struct Example {\n    let value = 42\n}\n")
@State private var annotations = TextEditorAnnotations()

TextField(text: $source) { input in
    input.layout.axis = .vertical
    input.codeEditing.showsLineNumbers = true
    input.codeEditing.gutter.breakpoints = Binding(
        get: { annotations.breakpoints }, set: { annotations.breakpoints = $0 })
    input.codeEditing.gutter.onBreakpointsChange = { debugger.setBreakpoints($0) }
    input.codeEditing.folding.regions = [TextFoldRegion(lines: 0...2)]
    input.codeEditing.folding.collapsedLines = Binding(
        get: { annotations.collapsedLines }, set: { annotations.collapsedLines = $0 })
}.textFieldStyle(.editor).font(.monospaced(size: 15)).lineHeight(24)
```

`debugger` 为应用自身的集成示意，并非 GuavaUI 内置服务。`TextBreakpoint.State` 表示 enabled/disabled/unverified，`gutter.executionLine` 接收调试器的暂停位置并绘制箭头和低强度整行提示。组件不会因点击断点而假装运行调试器。当前生产脚本编辑器已接入逐文档断点会话，但尚无脚本调试协议/运行时断点后端；启用的断点明确显示为 unverified 空心态，不能宣称已绑定运行时。Gallery 的运行及暂停按钮明确用于 UI 预览。

`TextEditorAnnotations` 是临时文档会话值，不序列化到源码、项目配置或撤销快照。生产 `ScriptWorkspaceModel` 在文档间保留它，修改 annotations 不产生 dirty。源码变化时，模型通过 `rebase(from:to:)` 将行锚点随编辑迁移；在行首插入新行采用向右亲和，锚点跟随原行下移，删除的行清除锚点，相同内容重新加载保留状态。字段也支持直接绑定独立断点/折叠状态并自动迁移，已由文档模型迁移的值不会再迁移一次。

## 折叠是文档投影

折叠不删除或复制隐藏源码。`TextVisualLineIndex` 在持久化行树中将隐藏逻辑行设为零个视觉行，`TextDocumentLayout` 直接跳过这些区间；光标、命中、选择、滚动和 IME 继续使用原始 Rope 的 Character/UTF-8 坐标。嵌套区间保留子折叠状态，交叉或越界区间被忽略。

收起含光标的区间将光标移到标题末端；上下移动跳过隐藏行。外部定位到隐藏行时展开祖先区间。全选/复制仍包含完整源码；紧邻隐藏边界的 Backspace/Delete 先展开，下一次按键才执行删除，避免无提示修改不可见代码。IME 预编辑期间临时显示全文投影并隐藏 gutter 操作，提交后恢复有效折叠。

语言服务提供区间，组件不解析语言。生产编辑器在后台 Tree-sitter worker 中提取 Swift 类型体、函数体、闭包、控制流、计算属性、集合及多行字符串/注释区间，排除字符串及注释中的伪括号；诊断图标来自真实 LSP 数据，点击定位到对应源码。异步解析期间使用 `folding.isReady = false` 保留会话中的折叠头，结果完成后再清理失效区间。Gallery 的小型 Swift 示例使用 lexer 排除字符串/行注释后配对括号，压力样例停用这个示例解析器。

可见操作是独立语义节点，与测量文本的 Yoga 叶节点互为兄弟；不能把按钮塞进 measured leaf。单行表单保持原有轻量层级。禁用、切换普通文本、secure 和卸载后旧操作不能修改状态。

## 验证

`GutterTests` 覆盖三档宽度、100%/200%、明暗主题和三类输入，验证断点/标记真实 action、嵌套折叠、导航、行锚点迁移、撤销、复制、异步解析、焦点和生命周期。20 万行折叠压力用例仅测量标题与尾行，展开恢复原逻辑行数。`TreeSitterHighlighterTests` 使用真实 AST 验证区间；`ScriptWorkspaceExternalChangeTests` 验证文档会话不污染源码或 dirty。普通输入、编辑器布局和 Inspector 搜索回归同时运行。

2026-10-19 的定向回归：92 项 GuavaUI 组件测试、20 项 Editor 测试、30 项 Gallery 回归和 5 项 DevTools 输入测试通过；最后一次组件修改后重新运行对应组件及生产集成测试。维护性和模块边界检查通过。Inspector/Workbench 的 UI 测试在主线程执行，与实际宿主及其余工作台 UI 测试一致；新增代码配置采用写时复制，验证副本修改不会污染原值。

macOS 原生 DevTools 闭环通过 `query_ui_nodes` 定位真实语义节点、`input-ui` 投递输入、`capture-ui --settle-ms 400` 检查实际镜像：

| 表面 | 实际验证 |
| --- | --- |
| 1280×820，指针，100%，浅色 | 添加断点、右键停用、F9/Shift+F9、折叠和行内隐藏断点提示；折叠前后 99 字节示例源码精确相同 |
| 390×820，触摸，200%，浅色 | 滚动显露编辑器，打开 44×48pt 行入口，经完整名称菜单折叠代码；大字号菜单在窗口内 |
| 720×820，混合输入，200%，深色 | 行菜单包含断点启停、运行预览与折叠，52pt 菜单行可点击；检查深色层次、图标和文本边界 |
| 1280×720，生产 ScriptCodeEditor，深色 | 真实 SourceKit-LSP ready，添加断点并折叠 AST 区间，214 字节源码精确相同；点击诊断图标定位到 Ln 8, Col 18 |
| 1280×820，长行 | 正文横移 120pt 后书签控件仍在同一 24×24pt 矩形，行号/折叠列固定 |

DevTools 输入客户端补齐了指针按钮名称归一化及明确校验错误，右键验证可使用 `button: "right"`。输入应答仅代表投递；随后等待绘制并查询状态/显式读值，避免把异步重组前的旧节点当作结果。全部操作使用项目自身接口；桌面触摸密度预览不等于真实设备或系统读屏验收。

设备原生调试协议、真实脚本暂停/步进、远程断点校验不是该 UI 组件已经实现的能力。snippet tab-stop 和超长单行分段布局仍在 [缺口清单](gaps.md)。
