# Markdown

`MarkdownView` 把 CommonMark（含 GitHub 扩展：表格、删除线、任务列表）渲染为原生 GuavaUI 视图。解析使用 [swift-markdown](https://github.com/swiftlang/swift-markdown)（Apple 维护的 cmark-gfm 封装），以 `private import Markdown` 引入：AST 只在 `Parse.swift` 内转换为内部块模型，不进入 GuavaUICompose 的公开 API。段落与行内样式由 [RichText](richtext.md) 排版。

```swift
ScrollView {
    MarkdownView(release.notes) { destination in router.open(destination) }
        .padding(16)
}
```

| API | 说明 |
| --- | --- |
| `MarkdownView(source, onOpenLink:)` | 渲染一个 Markdown 字符串；相同源文本复用解析结果 |
| `onOpenLink` | 链接与图片目标的激活回调；组件不自行打开 URL |
| `MarkdownEditor(text:sourceTitle:previewTitle:onOpenLink:)` | 绑定 `TextBuffer` 的源码编辑与实时预览；标题由调用方本地化，并用于页签和辅助功能命名 |

视图继承外层文字样式与宽度、按内容增高；长文档放进 `ScrollView`。整个文档共享一个文本选区：拖动可跨标题、段落、列表、代码与表格，⌘/Ctrl+C 复制、右键菜单 Copy / Select All，触摸长按选词，细节见 [RichText 选择与复制](richtext.md#选择与复制)。

## 编辑

```swift
@State private var draft: TextBuffer = "# Notes\n\nStart writing."

MarkdownEditor(text: $draft, sourceTitle: L("Source"), previewTitle: L("Preview")) {
    destination in router.open(destination)
}
.frame(height: 480)
```

`MarkdownEditor` 复用统一 `TextField` 的多行编辑、软换行、2 空格缩进、IME、选区、撤销/重做和剪贴板；源码使用随字号缩放的 15pt 等宽字、24pt 行高。预览沿用 `MarkdownView` 的原生渲染与链接回调。调用方提供有界高度，源码与预览各自滚动。

按**实际分配宽度**选择形态，与窗口宽度独立：≥600pt 为可拖动左右分栏，两侧最小 240pt；<600pt 为源码/预览页签。页签与尺寸切换保留节点、草稿、撤销历史、分栏比例及滚动位置；隐藏面板不接收输入与辅助功能焦点。页签支持键盘与 ≥44pt 触摸目标，RTL 镜像分栏。完整源码只在 `TextBuffer` 修订变化时转为字符串，焦点、主题、分栏与滚动更新复用字符串及解析结果。解析与渲染仍是整篇文档，不宣称任意大 Markdown 文件的恒定预览成本。

文件打开、保存、dirty 与外部修改冲突属于通用文档层；Markdown 编辑器不按扩展名单独实现文件流程。生产 Editor 的 Documents 面板沿用 `DocumentWorkspace` / `EditorDocumentWorkspace`，`.md` / `.markdown` 使用 `MarkdownEditor`，`.txt`、`.swift`、`.java` 等继续使用统一 `TextField`。切换或外部重新加载文档时重置编辑会话；保存刷新保留草稿和撤销历史。Gallery 的 Edit and preview 只演示组件组合。

## 块

| 块 | 呈现 |
| --- | --- |
| 段落 | RichText：粗体、斜体、行内代码 chip、删除线、下划线链接；软换行合并为空格，硬换行（行尾两空格或 `\`）保留 |
| 标题 1–6 | 主题 `title` → 中间字号 → `headline` → 正文粗体；1、2 级下方有分隔线；辅助功能角色为 heading 并带级别 |
| 引用 | 前缘 3pt `borderStrong` 竖线，内容用 `onSurfaceMuted`，可嵌套任意块 |
| 列表 | 有序列表从 `start` 起编号、编号右对齐在按最宽编号计算的槽内；无序列表按嵌套深度交替绘制实心点 / 圆环 / 方块；任务项为只读复选框（勾选为强调色实底 + 对勾），辅助功能为 checkbox + 只读 |
| 代码块 | `surfaceSunken` 圆角卡片：头部显示语言与复制按钮（复制后 1.6 秒内显示对勾与 “Copied”），正文为等宽、不换行，宽于容器时横向滚动 |
| 表格 | 列宽取该列最宽单元格并限制在 56–320pt，超出时单元格换行；表头加粗并着 `surfaceVariant`，行间分隔线，列对齐遵循 `:---:` / `---:`；整表宽于容器时横向滚动；RTL 下列顺序镜像 |
| 分隔线 | Divider |
| HTML 块 | 作为 `html` 代码块原样显示（不执行） |
| 图片 | 显示为斜体替代文字并链接到图片地址 |

间距：块之间 12pt，标题前额外 8pt；列表项与项内块之间 6pt。

## 手机 / 平板 / 桌面

- 正文、标题、引用、列表随容器宽度换行，CJK 按字断行；字号随 `TextScaler` 缩放一次。
- 段落继承 RichText 的行级双向排版，RTL 段落按自身方向对齐；文档壳层的 RTL 布局与段落方向分别解析。显式嵌入/隔离控制与双向选区仍有限制，见 [Typography](typography.md#双向段落)。
- 代码块与表格不压缩内容，在窄宽下横向滚动；触摸面上滚动条自动隐藏。
- 复制按钮沿用 Button 的 44pt 触摸命中。

## 验收

`MarkdownEditorTests` 覆盖 240/390/720/1280pt 实际容器、100%/200% 字号、触摸/混合/指针、明暗主题与 RTL，以及真实输入后的标题预览、链接激活、页签保留、撤销、程序化替换和空文档。

`MarkdownParsingTests` 覆盖行内样式合并、软/硬换行、标题/引用/嵌套与任务列表/代码/分隔线/表格对齐的块结构与解析缓存；`MarkdownRenderingTests` 覆盖标题角色与字号、长代码行保持单行并提供滚动区域、段落按容器宽度换行、任务复选框只读语义、表格列宽与行对齐。

DevTools 在 Gallery `--component markdown` 中验证：720pt 浅色与 390pt 深色下标题分隔线、编号与圆点/圆环/方块标记、任务复选框、引用竖线、代码块头部、表格对齐（居中、右对齐）与中文粗体（PingFang Semibold）；`guava devtools click` 点击屏幕外的 “Copy code” 时先自动滚动到可见再点击，剪贴板得到代码原文，按钮切换为对勾。
