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
