# 滚动、布局与 Workspace 原生验证

日期：2026-10-12。代码基线与构建 SHA256、测试计数及限制见 [validation.json](validation.json)。这份记录区分确定性测试、原生输入与几何验证、原生计时和绘制列表回放。

## 环境与计时口径

Apple M1 MacBook Air（MacBookAir10,1），macOS 27.0.1，60Hz；窗口 1280×720 逻辑点、drawable 2560×1440、2× 密度、4× MSAA，Demo 的 NativeRHI device validation 仍启用。所有场景均为 40 行 ScrollView 和同一 72 项画廊导航，计数均为 **1,328 个节点**；离屏剔除没有把普通 ScrollView 改成虚拟列表。

测量期间只有一个 Demo，无 Swift 构建或测试同时运行。脚本先预热，再产生 12 组交替方向的滚轮事件；每组 10 次输入、间隔 16ms。DevTools 注入要求 mirror 订阅，脚本停止 mirror 并丢弃 3 帧后才开始计时，避免回读图像的开销。每组收集最多 65 帧，下一轮输入前最多等待 1.5 秒，因此慢场景样本数较少，窗口包含惯性减速及可能的结束后空闲帧；**不包含 live input 期间的计时**，不是恒定速度、等时长的滑动实验。

- `layoutMs`：布局函数的 CPU 墙钟时长。
- `drawMs`：从布局结束到绘制结束，**还包含 NativeAccessibility 同步和 DevTools overlay**，不能当成纯粹 renderer 函数的耗时。
- `presentMs`：图集上传及 NativeRHI 编码/获取目标/提交/present 的 CPU 墙钟时长，不能直接解释成 GPU 时间或 GPU 等待。
- `totalMs`：Demo 帧内测量的总 CPU 墙钟时长，不包含整个事件循环。
- `arrivalIntervalMs`：客户端收到连续 timing.frame 消息的间隔，**不是合成器显示时间戳，也不是 input-to-photon 延迟**。

下表单位均为 ms。420/549/780 是计时帧数；间隔样本数每轮少一项。全部样本的 presented 为 true。

| 场景与原始报告 | 帧数 | 批次数 | draw P50 | total P50 | 到达间隔 P50 | 到达间隔 P99 | 到达间隔最大 | >33.34ms 次数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [修改前 Debug，旧全树路径](before-debug.json) | 420 | 323 | 14.75 | 34.51 | 41.60 | 44.05 | 44.75 | 402 |
| [中间验证 Debug，旧全树路径](after-debug-legacy.json) | 549 | 323 | 13.05 | 30.09 | 31.99 | 33.83 | 37.44 | 20 |
| [中间验证 Release，旧全树路径](after-release-legacy.json) | 780 | 323 | 5.01 | 15.01 | 16.67 | 17.24 | 17.75 | 0 |
| [最终 Debug，保留图层路径](after-debug.json) | 780 | 83–85 | 4.55 | 19.18 | 20.92 | 22.29 | 40.95 | 2 |
| [最终 Release，保留图层路径](after-release.json) | 780 | 83–85 | 4.16 | 14.94 | 16.68 | 17.52 | 24.79 | 0 |

Debug 仍超过 16.67ms 预算，且有 2 次客户端到达间隔超过 33.34ms。最终 Release 的 total P95 为 15.37ms、P99 为 15.52ms、最大 15.91ms；到达间隔 P95 为 17.24ms，最大为 24.79ms。该场景的节奏接近 60Hz，但 CPU 余量有限。没有 GPU completion/compositor 时间戳，不能把这组数据写成“所有滚动不掉帧”。

初次原生验证发现 Demo 始终用 NodeRenderer，未消费 AppRuntime 已有的保留图层路径：中间报告仍是 323 批。最终 Demo 默认改用 LayerAwareNodeRenderer，继承 pixelScale，并跳过离屏缓存叶子。保留中间报告以说明接线缺陷及测量过程。修改前 Debug 是会话中保留的旧进程，二进制路径后来被构建覆盖；没有嵌入 revision 或旧可执行文件哈希。各组按顺序运行，机器温度、电源/后台系统活动没有实验级控制；不能把差值全部归因为一个改动，也没有同负载 GPUI Kit/Motrix 原生对照。

