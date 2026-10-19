# AssetRefField / AssetDropTarget

资源引用字段显示名称、可选副标题和预览；选择、清空与拖放写回同一个 `Binding<AssetRef?>`，触摸用户可以直接使用选择与清空按钮。

```swift
AssetRefField(value: $texture,
    activePayload: $activeAssetDrag,
    acceptedKinds: ["texture"], pickerOptions: textures,
    placeholder: "Choose a texture")
```

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| value | 必填 | 调用方拥有的可选资源引用 |
| activePayload | nil 常量 | 当前拖拽 payload；不参与持久化 |
| acceptedKinds | 空集合 | 空集接受所有 kind，否则同时过滤拖放与选择菜单 |
| pickerOptions | 空数组 | 非空时显示选择入口；没有兼容项时禁用入口 |
| placeholder | Drop asset | 空值提示 |
| isEnabled | true | 同步禁用拖放、选择、清空；打开的选择菜单会关闭 |

`AssetRef` 包含稳定 id、name、可选 subtitle、kind 和可选 previewPath。它是普通值，不要求资源模型继承框架类型；应用在边界构造它即可。

## 外观与空间

- 凹面输入底色、inputRadius、水平 6/垂直 4pt padding；预览 34×24，不按文字缩放放大像素。
- 字段按内容自然增高，最小为 32pt 乘文字缩放；触摸时至少 52pt，为内部 44pt 按钮和上下 padding 留出空间，不使用固定 32pt 高度裁掉操作。
- 名称与副标题单行省略并提供全文 tooltip，跟随文字缩放；字段语义始终保存完整名称、kind 与副标题。没有预览图时，缩略图位显示按 kind 关键词（不区分大小写）选出的图标：image/texture → 图像，mesh/model → 立方体，material/shader → 画笔，audio、video、scene、script、text、package 各有对应图标，其余为通用文件；完整 kind 只在 tooltip 和语义中，不再把 kind 文字截断成 “im…”。空字段只接受一种 kind 时，以弱化色显示该 kind 的图标，提示可拖入的内容。文字列可收缩，预览、清空和选择按钮不被挤小。
- 清空使用 ghost ×，名称为 `Clear asset`；选择使用 ghost chevron，名称为 `Choose asset`，暴露当前值与展开态。触摸目标至少 44×44。
- 选择菜单在锚点下方展开，240pt 首选宽度、窗口夹紧、空间不足翻转；触摸行至少 44pt，长选项在菜单中完整换行。选择后关闭，Escape/外部点击取消。

## 语义与状态

字段是带完整名称/值的 `group`，合并装饰文字但保留两个真实按钮；disabled 状态同步到语义。空值不显示清空按钮。外部值即使不是当前 acceptedKinds，也保持显示，便于调用方修复既有数据；新选择和拖放只能使用兼容 kind。

`AssetDropTarget` 通过场景的 `AssetDropRegistryHolder.current` 注册实时矩形。拖拽源在释放时提交 `AssetDropPayload`，兼容且启用的目标接收它；布局变化使用 live node frame，不维护另一套命中表。高亮与 activePayload 是运行会话状态；宿主负责安装/释放其注册表。

弹层需要窗口根部的 PortalHost，通常由 LayerRoot 提供。预览加载失败时回退到同一 kind 图标；没有 pickerOptions 的应用应提供自己的资源选择入口，不能只依赖拖放。

## 验收

`AssetFieldAdaptiveTests` 覆盖 390/720/1280、100%/200%、明暗主题与 RTL：在 220pt 字段内检查操作边界和触摸尺寸、完整语义，打开选择菜单并排除错误 kind，选择后清空，以及禁用态无激活入口。`AssetRefFieldTests` 覆盖实际注册表投递与类型拒绝。

Gallery `assetRef` 页使用实际容器宽度，包含长名称/副标题和一个不兼容选项；DevTools 验收记录见[自适应规范](adaptive-spec.md#5-规范完成清单按本文验收)。

2026-10-19：DevTools 在 390×820 触摸 200%、720×820 深色混合、1280×820 RTL 指针 200% 选择完整长资源后，字段分别为 286×77、560×52、929×77，名称和副标题完整可查询；触摸按钮 44×44。不兼容 material 菜单查询为 0，三档均一次清空得到 `Asset: None`，空值仍保留 button 角色的选择入口。实际查看三档镜像：窄宽省略不挤压操作，深色凹面、浅色圆角与 RTL 布局均无越界；菜单磨砂捕获及浮层后方残留手势的问题已分别修复并回归。

## 源码

- [AssetRefField.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Controls/Fields/AssetRefField.swift)
- [AssetDropTarget.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Overlays/AssetDropTarget.swift)

字段 chrome 与其他输入一致：surface 底色、1pt 输入边框和输入圆角，缩略图格为 34×24 的 surfaceVariant 圆角块；拖放时的接受/拒绝高亮仍叠加在其上。`AssetRefFieldTests.kindGlyphs` 覆盖关键词映射，`thumbnailIsAGlyph` 确认空值和有值时字段内都没有 kind 文字。DevTools 在 1280 Gallery `--component assetRef` 的浅色与深色主题下截图确认：三个自适应预览和 “Choose a texture” 空字段都显示图像图标格，字段边界清晰。
