---
path: /zh/docs/architecture/ui-frame-performance
title: 'UI 帧调度与性能验证'
description: '窗口帧调度、辅助功能快照与进度动画的性能验证'
locale: zh
translationKey: architecture/ui-frame-performance
category: architecture
order: 110
kind: doc
---

# UI 帧调度与性能验证

2026-10-21，在 Apple M1 / Metal、60 Hz、1280 × 720 逻辑分辨率（2560 × 1440 drawable）的 Debug Gallery 中，对 Progress / Spinner 页面采集 120 个真实窗口帧，预热 20 帧。页面包含 2667 个节点，镜像回读关闭。

| 指标 | 坐标遍历优化前 | 优化后 |
| --- | ---: | ---: |
| 提交帧率 | 33.91 FPS | 59.98 FPS |
| 布局阶段中位耗时（含原生辅助功能同步） | 22.27 ms | 3.05 ms |
| 整帧 CPU 路径 P95 | 30.84 ms | 9.73 ms |
| 成功提交帧 | 120 / 120 | 120 / 120 |

采样定位到辅助功能快照的坐标转换：旧实现对每个节点重新沿祖先链计算绝对变换。现在从快照根计算一次变换，向下传递子节点的位置、缩放和滚动偏移。子树快照仍支持位于任意祖先之下的根；裁剪、语义与懒加载值的行为保持一致。

桌面宿主先推进动画，再提交重组，以便动画产生的状态变化在同一显示回调绘制。动画注册按控制器身份去重，结束控制器在 tick 时统一清理，避免批量注册时反复扫描整个列表。关闭帧日志时不再格式化逐帧日志。

确定型线性与环形进度条共用节点拥有的显示值，以主题动效插值，只使绘制失效。首次显示、确定型与不确定型切换、禁用动画和减少动态效果时直接设置目标值。

复现命令（仓库根目录）：

```sh
./guava run GuavaUI/Examples --mac --devtools --no-open -- --component progress
./guava devtools GuavaUI/Examples timings /tmp/guava-progress.json 120 20
./guava test GuavaUI --no-parallel --filter 'Accessibility|MultiWindowSmokeTests|ProgressAnimationTests|AnimationController'
```

帧率来自真实窗口的提交事件流；耗时不包含 GPU 完成或系统合成器时间戳。此结果验证该 Gallery 页面，不代表所有 Editor 场景的帧率保证。Editor、复杂文本、视口和大型数据表应分别采样。

Editor 的 Debug 构建通过。使用 `GUAVAUI_FORCE_CONTINUOUS_FRAMES=1 ./guava run Editor --mac --devtools --no-open` 对启动窗口采集同样的 120 帧：132 个节点，60.00 FPS，整帧 P95 1.14 ms，120 帧均提交成功。该窗口未打开项目，不覆盖工作站或游戏视口负载。采样完成后关闭测试进程；环境变量仅用于本次命令。

## 项目工作区的后续优化

打开 CrystalRush 的临时副本，进入“玩法”工作区，开启连续帧诊断。临时状态目录复制现有布局并关闭 AI 接入，避免凭据交互影响采样；不修改原项目。该场景恢复一个编辑态实体，未启用脚本播放，属于工作区 UI 与静态视口验证。

本轮移除了三类重复工作：

- 构建一份外层容器缓存时，不再沿嵌套容器链同时建立多份平铺子树缓存；已有叶子缓存仍可复用。
- 原生辅助功能同步只写入发生变化的属性与子节点列表。输入可用性按实际节点树一次遍历，覆盖被语义快照省略的布局祖先；动作与焦点回调始终读取当前上下文。
- 文本框保留首次布局的滚动范围计算；稳定且未聚焦、未失效的字段复用布局结果，不反复计算 IME 光标。尺寸、样式、内容失效及焦点字段仍重新计算，显示状态不会进入持久化配置。

已采集的优化后工作区样本：1889 个节点，预热 60 帧后采集 180 帧，60.00 FPS，布局阶段中位 11.32 ms，整帧 CPU 路径 P95 14.06 ms，180 帧均成功提交。早期探索样本存在 AI 配置、文件树刷新等状态差异，不作为严格的性能倍率对照。

