# Combobox

`Combobox` 是可搜索的类型化单选：触发器显示当前选项，弹层里是搜索框和结果列表。值来自 `Binding<Value?>`；查询、高亮和弹层状态是瞬时状态，不写入值。不需要搜索时用 `Select`。

## 两种数据源

本地列表在组件内按每个空白分隔的词做不区分大小写的匹配（支持中文等 Unicode 标签）：

```swift
Combobox(selection: $city, options: cities) { $0.placeholder = "Choose a city" }
```

远程结果交给 `ComboboxSearch`，调用方的数据层只负责把查询映射成选项：

```swift
Combobox(selection: $airport, selectedLabel: airport.map(\.name),
         search: ComboboxSearch { query in try await api.airports(matching: query) }) {
    $0.placeholder = "Choose an airport"
}
```

组件负责请求的完整生命周期：

| 情况 | 行为 |
| --- | --- |
| 打开弹层 | 立即用空查询请求；远程数据可能变化，所以每次打开都刷新 |
| 输入 | 停止输入 `delay`（默认 250ms）后才请求；之前的请求被取消 |
| 加载中、尚无结果 | 显示 Searching… 和转圈 |
| 加载中、已有结果 | 旧结果原位变暗保留，弹层高度不跳动 |
| 失败 | 显示错误的 `errorDescription`（或通用文案）和 Retry |
| 少于 `minimumQueryLength` | 提示需输入的字符数，不发请求 |
| 无结果 | 显示 `emptyText` |
| 关闭弹层或组件卸载 | 取消在途请求 |

只有最新一代请求可以发布结果，慢响应不会覆盖后续查询；重复的值只保留第一个。结果在宿主 UI 线程（`UIWorkSchedulerHolder`）发布；没有运行中的宿主时显示失败状态，不在任意线程改状态。当前值不在已加载结果中时，触发器依次使用：结果里的标签、本次会话最后提交的选项、调用方提供的 `selectedLabel`。

## 键盘与辅助功能

Up/Down 在可用结果间移动高亮，Return 提交高亮项（无高亮时提交第一项），Escape 关闭。触发器为 comboBox 角色，名称为当前标签；状态行是 status 角色，刷新中的列表带 “Updating results” 说明。

## 布局

触发器宽度为 `presentation.width`（默认 280，下限 120），未选中时也填满该宽度，chevron 和清除按钮贴在尾缘。弹层宽度与触发器一致，列表最多显示 `maxVisibleRows` 行，行高随字号缩放，触摸时取 44pt 下限。

## 验收

`ComboboxSearchTests` 覆盖取代与取消、防抖只请求最后一个查询、失败后强制重试、最小长度、无宿主与配置夹紧。`DesignSystemTests.remoteCombobox` 经真实事件派发验证：打开即请求并显示 Searching…，结果到达后显示列表，输入过滤，键盘提交，弹层关闭后触发器保留所选标签。`ChromeRegressionTests.emptyComboboxTrigger` 验证未选中触发器填满 280pt。

DevTools 在 1280 Gallery `--component combobox` 的 Remote results 示例中：点击后 `--capture` 截到 Searching…；输入 “fra” 时旧结果变暗，约 600ms 后变为 FRA、SFO；输入 “offline” 显示错误和 Retry。镜像确认本地与远程触发器左对齐、等宽，chevron 贴在尾缘。
