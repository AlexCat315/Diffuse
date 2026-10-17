# SplitButton

主操作 + 相邻菜单触发器。左侧按钮执行默认动作，右侧箭头打开与 `MenuButton` 相同的菜单；两区各有独立命中、禁用和语义。

## Anatomy

```
┌──────────────────────────┬────┐
│         Save             │ ▾  │
└──────────────────────────┴────┘
                  ↓
        ┌──────────────────┐
        │ Save as…          │
        │ Export            │
        │ ────────────────  │
        │ Discard           │
        └──────────────────┘
```

- **primary**：常规 secondary 按钮，执行默认动作
- **menu trigger**：`MenuButton` 的箭头触发器，打开 Menu
- **menu**：与 `MenuButton` 共用 Portal、键盘、Escape/外部点击关闭

## API

```swift
SplitButton("Save", entries: [
    .item(MenuItem(id: "saveAs", title: "Save as…") { saveAs() }),
    .item(MenuItem(id: "export", title: "Export") { export() }),
], menuWidth: 200) {
    save()
}
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `label` | 必填 | 主按钮内容 |
| `entries` | 必填 | 菜单项 |
| `isEnabled` | `true` | 两区同步禁用 |
| `menuWidth` | `nil` | 菜单宽度 |
| `action` | 必填 | 主按钮动作 |

## Sizing

- 主按钮与箭头的触摸命中均由 `Button` 提升到 44pt。
- 主按钮使用 `.flex(1, shrink: 1, basis: 0)` 填充剩余宽度；箭头保持自然宽度。
- 菜单宽度由 `menuWidth` 或内容决定，位置/翻转由 Popover 处理。

## Tokens

全部来自 `SecondaryButtonStyle` / `MenuButton` / `Menu`：

| 槽位 | 来源 |
| ---- | ---- |
| 主按钮与箭头 chrome | `SecondaryButtonStyle` |
| 菜单材质/行高 | `Menu` + `glassSurface` |
| expanded 语义 | 箭头 Popover trigger |
| 禁用 | 两区同步 `isEnabled` |

## States

| 状态 | 行为 |
| ---- | ---- |
| closed | 主按钮与箭头各自 rest/hover/press/focus |
| primary click | 执行默认动作；菜单不打开 |
| arrow click | 打开菜单；不执行默认动作 |
| menu action | 执行菜单项并关闭 |
| disabled | 两区都不响应点击，箭头不展开 |
| Escape / outside | 关闭菜单 |

## Behavior

- **指针**：两个独立命中区；主按钮与箭头互不触发对方动作。
- **键盘**：主按钮与箭头各自是普通 Button，Enter/Space 激活；菜单内沿用 Menu 键盘导航。
- **辅助功能**：主按钮名称来自 label；箭头 label 为 `"More actions"`；菜单行保留 role/禁用/选中态。
- **焦点**：当前是两个独立 Tab 停靠，没有实现“Tab 进入整体 + 左右分区”的单一焦点模型。需要严格 split-button 键盘模型时，后续应改为单一 host。
- **视觉**：当前是两个相邻的 secondary 按钮，没有合并成共享 1px 分隔的单体 chrome；功能与命中正确，视觉合并待补。

## Authoring rules

- 默认动作明确、备选动作低频时用 `SplitButton`；只有主操作时用 `Button`，只有命令集合时用 `MenuButton`。
- 菜单项应覆盖主操作的所有变体（另存为、导出、丢弃）。
- 不要用两个独立 `Button` 手拼；用本组件保证两个区域的禁用和菜单语义一致。
- 宽屏需要固定总宽时在调用方 `.frame(width:)`；主按钮会填充剩余空间。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/SplitButtonTests.swift`）：

- `zones`：主按钮执行一次；箭头打开菜单；选择 `Save as` 执行一次并关闭。
- `disabled`：两区点击都不执行、不打开 Portal。

Gallery `splitButton` 页提供 Save、Save as、Export、Discard 与状态文本。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component splitButton --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Save / More actions
guava-dev devtools input-ui 9229 --click-node <Save>
guava-dev devtools input-ui 9229 --click-node <More actions>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Save as / Export / Discard
guava-dev devtools input-ui 9229 --click-node <Export>
guava-dev devtools capture-ui 9229 /tmp/guava-splitbutton.jpg
```

## References

- Fluent SplitButton
- Material 3 split button
- SwiftUI `Menu` + `Button` 组合