验证包括深层容器缓存数量与绘制一致性、缩放/裁剪/透明度、辅助功能增量同步及实时动作、文本输入、首次滚动范围、嵌套滚轮、焦点、IME 与 gutter。相关命令：

```sh
./guava test GuavaUI --no-parallel --filter 'LayerAwareNodeRendererTests|NativeAccessibilityTests|AccessibilityGeometryTests|ContainerOpacity|Animation'
./guava test GuavaUI --no-parallel --filter 'TextField|Gutter|Focus|Scroll'
```

最终复核：同一优化后进程的 300 帧稳态样本为 60.01 FPS，整帧 P95 13.40 ms、最大 13.53 ms，300 帧均成功提交。但前一段 180 帧样本出现了两次绘制尖峰（约 192 ms、224 ms），使该段事件流平均降至 51.88 FPS；其 P95 仍为 13.44 ms。后续稳态采样没有复现尖峰，尚未定位其触发条件，不能据此宣称已完全消除交互或初始化卡顿。探索性旧实现样本为约 55 FPS，但文件树刷新后多了 20 个节点，因此不将它用于精确倍率比较。

## 动态脚本场景（2026-10-22）

使用 CrystalRush 的隔离副本，信任并编译真实 Swift 游戏脚本，再进入播放。仅在临时场景参数中设置 `startMode=playing`、`duration=3600`、`startingHearts=20`，延长可采样时间；未强制连续帧。窗口仍为 Debug / Metal / Apple M1 / 60 Hz，启用 VSync，关闭镜像回读。运行时有 60 个实体、约 56 个可见网格、约 9 次 draw call；采样前后必须同时核对脚本 `phase=playing`、倒计时减少、渲染帧索引增加。

动态路径发现并处理了以下问题：

- 初始关闭的 `AnimatedVisibility` 在布局回调中把 `maxHeight` 从 0 改为 nil 再改回 0，导致整树永久布局失效。改为一次写入最终高度，并验证连续布局会收敛。
- 播放、实时预览和连续视口操作启用原生显示刷新节拍；停止后回到事件驱动。关闭 VSync 时尊重显式的非限速选择。节拍状态去重，避免每帧重新设置模式。
- 连续帧判断不再查询粒子列表：实时预览或播放本身已决定连续刷新，原查询不会改变结果。
- 真实游戏脚本每帧更新多个实体时，每次局部变换写入都会触发整场景世界变换传播。局部写入现在累计到世界空间读取、物理查询或脚本阶段边界。通用 `WorldTransform` 组件读取同样刷新；破坏、布娃娃、物理同步与渲染提取前保留正确传播顺序。
- 辅助功能快照直接向所属语义节点的子数组写入，避免无语义布局祖先层层复制数组；没有 `describedBy` 时直接使用首轮快照，不再重建整份语义树。

修复布局循环后、接入显示刷新节拍前，曾测得约 68.84 次提交/秒；该数值高于屏幕刷新率，不能当作实际显示 FPS。接入节拍后的动态基线样本（300 帧、预热 60 帧）为 50.40 次提交/秒，1662 节点，UI 路径 P95 6.30 ms。该阶段耗时不含游戏模拟和帧准备，不能据此判断完整动态帧预算已达标。

验证命令：

```sh
./guava test Editor --no-parallel --filter 'FrameCadenceTests|EditorViewportRenderGateTests'
./guava test Engine --no-parallel --filter 'ScriptTransformBatchTests|ScriptSpawning|ScriptRuntimeQueries|ScriptRuntimeLifecycle|CharacterController|Ragdoll|Destruction'
./guava test GuavaUI --no-parallel --filter 'Accessibility'
```

继续采样捕获到成对的约 215–220 ms 绘制尖峰。调用栈包含 CPU 圆角裁剪：每个三角形都会创建索引、顶点和坐标临时数组。裁剪现在先检查整批几何的包围盒；完全位于所有圆角遮罩内时保留原始索引直接返回。边界路径用标量计算三角形包围盒，并复用本批次遮罩轮廓，保留边缘插值及缓存几何的目标遮罩裁剪。验证：

```sh
./guava test GuavaUI --no-parallel --filter 'Rounded|Clip|LayerAwareNodeRendererTests|ContainerOpacity'
```

