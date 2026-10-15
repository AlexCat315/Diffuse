# 应用设计系统与缩放契约

GuavaUI 的默认外观是一套可替换的预设。应用决定字号、字体族、图标、间距、圆角、颜色和动效；框架负责在组件、布局、编辑与浮层之间传递这些设置。数值均为逻辑点，DPI 栅格密度独立处理。

## 全局与局部主题

```swift
var theme = Theme.defaultLight
theme.typography.family = "Helvetica Neue" // nil 使用 ApplicationConfiguration.typography.primaryFontName
theme.typography.body = TextStyleToken(font: .system(size: 16), lineHeight: 24)
theme.typography.caption = TextStyleToken(font: .system(size: 12), lineHeight: 18)
theme.icons.medium = 20
theme.spacing.lg = 14
theme.radius.md = 10
theme.icons.replace(UIIcons.Action.check, with: MyIcons.check)

AppRoot().theme(theme)
// 任意页面或子树可以 .theme(pageTheme)，不会修改旁边的主题。
```

`.theme(theme)` 为普通 Text 和输入框提供 body 默认值；`Text(...).font(.body)` 显式读取当前主题的 body。组件或祖先上的显式字体/样式优先于默认值，最近的显式样式优先。直接使用未提供 Theme 的 Compose 时保留宿主 TextEnvironment 默认值。`Icon(resource)` 和图标按钮默认读取 icon.medium，并跟随最近 TextScaler 放大。框架控件中的普通方向/状态图标消费 small/medium 槽位。`IconTheme.replace` 一步替换资源，不递归追踪替换链。

任意值仍可直接使用：`.font(.named("Menlo", size: 17))`、`.textStyle(TextStyleToken(...))`、`Icon(resource, size: 31)`（缩放前逻辑点）、`.padding(19)`、`.cornerRadius(13)`。显式字体族优先于主题字体族；仅指定 `.font(.system(size: 17))` 时仍继承主题的普通字体族，等宽槽位不受普通字体族覆盖。系统 fallback 继续处理主字体缺少的 grapheme。

### 圆角层级

组件不写圆角字面量；按角色读取 `theme.radius` 或对应的 `ThemeMetric`，应用换主题时整站同步：

| 角色 | token | 默认（逻辑点） |
| ---- | ----- | -------------- |
| 行 / chip / 小色块 / 高亮 | `theme.radius.sm`（`.rowRadius`） | 6 |
| 控件 / 面板内卡片 | `theme.radius.md`（`.controlRadius`） | 10 |
| 输入框外壳 | `theme.inputs.radius`（`.inputRadius`） | 10 |
| 分组容器 / 表格卡片 | `theme.radius.lg`（`.groupRadius`） | 14 |
| Panel / 工作区卡片 | `theme.radius.xl`（`.panelRadius`） | 18 |
| 胶囊 / Pill | `theme.radius.pill` | 9999（夹到半高） |

行、控件与容器的字面量（例如 4/6/8）只是历史遗留，迁移时映射到最接近的语义档位；自定义外观走 `ThemeMetric`，不要在组件里复制圆角数值。

只有字号覆盖而没有显式行高时，主题默认 body 行高按字号比例计算，避免大字号被固定的默认行高压住。显式 `.lineHeight(...)` 和语义 TextStyleToken 携带的行高保持其优先级；需要完全指定排版时直接传 `.textStyle(...)`。

## 应用自定义 token

```swift
struct BrandTokens: ThemeExtension {
    var hero = TextStyleToken(font: .system(size: 36, weight: .bold), lineHeight: 44)
    var cardInset: Float = 28
    static let defaultValue = BrandTokens()
}

theme.extensions[BrandTokens.self].cardInset = 32
let hero = SemanticFontRef { $0.extensions[BrandTokens.self].hero }
let cardInset = ThemeMetric { $0.extensions[BrandTokens.self].cardInset }
let avatarIcon = SemanticIconSize { $0.extensions[BrandTokens.self].cardInset }
Text("Overview").font(hero).padding(cardInset)
Icon(MyIcons.avatar, size: avatarIcon)
```

