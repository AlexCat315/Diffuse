# 原生滚动输入协议与重复惯性修正

日期：2026-10-12。代码基线为 c19d5303。本页记录后续修正，前一次计时仍保存在 [历史证据](../scroll-layout/README.md)，没有用新口径覆盖旧数据。

## 代码与参考

旧路径把所有 wheel 交给 `ScrollAnimator.scroll(by:)`，相邻包停止旧运动，安静约 90ms 后又估算释放。原先 macOS 的 SDL 默认关闭 AppleMomentumScrollSupported，框架以静默推断接管了本应由系统提供的惯性；对于已含系统/驱动惯性的其他输入源，又缺少识别和避免二次起滑的能力。相邻输入会反复停/起，无法保证连续输入保持原来的速度。SDL macOS 将精确输入缩为 0.1，组件随后统一乘 30，也不能保证 1 个原生逻辑点只移动 1 点。这个机制有确定性回归；不能用此前的 post-burst 计时排除它。

本轮先阅读了两个本地参考仓库，并核对实际依赖版本：

- GPUI Kit 的 Cargo.toml 固定 `gpui-pre = 0.3.8`。该版本 [div.rs](https://docs.rs/crate/gpui-pre/0.3.8/source/src/elements/div.rs) 先调用 `pixel_delta(line_height)`，再直接累加 scroll offset。本地 `crates/base/src/scroll_bounce.rs` 对桌面默认关闭 bounce，启用时也明确要求 finger Ended 在 momentum 前出现。
- Motrix 的 go.mod 固定 `github.com/egoist/mygo v0.4.1`。该版本 [Darwin surface.go](https://github.com/egoist/mygo/blob/v0.4.1/internal/darwin/surface.go) 保留精确点输入，只对非精确行输入乘 40；[ui/input.go](https://github.com/egoist/mygo/blob/v0.4.1/ui/input.go) 的 `scrollBy` 直接累加并夹取。应用本身没有另一套静默后起滑的实现。
- 另读了当前 [Zed macOS events.rs](https://github.com/zed-industries/zed/blob/main/crates/gpui_macos/src/events.rs)，核对 Pixels/Lines、原始 scrollingDelta 与 touch phase 的设计。这是额外参考，不能当作 Kit 固定版本的代码。

GuavaUI 新增 typed `ScrollInput`，分别携带 points/lines/pages、精度来源、finger phase、momentum phase、单调时间戳。macOS 的 AppKit 观察器把原始数据以标记排进 SDL 事件队列，shell 跳过重复 SDL wheel，保留零位移结束/取消包。其他平台当前保持诚实的 unknown/none，不猜设备或释放。

平台输入统一走 `scrollDirectly(by:)`，不会再次估算释放，也不在连续包之间启动回弹。自定义手势仍可显式使用运动控制器的惯性/弹簧。Scrollbar thumb 使用绝对夹取，松开保持位置。ScrollView、DataTable、TextField、ViewportHost、Editor/游戏 wheel action、DevTools 浏览器输入与录制格式已同步迁移；InputRecording 为 version 2，没有旧格式解码层。

有 phase 的流保留实际消费者。点击、mayBegin、取消、失焦/最小化拦截旧 momentum；移除目标或 modal 接管不转交相邻/背景视口。新 began 可以立即反向开始。嵌套边界交接仍按完整事件处理，尚没有拆分一次大增量的残余距离。

## 原生 Demo 功能验证

[原始输入结果](native-input.json) 来自 Release 原生 Demo 的实际 ViewGraph offset，输入是 DevTools 注入的合成 phase 流。8 项通过：

- 精确输入 12.5pt，实际移动 12.5pt，不乘 wheelStep 或 Retina 密度。
- 16/130/150/16ms 的不均匀间隔后，位移仍等于已交付增量之和。
- 系统 momentum 结束后等待 1 秒，offset 保持 32.75pt，没有第二次 fling。
- 点击后剩余 momentum 不再改变 40.75pt 的 offset。
- 新的反向 began 立即将 offset 改为 38.5pt。

脚本从树中读取 viewport 的真实位置，输入确认后留出宿主队列处理时间，再读取 offset。这验证位移/停止逻辑，不是物理触控板采样，也不是打断延迟测量。AppKit 回归另以合成 NSEvent 检查 points/lines、独立 momentum、零位移取消与 SDL 标记顺序。

## 回归与活动输入计时

构建、命令、环境、二进制 SHA256 与检查边界见 [validation.json](validation.json)。最终完整 GuavaUI 命令退出 0，Runtime 259、Compose 588、Gallery 7，另有 Workspace XCTest 51、DevTools XCTest 11、App XCTest 24，以及资源/timing 的 4 项 Swift Testing。App 中 1 项和 Runtime 中 3 项既有 opt-in benchmark 未启用。Portable 运动与录制 41 项、PlatformCore 2 项、Editor 20 项通过；两个采样脚本通过 Swift 6 严格编译，浏览器 client 通过 JS 语法检查。

原生适配回归使用 AppKit NSEvent 和 SDL events 子系统；不启动 SDL video，避免改写同进程 NSApplication 生命周期而中断其他测试。最终 Runtime 的 259 项有完整完成汇总，包含 3 项 AppKit 和 6 项 phased routing。全局 fallback 实际消费者也锁定，覆盖遮罩移除后的惯性归属。

在同一 Release 原生进程顺序采了两次活动输入，采样期间没有运行构建/测试。环境为 M1 MacBook Air、60Hz、1280×720 逻辑窗口、2× Retina。原始逐帧记录分别为 [第一次](active-release.json)、[复测](active-release-repeat.json)。单位均为 ms：

| 指标 | 第一次 | 复测 |
| --- | ---: | ---: |
| timing frame / presented | 815 / 815 | 826 / 826 |
| draw P99 | 4.305 | 4.311 |
| present P99 | 14.691 | 14.676 |
| 宿主 total P99 | 16.747 | 16.897 |
| 宿主 total 最大值 | 49.995 | 17.223 |
| 宿主 total >33.34ms | 1 | 0 |

第一次约 50ms 的尖峰主要在 present 等待（47.944ms），复测没有重现；尚未隔离其来源，不能归因给镜像或系统，也不能删掉该样本。`total` 包含 present 等待，通常接近刷新周期，不能当作纯 CPU 绘制耗时；客户端接收间隔受镜像消息传输影响，更不能换算为实际屏幕 FPS。此数据支持当前场景的绘制成本较稳定，仍不足以宣称所有滚动无掉帧。

30 个本轮 Swift 文件按结构规则与 HEAD 比较，没有新增或增长的越界。已有 ViewportInfoBar 27 字段和 NodeSummary 18 参数保持不变；整仓检查仍报告原有 AppDisplayHandle 29 字段超过基线允许的 27，未修改该类型或放宽基线。

## 复现与限制

```sh
swift build --package-path GuavaUI -c release --product GuavaUIDemo --jobs 4
GUAVA_DEVTOOLS=1 GUAVA_DEVTOOLS_PORT=9244 GuavaUI/.build/release/GuavaUIDemo --component scrollview --benchmark
# 在另一个终端，保持一个 Demo 窗口，停止其他构建/测试：
swift scripts/verify-scroll-input.swift 9244 /tmp/native-scroll-input.json
swift scripts/record-scroll-timings.swift 9244 /tmp/active-scroll-release.json
```

新的采样脚本只采集六段活动输入：每段 120 包、间隔约 16ms、每包 1.25pt；每段丢弃前三个 timing frame。为授权注入保留 1fps mirror，回读开销计入结果。客户端接收间隔不是 compositor 时间；`presentMs` 也不是 GPU 完成时间。这与旧版本 post-burst 统计不同，不能直接计算“提升多少”。

仍需真实触控板、Magic Mouse、平滑驱动鼠标、120Hz 和 Windows/Linux 设备录制；也尚未验证所有内容规模、长时间运行和可变行高列表。没有与两个参考库做等工作负载性能对跑。此次修复了已确认的输入叠加机制，没有将“所有滚动视觉上都不抖动/不掉帧”标为完成。

Workspace 的可持久化 minimum/preferred/maximum、外部区域键盘/辅助功能和标签大字体，以及通用 measure/propose/place、Grid/LazyGrid、可变行高虚拟布局、响应式候选布局、RTL/SafeArea，仍是后续工作，未在本轮标为完成。