最终组合实现的动态样本为 600 帧、预热 60 帧，1581 节点、600 帧全部提交：UI 路径 P95 5.84 ms，布局阶段中位 3.96 ms、P95 4.12 ms，绘制峰值 151.21 ms，UI 路径最大 163.28 ms，提交事件流 48.83 FPS。此前同为 1581 节点、尚未优化圆角裁剪的 300 帧样本，绘制峰值为 219.57 ms、UI 路径最大 231.67 ms。不同长度采样不能用于严格的峰值下降倍率；当前仍能复现长帧，且提交率未稳定达到 60 Hz，不能宣称问题已完全解决。

运行时核对：最终播放开始时有 60 个实体、56 个可见网格，`remaining_seconds=3599.95`；后续仍为 `phase=playing`，倒计时减少、渲染帧索引持续增加。暂停检查中倒计时停止；视口允许少量收敛帧及已有的心跳刷新。所有结果均为提交事件与 CPU 路径测量，没有 GPU 完成或系统合成器时间戳。

## 辅助功能树遍历合并（2026-10-22）

Debug Gallery / Progress 页面，Apple M1 / Metal / 60 Hz / 1280 × 720 逻辑（2560 × 1440 drawable），2667 节点、97 批次，`--benchmark` 连续帧，关闭镜像回读，120 帧采样、预热 20 帧，两次采样均 120/120 提交。

采样定位到布局阶段的全部耗时都在 `NativeAccessibility.synchronize`：`handleFrame` 的 221 个样本中有 220 个落在其中，且几乎平分为两次全树遍历——`inputAvailability(in:)`（103）与 `AccessibilityTree.snapshot`（109）。前者为每个带语义的节点写入一份 `[ElementID: Bool]` 字典，但只有真正生成元素的那部分节点会读取它。

现在输入可达性在同一次遍历里沿祖先链下传（`AccessibilityElement.acceptsInput`），桥接层不再单独遍历树、也不再建立该字典；`collect` 对语义的读取从两次降为一次。

| 指标 | 优化前 P95 | 优化后 P95 |
| --- | ---: | ---: |
| 布局阶段 | 4.82 ms | 2.67 ms |
| 绘制阶段 | 3.83 ms | 3.99 ms |
| UI 路径（布局 + 绘制） | 8.65 ms | 6.66 ms |
| 节点数 / 批次数 | 2667 / 97 | 2667 / 97 |

布局阶段下降 44.6%，UI 路径下降 23.0%，节点树与批次不变。样本计数同步下降：辅助功能同步在 `runFrame` 中的占比由 220/603 降至 134/521，`inputAvailability` 不再出现。

`presentMs` 与 `totalMs` 在同一二进制、同一参数下跨次采样波动可达数毫秒（本次 7.01–7.34 ms 与 2.77–3.12 ms 之间），受窗口遮挡与合成器状态影响，因此不作为本次对照指标；`totalMs` 的下降不可归因于本次改动。

复现与验证：

```sh
GUAVA_SWIFT_EXECUTABLE=/tmp/swift-nosandbox ./guava run GuavaUI/Examples --mac --devtools --no-open -- --component progress --benchmark
./guava devtools GuavaUI/Examples timings /tmp/before.json 120 20
swift test --package-path GuavaUI --disable-sandbox --filter 'Accessibility'
swift test --package-path GuavaUI --disable-sandbox --filter 'CompactLabel|ToolbarOverflow|GridColumns|ViewThatFits|SplitPresentation|ProductComponent|SectionedList|NavigationStack|CustomLayoutVisibility|Accessible'
```

结果：6 + 3 个辅助功能测试、52 个组件契约测试全部通过。

未解决：布局阶段剩余 2.67 ms 仍是同一次快照遍历（每节点一次 `CGRect` 运算、一次附件字典读取）。另外 `NodeTree.nodeCount` 在带 DevTools 计时时每帧被调用两次，各做一次全树遍历（采样约 43/521），只影响挂载 DevTools 的会话。

## 布局可见性改为节点存储属性（2026-10-22）

同一场景：Debug Gallery / Progress 页面，Apple M1 / Metal / 60 Hz / 1280 × 720 逻辑（2560 × 1440 drawable），2667 节点、97 批次，关闭镜像回读。本轮只改一个变量——`Node.isLayoutVisible` 由附件字典读取改为节点存储属性。

