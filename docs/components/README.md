# GuavaUI 组件设计参考

本目录给每个内置组件一份单独的设计契约。每篇覆盖：

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
| Button | ✅ | [button.md](button.md) |
| IconButton | ✅ | [iconbutton.md](iconbutton.md) |
| Toggle | ✅ | [toggle.md](toggle.md) |
| Checkbox | ✅ | [checkbox.md](checkbox.md) |
| TextField | ✅ | [textfield.md](textfield.md) |
| NumberField | ✅ | [numberfield.md](numberfield.md) |
| Vec3Field | ✅ | [vec3field.md](vec3field.md) |
| AssetRefField / AssetDropTarget | ✅ | [assetref.md](assetref.md) |
| Slider | ✅ | [slider.md](slider.md) |
| List / ListRow | ✅ | [list.md](list.md) |
| Tree / TreeRow | ✅ | [tree.md](tree.md) |
| Panel | ✅ | [panel.md](panel.md) |
| SplitView | ✅ | [splitview.md](splitview.md) |
| ScrollView | ✅ | [scrollview.md](scrollview.md) |
| Tab | ✅ | [tab.md](tab.md) |
| Box / Row / Column | ✅ | [layout.md](layout.md) |

## 通用约定

- **所有可点击组件**的命中区最小高度 32pt，键盘焦点用 2px focusRing。
- **所有文本输入**默认垂直居中、左侧 inset = `theme.spacing.sm`、`clipsToBounds = true`。
- **状态层** (hover/press/selected/focused) 走 `Color.composited(over:)`，不要用 `.lighter()` / `.darker()`。
- **chrome 颜色** 通过 `node.theme.colors.*` 在 `_updateNode` 内每次重算，不要缓存到 attachments。
- **布局容器** (Box/Row/Column) `isHitTestable = false`，不参与命中测试。
