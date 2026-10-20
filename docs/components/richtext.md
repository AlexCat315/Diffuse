# RichText

`RichText` 把多段带样式的文字排成一个段落：粗体、斜体、行内代码、删除线与链接共享同一条基线，一起换行。它继承外层的文字样式（`.font`）、前景色与 `TextScaler`，只缩放一次。Markdown 文档由同一套段落组成，见 [Markdown](markdown.md)。

```swift
RichText([
    RichTextRun("Run "),
    RichTextRun("guava build", traits: .code),
    RichTextRun(" or read the "),
    RichTextRun("guide", link: "https://example.com/guide"),
    RichTextRun("."),
]) { destination in open(destination) }
```

| API | 说明 |
| --- | --- |
| `RichTextRun(text, traits:, link:)` | 一段文字；`traits` 为 `.bold` / `.italic` / `.code` / `.strikethrough` 的组合；`"\n"` 为硬换行 |
| `link` | 交给 `onOpenLink` 的目标字符串；相邻且目标相同的 run 视为同一个链接 |
| `alignment` | leading / center / trailing，按提供的宽度对齐每一行 |
| `onOpenLink` | 链接激活回调；组件不打开 URL，由调用方决定路由或外部打开 |

## 排版

- 每个 run 按自己的字体单独 shaping，再统一断行；行高取该行各 run 的最大行高，基线按最大 ascent/descent 居中。
- 断行点：空格之后；表意文字（CJK、假名、谚文、全角）之间，遵守常见禁则——`，。、；：？！）」』】…` 等不出现在行首，`（「『【` 等不出现在行尾；长 URL 在 `/`、`-` 之后可断。无断点时在字素边界强制断开。
- 行内代码使用主题 `mono` 与 `body` 的字号比例，左右各留约 0.32em 内边距，背景为前景色 8% 透明度的圆角 chip（两种主题都可见）。
- 斜体由 `Font.italic()` 选取字体的斜体字面（CoreText symbolic trait）；没有斜体字面的字体保持正体。
- 段落布局按（段落、宽度、字体图集）缓存。
- 双向文字先按逻辑顺序断行，再按行重排；`.leading` / `.trailing` 随段落的首个强方向字符解析，希伯来文/阿拉伯文段落与其中的英文、数字可混排。`BidiTests` 验证 Text 与 RichText 的视觉顺序及对齐；算法范围和显式方向控制、编辑选区的限制见 [双向段落](typography.md#双向段落)。

## 交互

- 链接始终带下划线（正文链接需在指针到达前可辨认）；悬停时变为 `accentHover`，指针变为手形，链接的每个折行片段都可点击；按下后移出链接再松开会取消。
- 指针在同一节点内移动时，事件分发器会重新解析光标，因此段落内的链接与普通文字可以显示不同光标。
- 每个链接有一个不可见的锚点节点，位于该链接第一行片段之上：可 Tab 聚焦（按段落内顺序），辅助功能角色为 link，名称为链接全文、help 为目标，激活动作与 Return/小键盘 Enter 都会调用 `onOpenLink`。键盘焦点可见时，链接的所有折行片段都绘制焦点环。指针输入穿过锚点交给段落，因此任意片段都可点击。
- 没有 `onOpenLink` 时链接仍按链接样式显示，但锚点不可聚焦、辅助功能状态为禁用、不注册按键。
- DevTools 可以按 `role: link` 查询到每个链接及其帧，`click` 或 `activate` 直接打开。

## 选择与复制

- 单独的 `RichText` 自带一个选区；`MarkdownView` 内所有段落、标题、列表项、代码块与表格单元格共享一个选区，拖动可以跨块。
- 指针：按下并拖动选择（指针被段落捕获，移到其他块或块之间的空白会吸附到阅读顺序上最近的位置）；Shift 点击扩展；双击选词（ICU 分词，CJK 可用）；三击选整段。段落被点击后获得焦点但不显示焦点环、也不是 Tab 停靠点（文本内的键盘目标是链接）。悬停文字显示 I 形光标，链接显示手形。
- 键盘：⌘/Ctrl+C 复制、⌘/Ctrl+A 全选、Escape 清除；没有选区时这些键交给窗口其他部分。
- 复制文本按阅读顺序拼接：同一行的块（表格单元格）用制表符，换行的块用换行符。
- 右键 / Control 点击打开 Copy（⌘C）与 Select All（⌘A）菜单；没有选区时先选中指针下的词。
- 触摸：拖动交给滚动；长按（≥0.45s、移动 <10pt）松开后选中该词并打开同一菜单。
- 选区高亮使用主题 `selection`，绘制在代码 chip 之上、文字之下；选中的换行在行尾显示一小段延伸。选区是挂载期间的视图状态，不进入任何持久化格式。
- 上述选区命中与几何仍按逻辑顺序近似处理；双向显示排版的实现不代表 RTL 选区已具备完整视觉顺序语义。

## 验收

`RichTextTests` 覆盖跨 run 空格断行与行宽约束、无约束宽度单行、CJK 禁则与 URL 断点、硬换行与空行高度、行内代码内边距、点与插入点/选区矩形映射、链接任意片段点击与取消、悬停光标，以及 `.font` 修饰符作用于测量与绘制。`TextSelectionTests` 覆盖跨块拖动与阅读顺序复制、焦点不可见、双击选词/三击选段/全选、无选区时按键透传、触摸长按选词与 CJK/标点分词。`RichTextLinkTests` 覆盖链接锚点的角色、名称、目标、位置、Return 与辅助功能激活、焦点记录与无处理器时的惰性链接。DevTools 在 Gallery `--component richText` 720pt 浅色与 390pt 深色触摸下截图确认粗体/斜体/粗斜体/代码 chip/删除线/链接下划线同基线排列、长 URL 在 `/` 后换行、中文按字断行；通过 `guava devtools input` 点击 “layout guide” 后 “Last opened” 变为 `guide://layout`。按 `role: link` 查询到三个链接；`click` 长 URL 与 `activate` 中文链接分别更新 “Last opened”；从 Reset example 按 Tab 聚焦 “layout guide” 出现焦点环、Return 打开；390pt 下再按 Tab，折成两行的 URL 两段都绘制焦点环（`capture --node --scale 2` 取样）。Markdown 页中从标题拖到正文第一段中部后 ⌘C，剪贴板为 “Release notes\nGuavaUI 0.10 … a”，截图显示两块高亮；右键 “swift-markdown” 选中 “markdown” 并弹出 Copy ⌘C / Select All ⌘A 菜单，点击 Copy 后剪贴板为 “markdown”。