采样依据：辅助功能遍历栈中出现 `Node.isLayoutVisible.getter` → `Dictionary._Variant.lookup` → `__RawDictionaryStorage.find` → `String.hash(into:)`。该判断在快照遍历里每节点两次（可见性一次、`acceptsInput` 一次），绘制遍历里每节点一次，每次都要对 24 字节的字符串键做一次哈希。键 `GuavaUI.layout.visible` 只有 `Node+LayoutVisibility.swift` 一处读写，`attachments` 不存在整体拷贝，因此可以安全改为存储属性。

改动：`Node` 新增 `public internal(set) var isLayoutVisible: Bool = true`；`setLayoutVisibility(_:)` 写入该属性，仍然负责 `markRenderDirty` 与指针捕获/焦点释放；附件键删除。

静态（`--benchmark` 连续帧，每种实现各采样 2 次，取中位）：

| 指标 | 优化前 P50 / P95 | 优化后 P50 / P95 |
| --- | ---: | ---: |
| 布局阶段 | 2.73 / 2.80 ms | 2.57 / 2.64 ms |
| 绘制阶段 | 3.99 / 4.08 ms | 3.99 / 4.13 ms |
| 节点数 / 批次数 | 2667 / 97 | 2667 / 97 |

动态（事件驱动帧 + 240 个滚轮输入事件，120 帧 / 1.98 s）：

| 指标 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 布局阶段 P50 / P95 | 2.70 / 2.84 ms | 2.51 / 2.66 ms |
| 绘制阶段 P50 / P95 | 3.97 / 4.40 ms | 3.96 / 4.40 ms |
| 整帧 P50 / P95 | 15.32 / 15.66 ms | 15.26 / 15.61 ms |
| 提交帧 / 帧率 | 120 / 59.99 FPS | 120 / 60.14 FPS |

布局阶段静态降 5.7%（P95）、动态降 6.3%（P95）；绘制阶段、节点数与批次数不变。动态样本里绘制 P95 的 4.40 ms 来自滚动重绘，两种实现相同，说明本次改动不影响绘制路径的峰值。

一次误判需要记录：改动后首次连续帧采样读到 96 批次（改动前 97），曾怀疑可见性语义改变导致少合并一个批次。同一二进制改用事件驱动模式采样得到 97；回退代码重建复测 97，恢复代码重建复测也是 97。96 来自那个已运行数分钟、日志出现 `native display refresh unavailable` 的进程实例。批次数是环境敏感指标，A/B 必须同模式、同进程生命周期。

复现与验证：

```sh
# 静态
GUAVA_SWIFT_EXECUTABLE=/tmp/swift-nosandbox ./guava run GuavaUI/Examples --mac --devtools --no-open -- --component progress --benchmark
./guava devtools GuavaUI/Examples timings /tmp/static.json 120 20

# 动态：去掉 --benchmark，另开终端灌输入，与录制并行
./guava devtools GuavaUI/Examples timings /tmp/dynamic.json 120 20 &
./guava devtools GuavaUI/Examples input @/tmp/scroll.json

swift test --package-path GuavaUI --disable-sandbox --filter 'CustomLayoutVisibility|Accessible|Accessibility'
swift test --package-path GuavaUI --disable-sandbox --filter 'LayerAwareNodeRendererTests|ContainerOpacity|Hidden|Reveal|Animation|CompactLabel|SectionedList|GridColumns'
```

结果：4 个辅助功能/布局可见性测试、80 个渲染与组件契约测试全部通过。

未解决：布局阶段剩余约 2.5 ms 仍主要来自每次一整套全树辅助功能快照；`Node.accessibility` 每次读取仍是一次字符串键字典查询加一次结构体动态转换；`NodeTree.nodeCount` 在带 DevTools 计时时每帧做一次全树遍历。下一步应先判断"树未变化时跳过快照"能否成立，再决定是否值得继续拆快照本身。

## 写作模式文本编辑（2026-10-23）

本轮使用 CrystalRush 的隔离副本，实际打开写作模式并连续输入、移动光标、滚动源码；另外准备了含中文、英文和 emoji 的 1000 行普通文本。通过 `./guava run Editor --mac --devtools --no-open -- --project-dir …` 启动，独立状态目录关闭 AI 接入，不修改原项目。输入桥通过现有 DevTools 协议发送事件，每组 50 次操作、间隔 120 ms；录制覆盖操作期间的全部窗口帧。输入桥要求镜像订阅，本轮为 1 FPS，不能与关闭镜像的连续帧测试直接比较。

