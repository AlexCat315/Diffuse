# 文字排版与彩色字形

`Text`、`TextField`、头像首字母和游戏内文字共用 shaping、`TextLayout` 与 `DrawList`。使用主题的字体、行高与字距；混合字体共用基线，换行不拆开一个 shaping cluster。源坐标保持 UTF-8，编辑选区和光标以 Swift grapheme 为单位。

## 普通字体与设计系统

主题提供 display、title、headline、body、bodyStrong、caption、label 和 mono 语义角色，应用可以替换每个完整 TextStyleToken，指定 `Typography.family`，或通过 ThemeExtension 定义自己的角色。`Font.named` 和显式 TextStyleToken 保留任意字体族/字号出口。最近 Theme 为没有显式字体的文字和输入框提供 body 默认值，显式样式优先。TextScaler 对字号、行高和字距只缩放一次，测量、绘制和编辑使用一致结果；DPI 只改变栅格密度。[设计系统契约](design-system.md)有可运行的 API 示例与限制。

本轮检查真实系统字体发现三个问题：CoreText 字体描述符在数组中的位置被误当作 FreeType collection face index，SF 的 Medium/Semibold/Bold 因此可能加载失败并静默回退；可变字体轴没有传入 FreeType；CoreText 使用物理字号选择字体，令光学尺寸随 DPI 改变。现在按 face/named instance 查找字体，复制 CoreText 已解析的设计坐标，并在逻辑字号下选择光学尺寸。HarfBuzz 使用未 hint 的布局 advance，字形图集保留同一布局 metrics，栅格化不再用 bitmap bearing/advance 覆盖测量缓存。

`SystemFontInstanceTests` 检查真实 SF 的字重坐标、实际轮廓覆盖量，以及 1×/2× 的光学坐标和 advance；`FontPipelineTests` 检查首次栅格化前后 metrics 不变。这些证明修复了字体实例与测量路径，没有宣称自定义 FreeType 灰度栅格与系统原生文字的每个像素相同。

## 单行省略号

`Text("完整标题 👩🏽‍💻").truncated().font(.bodyStrong)` 按实际分配绘制单行尾部省略号，同时保留完整 tooltip 与辅助功能名称。它不会切开 emoji ZWJ、组合音标或旗帜；显式换行合并为空格，连省略号都放不下时不绘制残缺字符。测量与绘制复用同一套字体、字距、缩放及缓存；缩窄、放大和实时改字都会重新选择可见文本。`lineLimit(1)` 仍只禁用换行，需要省略号时显式使用 `truncated()`；此 API 不处理多行省略。

AppBar、TabView、`Button`/`Link`/`MenuButton` 的字符串标题、`DatePicker` 与 `Select`/`Combobox` 触发标题均已应用单行省略。Button/Link 与 DatePicker 的完整标题进入 tooltip；MenuButton 可显式传 `tooltip:`，Select/Combobox 通过 trigger description 保留完整名称。菜单项标题仍按 [Menu](menu.md) 的文档自然换行，不属于控制标题。`SingleLineTextTests` 验证 grapheme 边界、零宽度、shaping 和实际绘制，AppBar 通过真实 tooltip 与 heading 验证全文出口；`TruncationTests` 在窄约束下覆盖 Button/Link/MenuButton/DatePicker 的 `clipsToBounds` 与完整辅助功能名称。

## 彩色字体

macOS 上由 `FontProvider` 识别 FreeType color face，交给 `NativeColorGlyphFont` 的 CoreText shaping/metrics/rasterizer。平台 rasterizer 通过 `ColorGlyphSource` 提供逻辑 metrics、line metrics 和 straight-alpha sRGB RGBA bitmap；通用 `FontAtlas` 不依赖 CoreText。

