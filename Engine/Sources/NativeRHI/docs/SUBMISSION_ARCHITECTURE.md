# CPU 命令路径对照与提交计时

本次以提供的本地 NRI、NVRHI、slang-rhi 源码，以及本机 Cargo 缓存中的
wgpu-core/wgpu-hal 29.0.3 实现为依据。三个参考目录是源码快照，没有 Git 元数据；
不能据此声称它们是最新版本。本项目 WGPU 二进制的构建清单记录的是 wgpu-native
v29.0.1.1，revision `6aed50955d934ac36049ba8d002034841633ae02`；缓存中的
wgpu-core 源码 revision 为 `4cbe6232b2d7c289b6e1a38416a6ae1461a22e81`。
这里对照工作分工，不把参考实现当作已在本机运行过的性能基线。

参考快照入口文件的 SHA-256：

| 项目 / 文件 | SHA-256 |
| --- | --- |
| NRI `Source/VK/CommandBufferVK.hpp` | `1b032b19a001f053c0016b4d2b39851c01770bab37d2fc7b68c0db35c2ab6b92` |
| NVRHI `src/vulkan/vulkan-commandlist.cpp` | `2538ac2159413c35bf9d1dc6a369d14cbef93db40ca8f26a0e770bb3da15d03a` |
| slang-rhi `src/metal/metal-command.cpp` | `f7956e1bbc8005383806edaf138bc4d95118b72662f804a10cdddd68429fca20` |

## 相同名字不代表相同工作

| 实现 | 录制 / finish 的工作 | submit 的工作 |
| --- | --- | --- |
| NRI VK / D3D12 | Draw/DrawIndexed 直接调用 vkCmdDraw / ID3D12GraphicsCommandList；调用方显式提供 Barrier | 将已有原生命令缓冲与 fence 等待/信号送入 QueueSubmit2 / ExecuteCommandLists |
| NVRHI VK | open 创建/复用原生命令缓冲；setGraphicsState 等路径跟踪资源并提交屏障；close 恢复要求的初始状态并结束原生命令缓冲 | 整理 timeline、命令缓冲寿命、staging 引用，调用原生队列 |
| slang-rhi Metal | API 记录抽象命令；finish 解析 pipeline，并由 CommandRecorder 回放成 Metal encoder 命令 | 提交已有 Metal 命令缓冲，处理 fence、residency 与资源回收 |
| WGPU 29.0.3 Metal | pass.end 保存抽象 pass；CommandEncoder.finish 校验并 encode_commands，建立命令缓冲内资源使用跟踪，调用 HAL / Metal | 校验命令缓冲寿命，衔接设备全局资源状态，处理初始化与 pending writes，再提交 HAL 队列 |
| Guava NativeRHI Metal | UI 准备资源、上传几何、生成 Swift 抽象命令数组 | frontend 校验 → checkpoint / 状态与队列依赖规划 → 再次检查附件 → 回放 Metal encoder → commit |

因此已有 benchmark 的 `cpuRecord`、`cpuSubmit` **不能跨实现按列直接排名**。
WGPU 的主要原生编码已经包含在 `cpuRecord` 内；NativeRHI 的编码包含在
`cpuSubmit` 内。WGPU 的 submit 也不是一个裸 commit 调用。

`cpuFrame` 是相对可比的 CPU 总成本，包含帧入口、资源准备、录制与提交，排除每三帧
显式等待 GPU 的 drain；`completedBatch` 包含 drain，表示该调度下完成一批工作的平均
时间，不能当成单帧 GPU timestamp 或窗口呈现延迟。分位数来自不同样本，不能直接相加。

把 NativeRHI 的编码移动到 finish 会缩短名为 submit 的阶段，但不必然减少 CPU 总成本。
状态衔接仍必须按照真实提交顺序完成，尤其不能破坏跨队列 release/acquire 与失败回滚。

## 源码入口

- NRI：`Source/VK/CommandBufferVK.hpp` 的 Draw/DrawIndexed/Barrier，
  `Source/VK/QueueVK.hpp` 的 QueueVK::Submit；
  `Source/D3D12/CommandBufferD3D12.hpp` 与 `QueueD3D12.hpp`。
  校验另在 `Source/Validation/CommandBufferVal.hpp`，不能把关闭校验的薄封装与完整安全校验等同。