调用栈定位并修复了以下重复工作：

- 字体回退在每个字形簇上创建系统字体候选，包括主字体已支持的英文。现在先检查主字体，复用当前字号/字重的候选列表；列表仍无法覆盖时才查询 CoreText 系统回退。重新加载主字体时清空列表，保留中文字重与 emoji 回退行为。
- 缓存几何在位置和父遮罩均未变化时被重复裁剪。现在复用已裁剪结果；新增遮罩仍重新裁剪，发生位移时仍走原有路径。
- 完全位于遮罩矩形外的几何仍进行圆角多边形裁剪。现在先排除不可见索引，同时保留原始顶点供缓存边界判断；直边区域使用等价的矩形裁剪。
- 源码和缩略图重复查询相同偏移的语法颜色，未着色的位置也重复查树。加入最多 8192 项的瞬态缓存；文本版本和解析结果变化时清空，颜色仍按当前主题生成。
- 绘制循环每个字形都复制代码编辑配置。取色回调、诊断快照及淡化开关改为每次绘制读取一次。

初始动态样本（25 帧、约 1443 节点）UI 路径 P95 为 131.39 ms，布局 P95 47.26 ms、绘制 P95 68.05 ms。探索样本有窗口尺寸和响应式节点数差异，因此不计算严格优化倍率。最终复测固定为 1280 × 720 逻辑分辨率，仍是 Debug / Metal / Apple M1 / 60 Hz。这里的 CPU 路径不包含系统合成器或 GPU 完成时间，也不是端到端按键延迟。

验证命令：

```sh
./guava test GuavaUI --no-parallel --filter 'Rounded|Clip|LayerAwareNodeRendererTests|ContainerOpacity|Reveal'
./guava test GuavaUI --no-parallel --filter 'FallbackStyle|SystemFontInstance|ColorGlyph|TextTests'
./guava test GuavaUI --no-parallel --filter 'TextField|Minimap|RopeTextField|Diagnostic'
./guava test Editor --no-parallel --filter 'ColorCacheTests|TreeSitterHighlighterTests'
```

普通文本复测还定位到字体候选加载失败的重复路径：`loadFontFromCTFont → makeManagedFont → findFaceIndex` 在每个字符上重新读文件、扫描字体集合。现在在当前字体配置内记住失败的 PostScript 名称，并为已确定的样式栈/完整彩色 emoji 字形簇保留最多 1024 项选择；单个键最多 256 UTF-8 字节。重新加载主字体时重试失败项并清空选择；其他依赖上下文的系统回退继续即时查询。

最终普通文本复核：50 次实际输入，190 个窗口帧全部提交，1015 节点；布局 P95 **6.66 ms**、UI 路径 P95 **27.77 ms**、最大 **42.25 ms**。修复重复失败加载之前，同一份 1000 行文件的输入样本只有 11 个窗口帧，1015 节点，布局 P95 **710.21 ms**、UI 路径 P95 **732.31 ms**。前一段优化后录制的 UI 路径 P95 为 26.26 ms；本节以保留完整原始帧记录的复核段为准。两段编辑内容略有变化，不计算严格性能倍率。

最终源码输入样本：35 个窗口帧，约 1418 节点；布局 P95 **8.57 ms**、绘制 P95 **41.79 ms**、UI 路径 P95 **62.10 ms**。上下各移动 25 次光标，91 个窗口帧，UI 路径 P95 **64.36 ms**、最大 **75.51 ms**。仍有明显的源码绘制/重组开销，尚未稳定达到 60 Hz。本轮 UI 路径只统计窗口布局、辅助功能同步、绘制和提交，不包含独立的事件分发、重组和语言服务请求耗时。

最终源码滚动复核：50 次滚轮事件，276 个窗口帧全部提交；UI 路径 P95 **52.11 ms**，最大 **340.12 ms**，其中一次布局阶段为 296.53 ms。修复失败字体重复加载前曾录到约 2.22 秒峰值；当前复核没有复现该秒级绘制峰值，但仍有明显滚动长帧，尚未完全解决。最终源码输入与光标录制也均全部提交。