系统字体在本机探测中只有固定 bitmap strikes：原路径未选择有效尺寸，字形 advance/bitmap 错误；手动选择 strike 后，当前随项目分发的 FreeType 返回无法解码该 bitmap 的错误。FreeType 对 color/sbix glyph 的格式和可选解码能力见[官方字形加载说明](https://freetype.org/freetype2/docs/reference/ft2-glyph_retrieval.html)。本次保持二进制依赖不变，使用系统原生字体服务解决这条渲染路径。

- 逻辑字号的 CTFont 同时用于 shaping、advance 和行 metrics。栅格化缩放 CGContext，按逻辑字形 bounds 计算物理像素包围盒，外加 1 物理像素透明边。这样密度改变不会改变光标宽度或连字的 cluster。
- CoreText 的 UTF-16 string index 转为全局 UTF-8 cluster，保留 ZWJ、肤色、regional flag 与 variation selector 序列。原生 run 的位置偏移进入现有 positioned-glyph 布局。
- 普通 glyph 使用 alpha 图集；彩色 glyph 使用延迟分配的 RGBA 平面。默认 2048² 图集的 RGBA 平面为 16 MiB，仅测量文字不分配。字形缓存按 font ID、glyph ID、字号、密度区分；同一 font ID 在其生命周期中表示不可变字体。
- `GlyphAtlasInfo.format` 选择 alpha 或 RGBA 绘制。彩色字形保留源 RGB，文字颜色的 alpha 和节点 opacity 仍作用于它。CoreGraphics 预乘像素在上传前转为 straight alpha，复用已有 RGBA shader。
- `TextureID` 的最高位保留给彩色字体平面：`alphaID.colorGlyphAtlasID`。alpha atlas 和应用图片 ID 必须为非零且小于 `0x8000_0000`。
- 两个平面独立保存 dirty rectangle、支持局部上传与 reset。应用/Demo 在两个平面上传成功后才 markClean；任一上传失败保留脏状态以便下帧重试。
- 游戏内快照改为 `atlasUpdates` 数组，携带 format 与实际纹理 ID。主/渲染线程传输独立合并两个平面的更新，保留跳帧期间出现的 glyph；渲染端在 GPU 尚未就绪或上传失败时保留待上传数据。每平面传输限制为 64 MiB。

## 示例与验证

画廊 `Theme / Typography` 展示语义层级、英文字距/连字样例、中文、带重音姓名和彩色 emoji，以及红色文字/半透明示例；上半部分可修改局部主题并编辑/保存。`TextField` 有可编辑的 `A👩🏽‍💻中🙂B` 和实时 grapheme/字节计数；`Avatar` 保留 `👩🏽‍💻 coder`。此前 macOS Retina 已在明暗主题实际检查 14/24/40 点混排的方向、颜色、基线和显示，输入框实际验证删除一次、完整撤销、按字符选区替换及再撤销；这份历史原生检查记录见 [color-glyph-native.json](../guava-ui/evidence/color-glyph-native.json)，不代表所有新页面的完整回归。

`ColorGlyphTests` 使用真实系统字体验证上述五种 emoji、metrics/raster 分离、全局 UTF-8 cluster、alpha/RGBA batch、缓存/reset 和 1×/2× 稳定 advance。`ColorGlyphAtlasTests` 使用独立数据验证 RGBA 行/间距/脏区域、非法数据、图集耗尽/reset。`InGameDrawListSourceTests` 与 `ScriptCanvasTests` 验证双图集和跳帧传输；`TextFieldNavigationTests` 验证实际布局下的 emoji 光标/删除/撤销。

## 边界

此次新增的原生彩色字体来源仅为 macOS。Linux/Windows 彩色 bitmap/COLR 字体尚未接入 `ColorGlyphSource`；Wasm 仍使用现有字体集合与单通道传输，未宣称支持 RGBA 字形。通用 atlas 能容纳 RGBA，但这不等于所有字体格式/所有平台已完成。没有新增字体图集自动淘汰/分页；极端 glyph 多样性下仍会报告耗尽。RTL/双向段落的完整编辑语义和超长单行分段布局仍需补齐。
