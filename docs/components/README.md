# GuavaUI 组件设计参考

本目录收录组件设计契约。索引标记仅代表文档存在，不表示组件已达到完整或生产成熟状态。

实现质量、缺失组件与本次重构范围见 [GPUI Kit 对照审计](../guava-ui/gpui-kit-audit.md)，实际示例见 `GuavaUI/Sources/GuavaUIGallery/`。每篇覆盖：

1. **Anatomy** —— ASCII 框图 + 槽位命名
2. **Sizing** —— 高度 / padding / 最小命中区
3. **Tokens** —— 消费的 ColorScheme / Typography / Spacing / Radius / Motion 槽位
4. **States** —— rest / hover / press / focus / selected / disabled 矩阵
5. **Behavior** —— 键盘、指针、IME、辅助功能默认值
6. **Authoring rules** —— 调用方应做 / 不应做的事
7. **References** —— Material 3 / Fluent / Radix / Flutter Material / SwiftUI 对应组件

底层 token 体系见 [../guava-ui-design-system.md](../guava-ui-design-system.md)。

## 索引

| 组件 | 状态 | 文件 |
| ---- | ---- | ---- |
| Button | 文档已写 | [button.md](button.md) |
| IconButton | 文档已写 | [iconbutton.md](iconbutton.md) |
| Toggle | 文档已写 | [toggle.md](toggle.md) |
| Checkbox | 文档已写 | [checkbox.md](checkbox.md) |
| TextField | 文档已写 | [textfield.md](textfield.md) |
| Text / Typography / Color glyphs | 实现与验证边界 | [typography.md](typography.md) |
| NumberField | 文档已写 | [numberfield.md](numberfield.md) |
| Vec3Field | 文档已写 | [vec3field.md](vec3field.md) |
| AssetRefField / AssetDropTarget | 文档已写 | [assetref.md](assetref.md) |
| Modal / ContextMenu / TransitionView | 文档已写 | [interaction.md](interaction.md) |
| Sheet | 实现与验证边界 | [sheet.md](sheet.md) |
| Tooltip | 实现与验证边界 | [tooltip.md](tooltip.md) |
| Menu / ContextMenu / Select | 实现与验证边界 | [menu.md](menu.md) |
| JsonField | 文档已写 | [jsonfield.md](jsonfield.md) |
| Slider | 文档已写 | [slider.md](slider.md) |
| Rating | 实现与验证边界 | [rating.md](rating.md) |
| List / ListRow | 文档已写 | [list.md](list.md) |
| DataTable / DataTableModel | 实现与验证边界 | [data-table.md](data-table.md) |
| Avatar / AvatarGroup | 实现与验证边界 | [avatar.md](avatar.md) |
| Image / AsyncImage | 实现与验证边界 | [image.md](image.md) |
| Tree / TreeRow | 文档已写 | [tree.md](tree.md) |
| Panel | 文档已写 | [panel.md](panel.md) |
| SplitView | 文档已写 | [splitview.md](splitview.md) |
| ScrollView | 文档已写 | [scrollview.md](scrollview.md) |
| Tab | 文档已写 | [tab.md](tab.md) |
| Box / Row / Column | 文档已写 | [layout.md](layout.md) |

## 通用约定

- **所有可点击组件**的命中区最小高度 32pt，键盘焦点用 2px focusRing。
- **所有文本输入**默认垂直居中、左侧 inset = `theme.spacing.sm`、`clipsToBounds = true`。
- **状态层** (hover/press/selected/focused) 走 `Color.composited(over:)`，不要用 `.lighter()` / `.darker()`。
- **chrome 颜色** 通过 `node.theme.colors.*` 在 `_updateNode` 内每次重算，不要缓存到 attachments。
- **布局容器** (Box/Row/Column) `isHitTestable = false`，不参与命中测试。
