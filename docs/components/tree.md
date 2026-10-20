# Tree / TreeRow

Tree 提供窗口化层级列表、折叠、多选、搜索和拖放。缩进槽只保留低对比度竖线，不绘制连接文字或箭头的横线。

## API

```swift
Tree(roots, id: \.id,
     children: { $0.children },
     hasChildren: { !$0.children.isEmpty },
     configure: { tree in
    tree.isEnabled = isEnabled
    tree.selection.primary = $selectedID
    tree.selection.multiple = $selectedIDs
    tree.selection.expanded = $expandedIDs
    tree.search.query = query
    tree.search.text = { $0.title }
}) { node, isSelected, isExpanded, depth in
    Text(node.title).font(.body)
}
.frame(height: 250)
```

`children:` 也接受 key path；需要延迟读取时使用闭包和 `hasChildren:`。选择由调用方的 binding 保存；未传展开 binding 时，Tree 在本地会话中保存展开集。ID 必须稳定；同一 ID 可能出现在多个分支时，可用 `TreeNodeKey` 及 `primaryKey / multipleKeys / expandedKeys` 区分路径。

| 配置组 | 内容与默认 |
| --- | --- |
| `isEnabled` | 默认 true；统一控制行、展开按钮、键盘、拖放与辅助功能操作 |
| `selection` | 主选择、多选、展开集，以及对应的路径 key binding |
| `layout` | 行高 30、行间距 0、每级缩进 16、箭头槽 18、尾部槽 64；默认显示缩进竖线 |
| `search` | 查询、文本提取、过滤策略；默认过滤并自动展开匹配祖先 |
| `slots` | 自定义展开标记、尾部内容 |
| `events` | 选择通知、自定义键盘命令 |
| `drag` | 放置许可与提交；目标位置为 before / inside / after |

## 外观与状态

默认行使用 `SelectionAppearance(.navigation)` 的填色与圆角，选中底色避开左侧层级槽。文字继承 `theme.colors.onSurface`；展开箭头使用 `onSurfaceMuted`。层级线为 1pt 竖线，颜色是 `onSurfaceMuted` 的 24% alpha，可用 `layout.showsIndentGuides = false` 关闭。行间距、文本缩放与窗口化裁剪使用同一份几何，避免线段因行距断开。叶子保留空箭头槽以对齐文字。

禁用行使用 0.55 透明度并停止输入；禁用或卸载会释放拖放捕获与焦点。主题变化会使继承该主题的绘制缓存失效，文字与竖线实时更新；局部覆盖主题的子树保留自己的颜色。

## 交互

- 单击展开槽折叠或展开，单击内容选择；Command / Control 单击切换多选，Shift 选择可见范围。
- ↑ / ↓ 导航，Home / End 到首尾，← 折叠或选择父节点，→ 展开或选择首个子节点，Return / Space 选择当前项。
- Option / Alt + → 全部展开，Option / Alt + ← 全部折叠；更新调用方绑定的展开集。
- 搜索保留匹配节点的祖先并自动展开路径；清空搜索恢复原有展开状态。
- 拖放支持 before / inside / after，Escape 取消并释放捕获；业务数据重排由调用方的 `onDrop` 完成。
- 行提供 treeItem、selected / expanded 与禁用语义；辅助功能操作遵守同一启用状态。

## 延迟子节点与边界

提供廉价的 `hasChildren` 后，普通展示不会读取折叠分支的 `children`，已知叶子也不会调用它。展开才读取该分支。搜索和全部展开需要遍历当前可用子树，因此会读取相关分支。

这是同步延迟读取；网络请求、加载中与失败状态由调用方的数据层管理。将已缓存子节点交给 Tree，数据更新后重组即可。不要在 `children` 中直接启动网络副作用。

## 响应式与输入密度

Tree 自带垂直 ScrollView 和 VirtualStack，放在有高度约束的容器中；不需要再包一层垂直滚动。先按 TextScaler 解析行高与行距、按字体和图标倍率解析缩进，再在 touch surface 上把行高与非零展开槽提升到至少 44pt。切回 pointer 移除触摸下限，保留文字缩放、节点、选择与展开状态。

rowContent 只负责内容；展开标记、缩进和选中底色由 Tree 及 TreeRowStyle 管理。自定义样式可用 `.treeRowStyle(_:)`，默认只包裹内容区。使用 `.treeRowStyle(style, scope: .row)` 可将同一背景和选中标记延伸到缩进、展开槽及尾部控件；各槽仍保留自己的点击、展开和输入行为。

## 验证与文件

- Gallery `--component tree`：搜索、全部展开 / 折叠、多选、禁用与实时主题切换。
- Compose `Tree/BehaviorTests.swift`：折叠分支延迟读取、全部展开 / 折叠、Home / End、搜索恢复与禁用输入。
- `Adaptive/RowDensityTests.swift`、`TextScaleRowTests.swift`：390 / 720 / 1280pt、输入密度、100% / 200% 缩放与 light / dark。
- `ThemePaintInvalidationTests.swift`、Runtime `Rendering/CompositionPaintTests.swift`、Gallery `AppearanceTests.swift`：保留节点与绘制缓存的主题切换。

主体：[Tree.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Tree.swift)；配置：[TreeOptions.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/TreeOptions.swift)；指示线：[Guides.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Data/Lists/Tree/Guides.swift)；默认样式：[DefaultTreeRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/Styles/Components/DefaultTreeRowStyle.swift)。
