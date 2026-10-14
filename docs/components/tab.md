# TabView / TabItem

单选 tab 容器：tab bar 行 + divider + 当前选中 tab 的 content。

## Anatomy

```
┌─Tab A*─┬─ Tab B ─┬─ Tab C ─┬───────────┐
│        │         │         │           │ ← TabBar (.surfaceVariant 底)
│  ━━━━━ │         │         │           │ ← 2px accent indicator (仅 selected)
├────────┴─────────┴─────────┴───────────┤ ← Divider
│                                        │
│  active tab 的 content                  │
│                                        │
└────────────────────────────────────────┘
```

## API

```swift
@State var page: String = "components"

TabView(selection: $page, tabs: [
    TabItem("Components", id: "components") { componentsPage },
    TabItem("Tokens",     id: "tokens")     { tokensPage },
    TabItem("Layouts",    id: "layouts")    { layoutsPage },
])
```

| 参数 | 说明 |
| ---- | ---- |
| `selection` | `Binding<ID>` 必填，单选 |
| `tabs` | `[TabItem<ID>]`，按顺序在 bar 中绘制 |
| `TabItem(label, id:, content:)` | 标签 + 稳定 ID + 内容 ViewBuilder |

`ID` 必须是 `Hashable`；常用 `String` / 自定义 enum / `Int`。

## Tokens

| 槽位 | 默认 | Token |
| ---- | ---- | ----- |
| TabBar 底色 | `theme.colors.surfaceVariant` | theme |
| 选中文字 | `accent` | theme |
| 未选中文字 | `onSurfaceMuted` | theme |
| 选中下划线 | 2px `accent` | theme |
| Tab horizontal padding | 12 | 硬编码（待迁 token） |
| Tab vertical padding | 8 | 硬编码（待迁 token） |

## Behavior

- **指针**：单击某 tab → `selection.wrappedValue = tab.id`
- **键盘**：单一 Tab 停靠 + ← / → / Home / End 在标签间移动，禁用标签跳过
- **content 切换**：只渲染 active tab 的 content；其他 tab 的 content 闭包不参与 recompose
- **selection miss**：若 `selection.wrappedValue` 不命中任何 tab → bar 仍显示，content 区为空

## Authoring rules

✅ 应当：
- 用 `@State` 持有 selection
- ID 类型在整个生命周期内稳定（不要把 array index 当 ID）
- 把 TabView 放在已有高度的容器内（content 撑满剩余）

❌ 不应：
- 在 tab 切换时重建 `tabs` 数组（content 闭包会丢上下文）
- 嵌套 TabView 同 ID 类型 —— 用不同 ID 类型避免歧义

## Known limitations / TODO

- 没有 `TabStyle` 协议，视觉硬编码（chrome / indicator 颜色 / padding）
- 没有折叠菜单（溢出滚动、键盘导航与 compact 底部栏已实现）
- 没有 close button / dirty marker（VS Code 风格 EditorTabs）
- TabBar 单行；溢出可滚动；没有折叠菜单

## References

| 设计系统 | 借鉴点 |
| -------- | ------ |
| Material 3 | underline indicator + 选中 accent 文字 |
| Fluent UI v9 | TabList + Tab 拆分 |
| Radix Primitives | Tabs.Root + Tabs.List + Tabs.Trigger + Tabs.Content |
| SwiftUI | TabView(selection:) |

## File map

- 主体: [GuavaUICompose/Primitives/TabView.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/TabView.swift)
- 测试: [Tests/GuavaUIComposeTests/TabViewTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/TabViewTests.swift)

## 响应式与输入密度

TabStripPlacement 默认 .adaptive：surface width class 为 compact 时底部栏，其余顶部栏。显式 .top/.bottom 可覆盖。移动栏位只反转排列方向，保留当前页面的节点和局部状态。touch 下 tab 和关闭按钮至少 44pt；横向滚动 strip 同步扩展高度，segmented 额外包含 6pt padding。
