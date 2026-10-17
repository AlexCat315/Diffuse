# CommandPalette

命令搜索面板。搜索、排序、分组和键盘选择是主体；结果列表只挂载视口与 overscan 内的行，不再随命令总数线性创建视图。

## Anatomy

```
┌──────────────────────────────────────┐
│  [ GO                            × ] │
├──────────────────────────────────────┤
│  ▌ Go to File              ⌘P        │
│    Go to Line              ⌘G        │
│                                      │
│  ↑↓ navigate  ↵ run  esc close  2 of 8│
└──────────────────────────────────────┘
```

- **search**：唯一 Tab 停靠点；输入即过滤
- **results**：虚拟化列表，行高 36，分组标题 28
- **highlight**：键盘/指针共用的选中行；Enter/点击执行
- **footer**：快捷键提示与 `visible / total` 计数

## API

```swift
CommandPalette(isPresented: $open, items: [
    CommandItem("Toggle Theme", group: "View", keywords: ["dark"], shortcut: .primaryShift("L")) { toggle() },
    CommandItem("Go to File", group: "Navigate", shortcut: .primary("P")) { goToFile() },
])
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `isPresented` | 必填 | 面板开关 |
| `items` | 必填 | `CommandItem` 集合；`id` 必须稳定唯一 |
| `placeholder` | `"Type a command…"` | 搜索占位 |
| `emptyTitle` / `emptyMessage` | 内置 | 无结果空态 |
| `configure` | `{ _ in }` | 配置闭包（保留） |

`CommandItem` 包含 `title/subtitle/group/keywords/icon/shortcut/isEnabled/action`。

## Virtualization

- 结果通过 `VariableVirtualStack` 渲染：
  - 行高：header 28pt、item 36pt
  - `overscan = 3`
  - `scrollToIndex = highlightedEntryIndex`，键盘移动后自动显露
  - 结果容器 `width: 100%`，行与选中背景铺满
- 内容高度由 `entry` 数量 × 行高精确计算；滚动定位 O(log n)。
- 只挂载视口 + overscan 的行；离屏行完全卸载。持久数据保留在 `items`，行的 transient hover/press 状态不需要跨视口保留。
- 测试：1000 条命令时挂载的 `Command` 行按钮 < 60。

## Sizing

- Modal 固定 640×440，`inset 72`，顶部放置。
- 搜索行、footer 固定；结果区取剩余高度。
- 行高不随结果数量变化；`VariableVirtualStack` 使用同一 `TextScaler` 测量。
- 手机：固定 440 与行预算仍是已知限制；未做软键盘/窗口高度自适应。

## Tokens

| 槽位 | 来源 |
| ---- | ---- |
| Modal 背景/边框 | `Modal` 默认 surface |
| 选中行 | `accent × 0.16` + accent 边框 |
| hover/press | `stateLayerHover` / `stateLayerPressed` |
| 标题/快捷键 | `onSurfaceMuted` / `KeyCap` |
| 空态 | `EmptyState` compact |

## States

| 状态 | 行为 |
| ---- | ---- |
| closed | 不挂载结果；下一次打开重置 query/highlight |
| open | 搜索框聚焦；首项选中 |
| typing | 重新排序/分组；highlight 回到首项；结果滚动由 `scrollToIndex` 维持 |
| ArrowUp/Down | 循环移动；PageUp/PageDown 跳 10 项 |
| Return | 执行当前项并关闭 |
| Escape | 关闭 |
| pointer | hover 更新 highlight；点击执行 |
| disabled item | 跳过键盘选择；仍显示为弱化行 |
| no results | 显示 EmptyState |

## Behavior

- **键盘**：搜索框始终持有焦点；方向键/Page/Return/Escape 被面板消费，不移动光标。
- **指针**：点击行执行；hover 只更新 highlight，不执行。
- **辅助功能**：每行 role=button、label 为 title、help 为 subtitle；footer role=group；搜索框为唯一 Tab 停靠。
- **分组**：query 为空时按 group 插入 header；有 query 时不显示分组标题，结果按匹配度排序。
- **Portal/Modal**：沿用 Modal 的焦点约束、backdrop 与关闭后焦点还原。

## Authoring rules

- 命令集合大（数百到数千）时直接用 `CommandPalette`；不要自己先构造全量行视图。
- `CommandItem.id` 必须稳定且唯一；虚拟化按 id 复用/回收行。
- 不要把高频变化的临时状态放进 `CommandItem`；它是搜索数据，不是行状态。
- 需要最近使用记录/自定义 footer 时在应用层扩展 `items` 顺序；组件暂未内置。
- 排序/过滤由 `CommandSearch` 统一负责；不要在调用方预排序后假设面板保留顺序（无 query 时保留传入顺序）。

## Verification

单元测试：

- `ProductInteractionRegressionTests.commandInput`：真实搜索输入、跳过 disabled、PageUp/PageDown、Return 执行。
- `ProductInteractionRegressionTests.commandVirtualization`：1000 条命令挂载行 < 60。
- `FeedbackComponentTests` 覆盖排序/分组投影。

Gallery `commandPalette` 页提供 8 条命令、分组、快捷键、禁用项与 `Last run`。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component commandPalette --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Open command palette","visible_only":true}'
guava-dev devtools input-ui 9229 --click-node <Open command palette>
guava-dev devtools input-ui 9229 --input '[{"kind":"text","text":"GO"}]'
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Go to File / Go to Line
guava-dev devtools input-ui 9229 --input \
  '[{"kind":"keyDown","key":"ArrowDown"},{"kind":"keyDown","key":"Enter"}]'
guava-dev devtools capture-ui 9229 /tmp/guava-palette.jpg
```

## References

- VS Code Command Palette
- macOS Spotlight
- SwiftUI 无内置命令面板（List + searchable 组合）