扩展按类型查找，复制 Theme 时整组复制。缺失扩展返回该类型的默认值；`remove` 恢复默认。`SemanticColorRef`、`SemanticFontRef`、`SemanticIconSize`、`ThemeMetric` 都接受开放的解析闭包，无须给框架枚举增加 case。原生接口使用类型化 token；目前没有 CSS 文本解析器或 CSS cascade，浏览器展示也尚未接入这套 Swift Theme。

## 字体缩放与 DPI

```swift
var config = ApplicationConfiguration(title: "Studio")
config.textScaler = TextScaler(1.5) // 主窗口和辅助窗口共用宿主偏好

// 独立使用 Compose 或覆盖单个子树：
Page().textScaler(TextScaler(1.25))
```

TextScaler 的最近作用域覆盖外层，不把倍率连乘。字体、显式行高和字距只缩放一次，测量与绘制使用同一结果；TextField 光标/选区与渲染缓存消费相同字体。Button（含状态色、Tab 和分段样式）、TextField、Select、Menu、Toolbar、ButtonGroup、DisclosureGroup、Accordion 和 Panel 标题允许按内容增长；Combobox 与 Tree 同步虚拟列表的行高。Menu 默认使用不透明浮层表面，行预算和高亮跟随实际文字高度。明确指定的 `.frame(height:)` 仍是应用约束，可能限制内容。

图标默认使用 `theme.icons.scaling = .text`：语义尺寸、自定义角色和直接传入的数值都会跟随 TextScaler，资源包、文件和纹理来源一致，且只缩放一次。图标按钮使用对称留白和正方形最小点击区；loading 时用同尺寸 Spinner 替换图标，并保留 tooltip 提供的辅助功能名称。普通文字按钮仍在文字旁显示 Spinner。

```swift
// 全局设计系统可以选择固定图标。
theme.icons.scaling = .fixed

// 局部覆盖优先于主题；倍率是替代值，不与文字倍率连乘。
Icon(MyIcons.logo, size: 31).iconScaling(.fixed)
Page().iconScaling(.factor(1.5))

// 推荐让图标与它的预留槽使用同一尺寸来源。
IconMetricsReader { metrics in
    Box(direction: .row, alignItems: .center, justifyContent: .center) {
        Icon(MyIcons.check, size: .small)
    }.frame(width: metrics.size(.small))
}
```

`.frame` 和 `.padding` 作用在 Icon 的容器上，内部 SVG 保持所请求的尺寸和比例。不要把 `metrics.size(...)` 的结果再次传给默认会缩放的 Icon；需要传入已经计算好的最终尺寸时，局部使用 `.iconScaling(.fixed)`。固定尺寸的 Avatar 属于图像容器，其 fallback 图标和 initials 保持在头像内部；需要放大头像时由调用方改变头像尺寸。

应用编写固定行高的自定义列表时，可用 `TextScalerReader { scaler in ... }` 计算行高。普通布局无需手动乘 DPI：宿主按屏幕密度重建字体栅格，SVG 按物理像素重新取图；光学字号保持逻辑点，因此 13pt 在 2× 屏幕仍使用 13pt 的字形设计。

当前 TextScaler 是线性倍率，非法/非有限倍率回退 1。宿主需将自己的辅助功能或用户偏好交给框架；尚无 Windows/Linux 系统文字大小变化的自动订阅，也没有非线性动态字号曲线。部分历史组件（例如 CommandPalette 行预算、Calendar 日期格、PropertyGrid 行槽）仍有固定行高或虚拟化几何，不能据此宣称整个目录已通过 200% 大字体。画廊的 Text 控件用于逐页暴露和验证这些缺口。

## 验证

`DesignSystemTests` 验证局部/自定义主题、任意字体族、一次缩放、输入测量与绘制、浮层继承、图标替换与显式尺寸；`SystemFontInstanceTests` 验证 macOS 真实可变字体坐标、字重轮廓和 1×/2× 光学尺寸及 advance。字体栅格化前后的布局 metrics 必须相同，见 `FontPipelineTests`。

画廊实际输入、200% 换行布局、局部 Menlo/字号/图标与中文编辑保存，以及菜单可读性的记录和截图见 [design-system-native.json](../guava-ui/evidence/design-system-native.json)。这些是选定页面的视觉和交互证据，不是整个目录的完成证明。
