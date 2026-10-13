# Workspace 尺寸与布局契约验证（2026-10-12）

本轮实现与边界见 [审计续补](../../gpui-kit-audit.md#workspace-尺寸与通用布局续补2026-10-12)、[布局契约](../../../components/layout.md)、[Workspace](../../../components/workspace.md)、[可变行高](../../variable-virtual-layout.md) 和 [响应式候选布局](../../responsive-layout.md)。实现位于 `3f77f0a2`，本次验收另修正通用 Menu 长标题换行。

## 原生检查口径

运行 macOS arm64 的 `GuavaUIDemo --component layout` / `--component workspace`，窗口逻辑尺寸 1280 × 720、内容比例 2。通过现有 DevTools `mirror.input` 注入 pointer、key 和带 phase 的 wheel，实际走应用事件分发与状态重组。JPEG 来自该窗口实际 draw list 经所选渲染器离屏重放，**不包含操作系统 compositor**。这是原生程序内的交互与绘制检查，不是触控板或屏幕帧时间测试。

每张图片的同名 JSON 保留捕获元数据，`.tree.json.gz` 保留当时完整布局树；[validation.json](validation.json) 提取关键帧、滚动偏移和虚拟容器挂载数量。100K 数据量不意味着构建 100K 个视图。

| 场景 | 观察与证据 |
| --- | --- |
| Workspace 100% | [初始尺寸](workspace-100.jpg)，使用面板 preferred 初始化，保留 Editor/Preview 内容 |
| Workspace 200% 标签 | [End 选中末尾标签](workspace-tabs-200.jpg)；点击标签取得焦点，横向 offset 为 494；溢出/最大化/折叠动作仍在区域内 |
| Workspace 200% 溢出菜单 | [完整长标题换行](workspace-menu-200.jpg)，复用通用 Menu 的键盘焦点、动态行高和显露逻辑；快捷键/分隔线与 End/Home 由真实字体测试覆盖 |
| 外部拆分与持久化 | 点击外部调整柄后 End 达到 340pt，Home 达到 180pt；保存 180pt、调整到上限后 Restore 回到 180pt，数值见 validation.json；辅助功能 slider 角色、增减和相同约束由 WorkspaceViewTests 验证 |
| 内容测量 Grid 200% | [固定/弹性列和内容行高](grid-200.jpg)；窄的固定列自然换行，下一行按上一行最高内容定位 |
| 候选布局 | [100% 横排](candidates-100.jpg)、[200% 窄幅竖排](candidates-200.jpg)；修复自然尺寸重新约束导致的末字换行，真实字体回归覆盖 100%/200% × 620/180pt |
| RTL / insets | [200% 暗色 RTL](rtl-dark-200.jpg)；leading/trailing 顺序和非对称宿主 insets 镜像，嵌套 SafeArea 不重复消费 |
| 可变行高 100K | [200% 定位第 50,001 项](variable-reveal-200.jpg)，offset 为 5,499,858；该快照仅挂载 10 项、24 个子树节点，包含 overscan；字体缩放、数据变化与稳定 ID 锚点另由测试覆盖 |
| LazyGrid 100K | [200% 滚动至第 50,001 单元格附近](lazy-grid-200.jpg)，offset 为 1,300,000；仅挂载 36 个单元格、67 个子树节点，包含 overscan |

## 自动化覆盖

- `swift test --package-path GuavaUI --jobs 4`：完整包回归通过，Compose 624、Runtime 259、Workspace 59；另有其他目标及 4 项显式跳过的可选测试。覆盖 Workspace 尺寸/Codable/复位、外层 pointer/key/辅助功能、200% 标签导航、自定义布局失效和嵌套、Grid 轨道、100K LazyGrid/VariableVirtualStack、响应式布局与真实字体、多行 Menu。原始日志见 [GuavaUI](guava-ui-tests.log.gz)、[Portable](portable-tests.log.gz)、[Editor](editor-workspace-tests.log.gz)，汇总见 [test-results.json](test-results.json)。
- `swift test --package-path GuavaUI/Portable --jobs 4`：81 + 10 + 5 项通过，覆盖底层布局/绘制所有权与桥接。
- `swift test --package-path Editor --filter 'WorkspacePresetRegressionTests|AuthoringWorkspaceTests'`：8 项、2 组通过，涵盖 8 个预设真实字体渲染、布局持久化和 Agent docking。该 UI suite 补 `@MainActor`，避免 cooperative worker 的小栈耗尽，并与应用 UI 生命周期一致。
- `git diff --check` 通过。本轮布局与验收修正的 40 个 Swift 文件没有新增结构阈值违规或扩大已有超限类型。仓库全量 maintainability guard 仍报告两个未由本轮修改的既有超限：RenderSettings 初始化参数 19（基线 18）；AppDisplayHandle 存储字段 29（基线 27），没有抬高基线。

## 性能与未完成边界

自定义测量每子视图最多缓存四组 proposal，脏子树跨自定义容器边界失效；每个子视图复用 Yoga 测量探针。Grid 的 adaptive 轨道使用紧凑分组，避免按极大列数分配数组。LazyGrid 固定行定位 O(1)、可变行累计索引定位 O(log n)；VariableVirtualStack 使用 Fenwick 索引，普通滚动不重新测量全部数据，数据/宽度/字体等测量输入变化时 O(n) 同步。

没有在此记录中给出 FPS 或上游性能等价结论。浮动面板仍属于宿主窗口，独立系统窗口/跨窗口拖放未实现；未知高度自动估测、横向二维窗口化、span、GeometryReader、container query、多套内容 ViewThatFits、平台自动 SafeArea 和完整组件 RTL 仍未完成。辅助功能语义测试不等于完整跨平台辅助技术验收。
