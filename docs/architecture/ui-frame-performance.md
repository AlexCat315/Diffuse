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