- NVRHI：`src/vulkan/vulkan-commandlist.cpp` 的 open/close，
  `vulkan-state-tracking.cpp` 的 require*State/commitBarriers，
  `vulkan-resource-bindings.cpp` 的 createBindingSet/bindBindingSets，
  `vulkan-queue.cpp` 的 Queue::submit；公共状态逻辑在 `src/common/state-tracking.cpp`。
- slang-rhi：`src/metal/metal-command.cpp` 的 CommandEncoderImpl::finish、
  CommandRecorder::record、CommandQueueImpl::submit；绑定数据在
  `metal-shader-object.h/.cpp`。`src/state-tracking.h` 提供状态屏障聚合。
- WGPU：`wgpu-core/src/command/mod.rs` 的 finish/encode_commands，
  `command/render.rs` 的 render_pass_end，`device/queue.rs` 的 Queue::submit；
  `wgpu-hal/src/metal/device.rs` 的 create_bind_group 与
  `metal/command.rs` 的 update_bind_group_state/set_bind_group。

## 已落地的诊断与通用改进

- `Device.submit(..., cpuProfile:)` 可选记录 frontend 校验、依赖规划、backend 编码、
  原生提交调用四段 CPU 时间；默认 nil 不读取时钟。累计多个 planned submit 的编码/提交
  时间，包括所有权转移的辅助 submit；不等待 GPU。
- Metal 的 queueSubmit 边界是 MTLCommandBuffer.commit；Vulkan 包含组装 submitInfo 与
  vkQueueSubmit；DX12 的 C bridge 提交入口还包含 Close、timeline 解析和原生 retirement，
  因此 DX12 数值不能解释为 ExecuteCommandLists 单个调用。当前只验证 macOS Metal。
- benchmark JSON 增加 measurementScopes，并在显式开启诊断时写入四段数据。
  新增无 authored 图片、固定一份四顶点几何的 0/1/96/1024 draw 命令数量实验。
  它增加命令与 scissor 数量，不增加纹理集合或几何上传量。
- immutable binding set 注册时预解析 planner 依赖，不在每次提交重复解释绑定类型；
  已覆盖的只读窗口复用 RAW 依赖，但写入、范围扩大、stage 扩大和队列变化仍产生所需同步。
  绑定缓存命中复用先前校验结果；相邻重复 set/scissor 省略。

## 结构改动的依据与进度

1. 分离命令缓冲局部资源使用与提交时全局状态衔接，借鉴 WGPU 的局部 tracker / 全局
   transit，避免每次 submit 重新解释所有 draw；保留真实提交顺序、写后读、队列转移与失败回滚。
2. 已借鉴 WGPU HAL、slang-rhi BindingData 与 NVRHI descriptor set，在创建不可变绑定时
   解析并强持有原生资源、offset 与 stage；编码不再逐 entry 查资源字典或验证 buffer 范围。
   反向索引在资源退休时失效依赖 set；LRU 淘汰仍经 frame ring 延迟注销。纹理 shader usage
   在创建绑定时校验，避免把按 frame slot 更换原生对象的 framebuffer-only drawable 缓存为采样绑定。
3. 合并重复的命令遍历。当前 frontend 校验、能力检查、planner、附件检查、Metal 回放
   分别扫描 pass。不能以关闭必要校验来制造性能收益。
4. 只有 CPU 总成本和完成时间改善才算收益；空 pass、普通控件、命令数量、动态上传、
   compute 与实际场景都需要覆盖。图片场景只是资源压力用例之一。

slang-rhi Metal 使用 untracked resource 与 encoder fence 的同步约定；当前本项目使用
Metal 的 tracked resource。不能仅模仿其低层编码而删掉当前同步机制。

## 首轮分段诊断（Apple M1，Release）

固定几何实验每次仅上传 4 个顶点和 6 个索引，所有 draw 复用同一份几何、不同 scissor；
0 draw 是空 pass。它不是完整游戏负载，但能够隔离命令数量变化。普通控件仍使用原先
48 组控件场景。以下均开启 NativeRHI 分段计时；WGPU 未插入内部计时器，因此这些
CPU 数值用于定位，不作为最终性能验收或改动前后加速比例。

