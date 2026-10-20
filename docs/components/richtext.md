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

## 交互

- 链接始终带下划线（正文链接需在指针到达前可辨认）；悬停时变为 `accentHover`，指针变为手形，链接的每个折行片段都可点击；按下后移出链接再松开会取消。
- 指针在同一节点内移动时，事件分发器会重新解析光标，因此段落内的链接与普通文字可以显示不同光标。

## 验收

`RichTextTests` 覆盖跨 run 空格断行与行宽约束、无约束宽度单行、CJK 禁则与 URL 断点、硬换行与空行高度、行内代码内边距、点与插入点/选区矩形映射、链接任意片段点击与取消、悬停光标，以及 `.font` 修饰符作用于测量与绘制。DevTools 在 Gallery `--component richText` 720pt 浅色与 390pt 深色触摸下截图确认粗体/斜体/粗斜体/代码 chip/删除线/链接下划线同基线排列、长 URL 在 `/` 后换行、中文按字断行；通过 `guava devtools input` 点击 “layout guide” 后 “Last opened” 变为 `guide://layout`。