## 原生中断与 Workspace

[scroll-interruption.json](scroll-interruption.json)：在原生 Debug Demo 中注入滚轮和点击，再读实际 ViewGraph；两种点击后的偏移在 1000ms 后保持完全一致。quiet window 内取消分支另有可控时钟的 ScrollAnimator 回归。树序列化和 socket 往返会增加延迟，因此本验证不提供原生设备 phase 或停止延迟的保证。

[workspace-geometry.json](workspace-geometry.json)：实际窗口输入与 JSON 保存/恢复，所有阶段工作区为 935×360pt，内部中心区为 692×360pt：

| 阶段 | 分隔柄 y | 工作区高度 |
| --- | ---: | ---: |
| 初始 | 503 | 360 |
| Save layout 后向上拖动 50pt | 453 | 360 |
| 焦点分隔柄 ArrowDown | 460 | 360 |
| Restore 保存的 JSON | 503 | 360 |

修复前同一拖动会把外层声明的 360pt 高度覆盖成 577pt；修复后局部重组保持外层尺寸。指针拖动、键盘调整和恢复均有真实事件/JSON 自动化回归。完整树快照以 `.tree.json.gz` 保存，摘要保留原始 SHA256；输入动作 JSON 同目录保存，坐标来自该窗口的实际树与图像。

以下 JPEG 是 **原生 Demo 的真实 DrawList 经已选渲染器离屏回放**，不是 OS 合成器截图，也不是帧率证据：

- [初始](workspace-initial.jpg)、[指针拖动](workspace-dragged.jpg)、[键盘调整](workspace-keyboard.jpg)、[恢复](workspace-restored.jpg)。
- 每张图旁的 `.json` 保存 DevTools hello、回放来源及图像元数据；完整树可解压查看。

## 复现

在仓库根目录构建并启动单个窗口，第二个终端运行采样。先退出其他 Demo/编译/测试，窗口保持 1280×720。

```sh
swift build --package-path GuavaUI -c release --product GuavaUIDemo --jobs 4
GUAVA_DEVTOOLS=1 GUAVA_DEVTOOLS_PORT=9244 GuavaUI/.build/release/GuavaUIDemo --component scrollview --benchmark
# 第二个终端：
swift scripts/record-scroll-timings.swift 9244 /tmp/guava-scroll-timings.json
```

当前代码的旧路径对照可在启动前增加 `GUAVAUI_LEGACY_RENDERER=1`；Debug 则换成 `.build/debug` 并省略 `-c release`。Workspace 用 `--component workspace`，依次 Save layout、拖动内部分隔符、箭头键、Restore。既有 `scripts/capture-editor-devtools.swift PORT OUTPUT.jpg` 也可对 Demo 取静态回放，其文件名不限制被测应用。

完整 GuavaUI 测试通过：Compose 586、Runtime 250、Gallery 7、Workspace XCTest 51、DevTools XCTest 10、App XCTest 24（其中 1 个 opt-in benchmark 跳过）；Runtime 另有 3 个既有 opt-in benchmark 未启用。Portable 运动测试 40 项、Editor 模型迁移 17 项通过；最终 Release 构建与 Editor 集成复测均通过。45 个本轮变更/新增 Swift 文件（含采样脚本）按结构检查规则无新增越界；整仓检查仍报告既有 AppDisplayHandle 29 个字段超过基线允许的 27 个，未修改该类型或放宽基线。

## 仍未证明/完成

真实鼠标/触控板单位、phase、OS momentum 的统一输入；系统偏好自动订阅、完整 RTL 和跨平台辅助功能；120Hz/Windows/Linux、长期内存、复杂大内容的滚动；通用可变行高虚拟布局。普通 ScrollView 的离屏绘制剔除不减少内容创建与布局，以上项目继续保留为缺口。NativeRHI 与辅助功能同步的细分性能仍需独立 profiler 证据。