| 工作量 | 分辨率 | CPU 总 p50 Native / WGPU (µs) | API submit p50 Native / WGPU (µs) | Native 校验 / 规划 / 编码 / commit p50 (µs) |
| --- | --- | ---: | ---: | ---: |
| [0 draw](benchmarks/native-command-count-0-m1-720-submission-profile.json) | 720p | 37.46 / 40.00 | 34.42 / 12.38 | 0.29 / 3.04 / 25.04 / 3.79 |
| [0 draw](benchmarks/native-command-count-0-m1-1080-submission-profile.json) | 1080p | 26.96 / 29.46 | 25.17 / 9.42 | 0.21 / 2.17 / 17.88 / 2.79 |
| [1 draw](benchmarks/native-command-count-1-m1-720-submission-profile.json) | 720p | 42.46 / 92.38 | 37.04 / 14.92 | 0.46 / 6.00 / 24.62 / 2.83 |
| [1 draw](benchmarks/native-command-count-1-m1-1080-submission-profile.json) | 1080p | 43.58 / 86.33 | 37.88 / 13.33 | 0.46 / 6.29 / 25.54 / 3.04 |
| [96 draw](benchmarks/native-command-count-96-m1-720-submission-profile.json) | 720p | 58.54 / 110.62 | 46.58 / 15.00 | 1.21 / 5.83 / 32.67 / 5.46 |
| [96 draw](benchmarks/native-command-count-96-m1-1080-submission-profile.json) | 1080p | 67.79 / 114.83 | 53.62 / 15.79 | 1.42 / 6.75 / 37.79 / 5.96 |
| [1024 draw](benchmarks/native-command-count-1024-m1-720-submission-profile.json) | 720p | 172.88 / 244.42 | 117.88 / 14.04 | 6.58 / 6.42 / 96.62 / 4.83 |
| [1024 draw](benchmarks/native-command-count-1024-m1-1080-submission-profile.json) | 1080p | 135.12 / 219.08 | 93.25 / 13.08 | 5.00 / 5.38 / 77.00 / 4.42 |
| [普通控件（336 draw）](benchmarks/native-ui-m1-720-submission-profile.json) | 720p | 285.33 / 402.08 | 194.58 / 16.54 | 16.25 / 12.08 / 156.04 / 5.25 |
| [普通控件（336 draw）](benchmarks/native-ui-m1-1080-submission-profile.json) | 1080p | 335.17 / 506.08 | 228.00 / 18.92 | 19.17 / 12.96 / 187.75 / 5.88 |

所有实验在采样前比较完整 readback 画面，误差门槛通过；稳态没有纹理上传。
普通控件的 NativeRHI 编码 p50 为 156–188 µs，规划约 12–13 µs，commit 约 5–6 µs。
这轮数据指向 backend 编码路径是主要 CPU 成本。固定几何从 1 draw 增长至 1024 draw，
编码耗时随之增长，而规划成本基本稳定。不能由此排除复杂资源集合或 compute 的规划成本。

复现（先以同一工具链完成 Release 构建）：

```sh
GUAVA_NATIVE_COMMAND_BENCHMARK=1 GUAVA_NATIVE_UI_BENCHMARK=1 \
GUAVA_NATIVE_SUBMISSION_PROFILE=1 GUAVA_NATIVE_UI_BENCHMARK_OUTPUT=/tmp/guava-submission-profile \
swift test --package-path GuavaUI -c release --skip-build --filter NativeDrawListBenchmarkTests
```

去掉 `GUAVA_NATIVE_SUBMISSION_PROFILE` 后不插入分段时钟；对比优化收益时应使用这个模式，
保持交替首发顺序、完整工作量与完成时间口径。

验证在隔离的 `fb92b738` 工作树加本次渲染改动上完成，以避开主目录同时进行的组件注册表
改造；15 个渲染/测试源文件逐字节一致。NativeRHI 117 项测试全部通过、无跳过（设置
Slang 路径，含真实 Metal 队列与存储读写）；GuavaUI Release 14 项相关测试中 11 项执行
通过，3 项 opt-in benchmark 在普通回归运行中跳过。上述诊断单独启用其中 2 项（命令
数量与普通控件），10 份报告与所有画面预检通过。Swift maintainability 检查通过，
未增加现有超限指标。

窗口计时脚本支持 Release、交替 renderer 顺序及无镜像 readback 的 DevTools 采样，
并在任何样本未提交/呈现时保留原始报告并拒绝结果。Editor Native 连续窗口功能流程
及两组 300 帧采样已完成；配对 WGPU 的一次运行返回未呈现帧，随后单独 120 帧正常，
原因尚未稳定复现，因此这组窗口数据不作为性能通过证据，默认 renderer 继续保持 WGPU。
