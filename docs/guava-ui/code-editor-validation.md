# 真实代码编辑器验证

日期：2026-10-07。示例使用生产 `ScriptCodeEditor`、Rope `TextBuffer`、后台 Tree-sitter Swift grammar 和真实 SourceKit-LSP。入口：

```sh
swift run --package-path Editor EditorApp --script-editor-demo
```

示例使用独立临时项目与内存偏好设置，不加载用户项目。Reset sample 恢复带类型错误和待补全成员的 Swift 示例；Load 200,000 lines 加载真实 200K 行文档，Middle 跳到中部。Ctrl+Space 请求补全，F1 请求光标处文档，Escape 关闭浮层。Completion 按钮只定位最后一行；候选由语言服务提供。

## 原生输入与性能

测试机器为 MacBookAir10,1、8 GiB、arm64，macOS 27.0.1（26A434）、Swift 6.4。运行 Debug 构建，窗口 drawable 为 2560 × 1496 像素，FIFO present。FPS 测试显式启用连续 displayRefresh 帧驱动；正常示例仍按事件驱动，空闲时不以连续帧率衡量性能。

在第 100001 行末尾添加注释后，通过原生输入事件逐字输入 357 个字符，持续 30.180 秒。输入使代码行超出视口，文本自动横向滚动，行号 gutter 保持固定，光标始终在可编辑区域内。

| 指标 | 结果 |
| --- | --- |
| 输入期间一秒采样窗口 | 28 个，排除首尾各一秒 |
| FPS 最小 / 中位数 / 最大 | 57.5 / 59.8 / 60.6 |
| 采样帧数 | 1684 |
| layout 帧加权均值 | 1.280 ms |
| draw 帧加权均值 | 1.252 ms |
| present 帧加权均值 | 0.510 ms |
| EditorApp RSS 最小 / 中位数 / 最大 | 300.8 / 302.6 / 308.1 MiB |

这些是运行时一秒窗口统计，**不是逐帧 p99、键盘到显示延迟或系统合成器掉帧统计**。RSS 只涵盖 EditorApp，不涵盖 SourceKit-LSP、Instruments 或 UI 自动化进程。该场景验证了大文档中部连续输入时渲染提交没有持续塌陷，不能作为与 GPUI Kit 的性能等价证明。脱敏采样保存在 [JSON 证据](evidence/code-editor-200k-native.json)。

连续输入结束后撤销恢复该批字符之前的 Rope 根；随后连续五轮重做/撤销并再次重做，文本、光标和横向滚动都正确恢复。检查后的 EditorApp RSS 为约 199.4 MiB，没有随着这几轮操作单调增长；这不替代长期内存泄漏测试。

复现性能记录时设置：

```sh
GUAVA_FPS_LOG=1 GUAVAUI_FORCE_CONTINUOUS_FRAMES=1 \
  swift run --package-path Editor EditorApp --script-editor-demo
```

以原生 `.app` 启动时，可显式设置 `GUAVA_SCRIPT_EDITOR_DEMO_LOG_PATH` 保存 stdout/stderr。该可选路径仅用于 demo 的日志记录。记录一次连续输入，按实际输入开始/结束时间切分日志；不要将 mailbox 的无节流提交次数当作屏幕刷新率。

## Instruments 检查

同一次原生测试附加 Time Profiler，记录 40 秒，完成保存后导出 `time-profile` 表。按完整栈中的 `ts_parser_parse*` 统计，26,654 个解析采样全部来自 worker，主线程解析采样为 0。这次采样证明解析工作离开 UI 线程；26.654 秒的 worker 采样权重也说明 Swift grammar 在这个输入场景仍会产生较重的解析工作，不能宣称每次编辑只解析一行。

主线程的 11 个 `TextBuffer.stringValue.getter` 采样均来自 AppKit 的 accessibilityValue 查询：`TextField.updateAccessibilityValue` 的延迟 provider → `Node.resolvedAccessibilityValue` → `MacSceneAccessibilityElement.accessibilityValue`。没有发现逐键绘制路径物化全文的采样。Time Profiler 是统计采样，不能证明从未出现未采到的调用。

