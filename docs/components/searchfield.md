# SearchField

统一搜索输入。复用 `TextField` 的 chrome、光标/选择/IME 和 clear action，在前导槽放入搜索图标，并在字段下方提供可选的联想结果。

## Anatomy

```
┌─────────────────────────────────────┐
│  ⌕  Search components…           ×  │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│  Camera                             │
│  Canvas                             │
└─────────────────────────────────────┘
```

- **leading icon**：`TextField` 的装饰性前导图标，不参与命中
- **field**：常规 `TextField`，保留 clear、焦点、IME 和文本缩放
- **suggestions**：字段下方的行列表；当前高亮行使用 `stateLayerSelected`
- **clear**：`TextField` 的 clear affordance，仅在有文本且聚焦时出现

## API

```swift
@State private var query = TextBuffer("")

SearchField(
    text: $query,
    placeholder: "Search components",
    suggestions: ["Camera", "Canvas", "Counter"],
    onSubmit: { print("submit", $0) },
    onSuggestionSelected: { print("select", $0) }
)
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `text` | 必填 | `Binding<TextBuffer>` |
| `placeholder` | `"Search"` | 占位文本；语义 label 固定为 `"Search"` |
| `suggestions` | `[]` | 候选列表；按输入做大小写不敏感包含过滤 |
| `isEnabled` | `true` | 禁用字段和联想 |
| `clearsOnEscape` | `true` | Escape 清空查询 |
| `onSubmit` | `nil` | Return 且无高亮候选时提交当前文本 |
| `onSuggestionSelected` | `nil` | 选择候选后回调（文本已写回） |

底层 `TextFieldDecoration.leadingIcon` 也可单独用于其他字段；它是装饰性的，不改变命中测试。

## Sizing

- 字段高度沿用 `TextField` 的 size（regular 32pt；触摸命中仍由 TextField 提升到 44pt）。
- 联想行使用 `SuggestionRowStyle` 填满字段宽度，文本左对齐；触摸命中由 `Button` 的 44pt 下限保证。
- 联想列表与字段间距 4pt，外层圆角/边框使用 `controlRadius` / `border`。
- 窄宽下字段和联想列表随父宽收缩；长候选单行显示，不把字段撑出容器。

## Tokens

| 槽位 | 来源 |
| ---- | ---- |
| 字段背景/边框 | `TextField` 默认 chrome |
| 搜索图标 | `theme.inputs.addonForeground`（与 clear 图标一致） |
| 联想背景 | `surfaceFloating` |
| 高亮行 | `stateLayerSelected` |
| hover 行 | `stateLayerHover` |
| 边框/圆角 | `border` / `controlRadius` |

## States

| 状态 | 行为 |
| ---- | ---- |
| 空 | 无联想；显示 placeholder |
| 输入 | 过滤候选；默认高亮第一项 |
| ArrowDown / ArrowUp | 在候选中循环移动高亮 |
| Return | 有高亮时选择候选；否则调用 `onSubmit` |
| Escape | `clearsOnEscape` 时清空文本并隐藏联想 |
| 选择候选 | 写回文本、隐藏联想、调用 `onSuggestionSelected` |
| clear | 清空文本并清除高亮 |
| disabled | 字段不可编辑，不显示联想 |

## Behavior

- **指针**：点击候选行选择；点击字段聚焦；clear 由 TextField 处理。
- **键盘**：ArrowUp/Down、Return、Escape 由字段的 `onKeyDown` 统一处理；Return 不会先插入换行。
- **辅助功能**：字段 role=textField、label=`Search`；候选是普通 button，名称即候选文本。
- **IME**：沿用 TextField 的组合输入；Escape 在组合期间仍由字段处理，调用方可用 `clearsOnEscape: false` 保留默认取消行为。
- **联想位置**：内联在字段下方，不依赖 Portal；软键盘出现时由外层滚动容器保证结果可达。

## Authoring rules

- 搜索语义用 `SearchField`，不要再用 `TextField` 自行拼图。
- 候选过滤默认大小写不敏感包含；需要远端结果时，在 `onChange` 之外维护候选数组，不要在一次 body 中发请求。
- 不要把候选做成唯一入口；提交和 clear 必须独立可用。
- 联想列表较长时由调用方限制 `suggestions` 数量或外层滚动；组件不虚拟化候选。
- 需要全局快捷键（Cmd/Ctrl+F）时由应用绑定，组件不注册全局键盘。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/SearchFieldTests.swift`）：

- `escapeClears`：Escape 清空文本。
- `suggestionSelection`：ArrowDown 移动高亮，Return 选择并写回。
- `submit`：无高亮候选时 Return 提交当前查询。

Gallery `searchField` 页提供输入、候选过滤、选择与提交；`AdaptiveControlExamples` 提供 390/720/390-touch 预览。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component searchField --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"textField","visible_only":true,"limit":10}'
guava-dev devtools input-ui 9229 --click-node <Search>
guava-dev devtools input-ui 9229 --input '[{"kind":"text","text":"Ca"}]'
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'   # Camera / Canvas
guava-dev devtools input-ui 9229 --input \
  '[{"kind":"keyDown","key":"ArrowDown"},{"kind":"keyDown","key":"Enter"}]'
guava-dev devtools capture-ui 9229 /tmp/guava-search.jpg
```

## References

- SwiftUI `.searchable` / `SearchField`
- Flutter `SearchBar` / `SearchAnchor`
