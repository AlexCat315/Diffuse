# 文字排版与彩色字形

`Text`、`TextField`、头像首字母和游戏内文字共用 shaping、`TextLayout` 与 `DrawList`。使用主题的字体、行高与字距；混合字体共用基线，换行不拆开一个 shaping cluster。源坐标保持 UTF-8，编辑选区和光标以 Swift grapheme 为单位。

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

画廊 `Theme / Typography` 有 14/24/40 点中文、带重音姓名与彩色 emoji 混排，以及红色文字/半透明示例；`TextField` 有可编辑的 `A👩🏽‍💻中🙂B` 和实时 grapheme/字节计数；`Avatar` 保留 `👩🏽‍💻 coder`。macOS Retina 已在明暗主题实际检查方向、颜色、基线和显示，输入框实际验证删除一次、完整撤销、按字符选区替换及再撤销。原生检查记录见 [color-glyph-native.json](../guava-ui/evidence/color-glyph-native.json)。

`ColorGlyphTests` 使用真实系统字体验证上述五种 emoji、metrics/raster 分离、全局 UTF-8 cluster、alpha/RGBA batch、缓存/reset 和 1×/2× 稳定 advance。`ColorGlyphAtlasTests` 使用独立数据验证 RGBA 行/间距/脏区域、非法数据、图集耗尽/reset。`InGameDrawListSourceTests` 与 `ScriptCanvasTests` 验证双图集和跳帧传输；`TextFieldNavigationTests` 验证实际布局下的 emoji 光标/删除/撤销。

## 边界

此次新增的原生彩色字体来源仅为 macOS。Linux/Windows 彩色 bitmap/COLR 字体尚未接入 `ColorGlyphSource`；Wasm 仍使用现有字体集合与单通道传输，未宣称支持 RGBA 字形。通用 atlas 能容纳 RGBA，但这不等于所有字体格式/所有平台已完成。没有新增字体图集自动淘汰/分页；极端 glyph 多样性下仍会报告耗尽。RTL/双向段落的完整编辑语义和超长单行分段布局仍需补齐。