解析增量读取的可控测试另有证据：200K 行数字修改在首次语法上下文更新后，后续编辑约读取 153 字节。第一次局部修改仍可能读取约 2.98 MB；初次解析遍历全文。worker 合并未处理的缓冲区根、丢弃旧结果，避免把解析时间直接转移到 UI。

## 真实语言服务 UI

已在原生窗口确认以下行为：

- SourceKit-LSP 初始化为 ready，样例的类型错误和不存在成员出现真实诊断波浪线与消息。
- `message.` 的真实候选弹窗有约 200 项；输入 `up` 后过滤到两个 `uppercased` 候选。Up/Down 切换，Tab 插入 `message.uppercased()`；Escape 关闭。选中底色铺满候选行，类型说明沿右侧对齐。
- 在 `greet` 标识符处按 F1，浮层显示服务器返回的 `func greet(name: String) -> String` 和示例中的文档说明；Escape 关闭。这里只记录了键盘 hover 的原生操作证据，指针 hover 的触发路径另有自动化覆盖。
- 大文档中部输入时语法颜色更新，横向滚动、固定行号、撤销/重做与可见光标保持一致。

自动化覆盖 Rope 随机 Unicode 编辑/接缝、三索引空间、200K 行可见窗口 shaping、IME、undo 根恢复、Tree-sitter 子树复用/异步旧结果丢弃、LSP UTF-16 增量同步、补全过滤与原子额外编辑、诊断几何、hover 锚点和实际事件分发。

## 语言服务进程生命周期（2026-10-08）

此次补测暴露了旧实现中的真实缺陷：语言服务器已经退出，编辑器页脚仍显示 ready，查询只返回空结果。进程退出、管道 EOF 和协议错误现在会向工作区发布失败状态；传输按同一连接的事件流处理 stdout 字节，旧连接的迟到回调不能关闭新连接。UI 状态更新带递增版本和工作区会话标识，关闭工作区后旧启动/诊断回调不能恢复 ready。

意外中断后最多自动重连三次，等待时间分别为 0.5、2、5 秒；正常运行满 30 秒后重置尝试次数。重连通过 didOpen 发送最新未保存的缓冲区，期间的编辑也保留在文档会话中。达到上限后显示失败原因和 Retry；手动重试重新开始会话。主动关闭不触发恢复，初始化期间关闭直接中断请求，不等 30 秒超时。Dismiss 只隐藏消息，保留真实失败状态。

原生生产示例已操作验证：

- 初始真实诊断为两条；将第 8 行改为 `let count: Int = 42` 后，类型错误消失，仅保留末行成员名错误。
- 主动终止该示例的 SourceKit-LSP 子进程，新服务器自动启动；未保存的 `42` 保持不变，F1 再次返回 `greet` 的函数签名和文档。
- 重连后 Ctrl+Space 返回成员候选，输入 `up` 后收窄，Tab 插入 `message.uppercased()`，诊断清零。
- 连续终止四个会话（初始及三次自动重连）后，不再产生服务器进程，界面显示退出原因和 Retry LSP；使用重试入口后恢复 ready，完整的未保存代码保持不变。

可控子进程测试覆盖碎片化消息的有序交付、无待处理请求时的意外退出、最新根重开、backoff 期间停止、三次重试上限及手动恢复、初始化期间取消。工作区测试覆盖错误提示的关闭、重试与关闭后迟到回调。原生记录见 [LSP 生命周期证据](evidence/code-editor-lsp-lifecycle-native.json)。这不是跨平台或长期断线稳定性验证。

## 剩余边界

- 特别长的单一逻辑行仍完整 shaping，尚未水平分段；横向宽度来自已访问窗口，未扫描全篇最宽行。
- 软换行未访问行的高度以一行估计，访问后校正。编辑器还缺搜索/替换、多光标、折叠、完整 snippet tab-stop 导航等上游能力。
- 尚未完成跨平台 IME、长时间内存、跨平台语言服务恢复和所有诊断更新路径的原生验证。
- 当前证据不能证明 GuavaUI 编辑器已经达到 GPUI Kit 的成熟度；组件画廊覆盖和产品组件缺失清单仍以[逐项审计](gpui-kit-audit.md)为准。
