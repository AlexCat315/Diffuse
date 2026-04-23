# Tree / TreeRow

层级树。在 List 之上加 `disclosure` 折叠 + `depth` 缩进 + `children:` keyPath。

## Anatomy

```
┌──────────────────────────────────────────────┐
│  ▼  Scene Root                                │ ← depth 0
│      ▶  Main Camera                           │ ← depth 1, 无 children → 不绘制 chevron 但保留宽度
│      ▼  Lights                                │ ← depth 1, 有 children, expanded
│          ▶  Directional Light                 │ ← depth 2
│          ▶  Fill Light                        │
│      ▶  Props                                 │
└──────────────────────────────────────────────┘
   ↑       ↑       ↑
   │       │       └── rowContent(item, isSelected, isExpanded, depth)
   │       └── disclosureWidth (默认 18)
   └── indent gutter = depth × indentation (默认 16)
```

## API

```swift
Tree(roots,
     children: \.children,
     id: \.id,                       // 默认 \.id
     selection: $selectedID,
     expanded: $expandedSet,         // 可选，nil 时用内部 @State
     rowHeight: 30,
     rowSpacing: 0,
     indentation: 16,
     disclosureWidth: 18) { node, isSelected, isExpanded, depth in
    Text(node.title)
}
```

| 参数 | 默认 | 说明 |
| ---- | ---- | ---- |
| `children` | 必填 keyPath | 返回 `[Element]?` 或 `[Element]` |
| `selection` | `.constant(nil)` | 单选 |
| `expanded` | nil | 外部维护展开集；nil 时组件自管 |
| `rowHeight` | 30 | 每行高度 |
| `indentation` | 16 | 每级缩进像素 |
| `disclosureWidth` | 18 | 箭头列宽度（无子节点也保留） |

## Tokens (DefaultTreeRowStyle)

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| 选中底色 | `theme.colors.stateLayerSelected` | composited |
| hover 底色 | `theme.colors.stateLayerHover` | composited |
| chevron 颜色 | `theme.colors.onSurfaceMuted` | theme |
| 文本颜色 | `theme.colors.onSurface` | theme |

## Behavior

- **disclosure**：点击 chevron 区域翻转 expanded；点击其他区域选中本行
- **指针**：单击行 → `selection.wrappedValue = id`
- **滚动**：外层 `ScrollView(.vertical)`
- **键盘**：未实现

## Known issues

- chevron 列宽固定 `disclosureWidth`（即便没有 children 也占位）—— 这是为了对齐子层的设计选择，不是 bug
- 没有"全部展开 / 全部折叠"快捷
- `expanded` binding 使用 `Set<ID>` 时调用方需保证 hash 稳定

## Authoring rules

✅ 应当：
- 大数据集时给 `expanded:` 外部维护，便于持久化展开状态
- rowContent 用 `Text` + `Row` 自由组合 icon
- 把 Tree 放进已有高度的容器（如 SplitView 一侧或 `.flex()`）

❌ 不应：
- 在 rowContent 里写 chevron / 缩进 —— Tree 已经处理
- 给 rowContent 写选中底色 —— style 处理

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Fluent UI v9 | TreeView 的 chevron + indent + selection 三层模型 |
| Radix Primitives | 暂无 Tree primitive，参考 Accordion 的 expanded binding |
| SwiftUI | `OutlineGroup(children:)` + 自定义 disclosure |

## File map

- 主体 + `_TreeRowComposite`: [GuavaUICompose/Primitives/Tree.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Tree.swift)
- Style 协议 + 默认: [GuavaUICompose/Theme/TreeRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/TreeRowStyle.swift) · [DefaultTreeRowStyle.swift](../../GuavaUI/Sources/GuavaUICompose/Theme/DefaultTreeRowStyle.swift)
