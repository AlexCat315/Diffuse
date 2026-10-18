# MenuButton

带常规按钮外观的菜单触发器。点击后通过 `Popover` 在按钮下方打开 `Menu`；菜单继承 Portal、Escape/外部点击关闭、焦点与 expanded 语义。

## Anatomy

```
┌──────────────┐
│   Options ▾  │
└──────────────┘
┌────────────────────┐
│ Rename             │
│ Duplicate          │
│ ────────────────── │
│ Delete             │
└────────────────────┘
```

- **trigger**：常规 secondary 按钮，保留 hover/press/focus/disabled
- **popover**：从触发器下方展开；窗口边界自动翻转/夹紧
- **menu**：复用 `Menu` 的行、快捷键、选中态、子菜单和键盘导航

## API

```swift
MenuButton("Options", entries: [
    .item(MenuItem(id: "rename", title: "Rename") { rename() }),
    .item(MenuItem(id: "duplicate", title: "Duplicate") { duplicate() }),
    .separator("separator"),
    .item(MenuItem(id: "delete", title: "Delete", role: .destructive) { delete() }),
], width: 200)
```

```swift
public struct MenuButton<Label: View>: View {
    public init(entries: [MenuEntry],
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .bottomLeading,
                @ViewBuilder label: () -> Label)
}
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `entries` | 必填 | `MenuEntry` 数组 |
| `isEnabled` | `true` | 禁用时触发器不展开 |
| `width` | `nil` | 菜单宽度；`nil` 使用内容自然宽度 |
| `placement` | `.bottomLeading` | 与触发器的方位及对齐方式 |
| `label` | 必填 | 自定义触发内容；`Text` 版本可直接传标题 |
| `tooltip` | `nil` | 可选完整标题 tooltip；`Text` 版本接收并显示 |

`MenuButton("…")` 的字符串标题使用单行尾部省略，完整标题保留在 accessibility label；传入 `tooltip:` 时同时作为触发器 tooltip。自定义 `label` 的省略/换行仍由调用方负责。

`Popover` 新增 `triggerStyle: AnyButtonStyle?`：`MenuButton` 用 `SecondaryButtonStyle` 提供按钮 chrome；需要裸触发器时传自定义 style。

## Sizing

- 触发器沿用 `Button` 的 chrome 与触摸 44pt 命中。
- 菜单宽度由 `width` 或内容决定；高度/滚动由 `Menu` 的 `maxVisibleRows` 管理。
- 菜单在触发器下方展开；窗口不足时由 Popover 翻转/夹紧。

## Tokens

全部来自 `Button` / `Menu` / `Popover`：

| 槽位 | 来源 |
| ---- | ---- |
| 触发器背景/边框/焦点环 | `SecondaryButtonStyle` |
| 菜单材质/圆角 | `Menu` 的 `glassSurface(.controlRadius)` |
| 行 hover/选中/禁用 | `Menu` 行 token |
| 展开态语义 | `ActionControlAccessibility.isExpanded` |

## States

| 状态 | 行为 |
| ---- | ---- |
| closed | 触发器 rest/hover/press/focus/disabled |
| open | 点击触发器展开菜单；`isExpanded = true` |
| 选择菜单项 | 调用 `MenuItem.action`，关闭菜单 |
| Escape / 外部点击 | 关闭菜单 |
| 再次点击触发器 | 关闭菜单 |
| disabled | 不展开；菜单不挂载 |

## Behavior

- **指针**：点击触发器切换；点击菜单行执行并关闭；外部点击关闭。
- **键盘**：触发器 Enter/Space 打开；菜单内 Up/Down/Home/End/Enter/Escape/类型查找沿用 `Menu`。
- **辅助功能**：触发器 role=button、名称来自 label、`isExpanded` 反映菜单状态；菜单行保留 role/禁用/选中态。
- **焦点**：菜单打开后焦点进入菜单；关闭后 Popover 还原触发器焦点。
- **Portal**：菜单通过 Popover 的 Portal 渲染，不受父级裁剪/层叠影响。

## Authoring rules

- 命令集合用 `MenuButton`；不要再用 `Button` + 手写 Popover/Menu。
- 主操作 + 备选操作需要两个独立动作时，首选 `MenuButton` + 单独主按钮；`SplitButton` 的单一 Tab 停靠与左右分区仍待实现。
- 菜单项 id 必须稳定；禁用项不要用 `isEnabled: false` 代替业务校验。
- 菜单宽度要给长标题余量；超长内容由 Menu 行截断/换行规则处理。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/MenuButtonTests.swift`）：

- `opensRunsAndCloses`：点击触发器打开 Portal 菜单，点击 `Save` 执行一次并关闭。
- `disabledDoesNotOpen`：禁用触发器不产生 Portal 条目。

Gallery `menuButton` 页提供 Options/Disabled 触发器、破坏性项与 action 回调。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component menuButton --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Options","role":"button","visible_only":true}'
guava-dev devtools input-ui 9229 --click-node <Options>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Rename / Duplicate / Delete
guava-dev devtools input-ui 9229 --click-node <Rename>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Last action:","visible_only":true}'
guava-dev devtools capture-ui 9229 /tmp/guava-menubutton.jpg
```

## References

- SwiftUI `Menu`
- Flutter `MenuAnchor` / `PopupMenuButton`
