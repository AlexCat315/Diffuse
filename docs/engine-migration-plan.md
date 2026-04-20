# Engine 迁移方案（第二版，含现状与实现映射）

## 1. 文档目的

这份文档回答四个问题：

1. 现在的 Engine 架构是什么。
2. 现在有哪些能力，分别在哪里实现。
3. 目标架构是什么，要保留/替换什么能力。
4. 每个阶段具体做什么、改哪些模块、如何验收、何时回滚。

## 2. 现状架构（As-Is）

## 2.1 入口与运行模式

当前入口在 [packages/engine/src/main.zig](packages/engine/src/main.zig)，包含三种主运行模式：

1. 直接引擎运行模式 runEngine。
2. Editor Server 模式 runEditorServer（供编辑器通过 RPC 控制）。
3. MCP 模式 runMcp（AI 协作相关）。

命令行参数在 [packages/engine/src/cli.zig](packages/engine/src/cli.zig) 实现，支持：

1. 渲染后端选择。
2. editor-port 配置。
3. project-path 与 scene 参数。
4. render-test、benchmark、validate 等工程命令。

## 2.2 核心模块分层

聚合导出在 [packages/engine/src/root.zig](packages/engine/src/root.zig)，可见当前是“单引擎内多子系统”结构：

1. core：Application、Layer、Input、CommandQueue、SceneManager。
2. render/gfx：渲染器与 RHI 抽象（已对接 guava_rhi）。
3. scene/assets：世界、实体组件、资源导入与注册表。
4. physics/script/network/ui 等功能系统。
5. editor_rpc：WebSocket JSON-RPC 服务层。

## 2.3 主循环实现

主循环在 [packages/engine/src/engine/core/application.zig](packages/engine/src/engine/core/application.zig) 的 run 中实现，包含：

1. 事件泵与输入更新。
2. SceneManager pump 与命令队列应用。
3. 各系统 update（动画、导航、网络、经济、选择、脚本等）。
4. 渲染触发条件判断（scene revision、pick 读回、redraw cooldown）。
5. drawFrame 提交与帧延迟控制。

## 2.4 编辑器通信与视口链路

Editor RPC 在 [packages/engine/src/engine/editor_rpc/server.zig](packages/engine/src/engine/editor_rpc/server.zig) 与 [packages/engine/src/engine/editor_rpc/dispatch.zig](packages/engine/src/engine/editor_rpc/dispatch.zig) 实现：

1. 本地 TCP + WebSocket + JSON-RPC 2.0。
2. 多命名空间 handler 自动分发。
3. 订阅与广播（scene changed、selection changed、viewport metrics 等）。

viewport 相关 handler 在 [packages/engine/src/engine/editor_rpc/handlers/viewport.zig](packages/engine/src/engine/editor_rpc/handlers/viewport.zig)，包含：

1. setRect、getWindowInfo、attachToParent、detachFromParent。
2. getSurfaceId（IOSurface 或 shm）。
3. 渲染设置读写（Bloom、SSAO、TAA、SSR、DOF、RT shadows 等）。

## 2.5 渲染能力现状

渲染核心在 [packages/engine/src/engine/render/renderer.zig](packages/engine/src/engine/render/renderer.zig)，特征：

1. 多 Pass 管线（base、shadow、post、gizmo、id pass 等）。
2. 视口状态可配置，定义在 [packages/engine/src/engine/render/types.zig](packages/engine/src/engine/render/types.zig)。
3. 后端类型来自 guava_rhi，类型桥在 [packages/engine/src/engine/render/types.zig](packages/engine/src/engine/render/types.zig)。
4. Editor 模式下支持选择读回与重绘触发机制。

## 2.6 构建与工程能力

构建在 [packages/engine/build.zig](packages/engine/build.zig)：

1. 可构建 guava-engine 与 guava-player。
2. 可运行 render-test、validate、leak-check。
3. 已有与 editor 的联动入口 run-editor。

## 2.7 现状范围量化

当前可直接量化的迁移范围：

1. Editor RPC handler 文件数：24。
2. Editor RPC 方法数：174。
3. 主循环为单入口集中调度，且 update 链路包含动画、物理、导航、网络、AI、脚本、音频、层更新、渲染提交。

结论：

1. 这是成熟的大型编辑器引擎运行时，不是小型 demo。
2. 迁移必须做“协议兼容 + 主循环替换 + 渲染逐步替换”，不能一把梭重写。

## 3. 现状能力清单（可迁移资产）

必须保留的能力：

1. Application 生命周期管理与 Layer 机制。
2. Scene/Asset/Script 基础运行链路。
3. Editor RPC 命名空间与方法协议。
4. Viewport 控制与渲染设置协议。
5. 构建、验证、渲染测试、泄漏检查能力。

可延后迁移的能力：

1. 次要后处理参数全量映射。
2. 非核心工具链命令。
3. 个别低频编辑器调试接口。

## 4. 目标架构（To-Be）

## 4.1 结构目标

目标不是“功能重写”，而是“运行时壳替换 + 现有能力复用”。

目标模块：

1. EngineHost（Swift）：生命周期与帧调度总控。
2. RuntimeAdapters（Swift）：连接 Scene/Asset/Script 子系统。
3. RenderBackend（Swift 接口 + wgpu 实现）：渲染提交与呈现。
4. NativeBridge（C ABI）：复用或承接 C/C++ 热点模块。
5. GuavaUI（Swift + wgpu）：自渲染编辑器 UI，跨平台，与引擎共享 wgpu 实例。
6. PlatformShell（SDL3）：跨平台窗口创建与输入事件。

当前脚手架：

1. [packages/guava-next/Sources/EngineCore/EngineCore.swift](packages/guava-next/Sources/EngineCore/EngineCore.swift)
2. [packages/guava-next/Sources/EngineCore/EngineFFI.swift](packages/guava-next/Sources/EngineCore/EngineFFI.swift)
3. [packages/guava-next/Sources/CEngineBridge/include/engine_bridge.h](packages/guava-next/Sources/CEngineBridge/include/engine_bridge.h)

## 4.2 线程模型目标

1. Main 线程：输入、命令提交、编辑器交互。
2. Render 线程：图形命令编码与提交。
3. Worker 线程池：资源加载与后台任务。

约束：

1. Main 不做重渲染计算。
2. Render 不直接读写 UI 状态。
3. 跨线程传递不可变快照与命令队列。

## 5. As-Is 到 To-Be 映射

## 5.1 生命周期与主循环

As-Is：

1. Application.run 在 Zig 中串联输入、系统更新、渲染。

To-Be：

1. Swift EngineHost 持有 TickPhase：Input、Simulation、RenderPrep、RenderSubmit。
2. 每个 Phase 对应一个 Adapter，先调用旧 Zig 能力，再逐步替换。

实现动作：

1. 在 [packages/guava-next/Sources/EngineCore/EngineCore.swift](packages/guava-next/Sources/EngineCore/EngineCore.swift) 增加 TickPhase 和调度器。
2. 在 [packages/guava-next/Sources/EngineCore/EngineFFI.swift](packages/guava-next/Sources/EngineCore/EngineFFI.swift) 增加 phase 级 C ABI 调用。

## 5.2 Editor RPC

As-Is：

1. server + dispatch + handlers 分层。
2. method 命名空间稳定，前端依赖强。

To-Be：

1. 保留协议不变，先把 RPC 作为兼容层保留。
2. 后端实现从 Zig 迁到 Swift 时，保持同名 method 与参数语义。

实现动作：

1. 先冻结 method 契约，生成协议快照。
2. 用协议回归测试校验迁移后兼容性。

## 5.3 视口与渲染

As-Is：

1. renderer 内部多 pass，editor 可实时改 viewport state。
2. 通过 getSurfaceId/共享 surface 对接 editor 端展示。

To-Be：

1. RenderBackend 先实现 wgpu 主路径。
2. 视口状态仍保留同语义字段，先实现高频字段，低频字段分批补。
3. viewport 渲染到 wgpu 纹理，GuavaUI 在 viewport 面板区域采样该纹理，零拷贝。
4. 外部接口继续提供 surface 句柄语义，避免 editor 同步重构。

实现动作：

1. 在 [packages/guava-next/Sources/RenderBackend/RenderBackend.swift](packages/guava-next/Sources/RenderBackend/RenderBackend.swift) 增加 SceneViewport API。
2. 把渲染统计（draw calls、frame time、passes）作为统一输出。

## 5.4 构建与测试

As-Is：

1. build.zig 已有 run、validate、render-test、leak-check。

To-Be：

1. 迁移后必须保留等价的自动化能力。

实现动作：

1. 在 guava-next 增加 smoke test 与回归脚本。
2. 建立“同一场景输入 -> 同一统计指标”对比基线。

## 5.5 文件级迁移映射（必须按此顺序）

| 现有文件 | 角色 | 新文件/模块 | 第一阶段动作 | 验收标准 |
|---|---|---|---|---|
| [packages/engine/src/main.zig](packages/engine/src/main.zig) | 进程入口与模式分发 | [packages/guava-next/Sources/EditorApp/main.swift](packages/guava-next/Sources/EditorApp/main.swift) | 建立同等运行模式开关（普通/编辑器服务） | 能按参数启动对应模式 |
| [packages/engine/src/engine/core/application.zig](packages/engine/src/engine/core/application.zig) | 主循环与系统调度 | [packages/guava-next/Sources/EngineCore/EngineCore.swift](packages/guava-next/Sources/EngineCore/EngineCore.swift) | 引入 TickPhase 与帧管线骨架 | 能执行 Input->Sim->RenderSubmit |
| [packages/engine/src/engine/render/renderer.zig](packages/engine/src/engine/render/renderer.zig) | 渲染总控 | [packages/guava-next/Sources/RenderBackend/RenderBackend.swift](packages/guava-next/Sources/RenderBackend/RenderBackend.swift) | 抽出 Renderer 协议与 FrameReport | 输出帧统计且可渲染首帧 |
| [packages/engine/src/engine/editor_rpc/server.zig](packages/engine/src/engine/editor_rpc/server.zig) | RPC 服务 | EngineCore.RpcCompatAdapter | 保留端口、协议、队列行为 | 旧 editor 客户端可连通 |
| [packages/engine/src/engine/editor_rpc/dispatch.zig](packages/engine/src/engine/editor_rpc/dispatch.zig) | 方法路由 | EngineCore.RpcMethodRegistry | 固化 method 表并加兼容测试 | method 名称与参数保持一致 |
| [packages/engine/src/engine/editor_rpc/handlers/viewport.zig](packages/engine/src/engine/editor_rpc/handlers/viewport.zig) | 视口控制与输入 | RenderBackend.ViewportHost + RpcViewportAdapter | 先迁 setRect/getSurfaceId/sendInput | viewport 可交互且可取 surface |
| [packages/engine/src/cli.zig](packages/engine/src/cli.zig) | 运行参数契约 | EditorApp.ArgParser | 保留关键参数（backend/editor-port/project-path） | 参数兼容通过回归测试 |
| [packages/engine/build.zig](packages/engine/build.zig) | 构建与测试入口 | [packages/guava-next/Package.swift](packages/guava-next/Package.swift) + scripts | 建立等价 smoke/benchmark 入口 | CI 可执行最小回归 |

## 6. 分阶段执行计划（可开工版本）

## Phase 0（1-2 周）：现状冻结与契约固化

任务：

1. 冻结 RPC method 列表与参数契约。
2. 冻结运行指标基线（启动时延、P95 帧时间、内存峰值）。
3. 产出 As-Is 能力矩阵。

验收：

1. 有基线报告与契约快照。
2. 评审通过后才能进入 Phase 1。

## Phase 1（2-4 周）：Swift EngineHost 驱动旧引擎

任务：

1. 用 Swift 主循环驱动 C ABI。
2. 运行模式最小打通：init、tick、shutdown。
3. 接入崩溃与日志链路。

验收：

1. 可连续运行 30 分钟。
2. 无明显泄漏增长。

## Phase 2（4-8 周）：渲染主路径替换 + GuavaUI 基础

任务：

1. wgpu 后端首版可渲染场景。
2. 视口高频设置可读写。
3. 帧统计对齐现有指标。
4. GuavaUI 2D 渲染器最小原型（矩形 + 文字）。
5. Yoga 布局集成。

验收：

1. 目标场景稳定渲染。
2. 与基线对比不出现灾难性退化。

## Phase 3（持续）：子系统分批替换 + GuavaUI 编辑器完善

任务：

1. Scene/Asset/Script 按优先级迁移。
2. C/C++ 热点保留到 NativeBridge。
3. GuavaUI DockContainer、TreeView、PropertyGrid、编辑器面板逐步完善。

验收：

1. 每批迁移都有功能回归与性能回归结果。

## 7. 回滚策略

回滚触发：

1. 连续两周未达到阶段验收。
2. 稳定性指标显著恶化。
3. RPC 协议兼容性出现破坏。

回滚动作：

1. 回到上一阶段 tag。
2. 冻结新迁移，仅修复阻断问题。
3. 保持 editor 对外协议不变。

## 8. 立刻执行的任务分解（按文件与产出）

### 8.1 Sprint A（5 个工作日）

1. 任务 A1：导出 RPC 协议快照。
	- 输入文件：[packages/engine/src/engine/editor_rpc/handlers](packages/engine/src/engine/editor_rpc/handlers)
	- 产出文件：[docs/engine-rpc-contract-v1.json](docs/engine-rpc-contract-v1.json)
	- 完成定义：包含 24 个 namespace 文件、174 个方法签名。

2. 任务 A2：定义 TickPhase 调度器。
	- 输入文件：[packages/guava-next/Sources/EngineCore/EngineCore.swift](packages/guava-next/Sources/EngineCore/EngineCore.swift)
	- 产出：TickPhase 枚举、FramePipeline 结构、阶段计时。
	- 完成定义：运行日志中可见每阶段时长。

3. 任务 A3：扩展 C ABI 到 phase 级接口。
	- 输入文件：[packages/guava-next/Sources/CEngineBridge/include/engine_bridge.h](packages/guava-next/Sources/CEngineBridge/include/engine_bridge.h)
	- 输入文件：[packages/guava-next/Sources/CEngineBridge/engine_bridge.c](packages/guava-next/Sources/CEngineBridge/engine_bridge.c)
	- 输入文件：[packages/guava-next/Sources/EngineCore/EngineFFI.swift](packages/guava-next/Sources/EngineCore/EngineFFI.swift)
	- 完成定义：可分别调用 input/sim/render_prepare/render_submit。

4. 任务 A4：最小帧统计。
	- 输入文件：[packages/guava-next/Sources/RenderBackend/RenderBackend.swift](packages/guava-next/Sources/RenderBackend/RenderBackend.swift)
	- 产出：FrameReport（frame_time_ms、draw_calls、passes）。
	- 完成定义：每帧可采集并输出。

5. 任务 A5：最小 smoke test。
	- 输入文件：[packages/guava-next/Sources/EditorApp/main.swift](packages/guava-next/Sources/EditorApp/main.swift)
	- 产出：启动 3 帧后退出测试脚本。
	- 完成定义：swift run EditorApp 返回 0。

### 8.2 Sprint B（5 个工作日）

1. 任务 B1：RPC 兼容层最小实现。
	- 目标方法：editor.ping、editor.getCapabilities、viewport.setRect、viewport.getSurfaceId、viewport.sendInput、scene.getHierarchy。
	- 产出：兼容层接口与测试。
	- 完成定义：旧 editor 可成功调用以上方法。

2. 任务 B2：viewport 高频设置最小集。
	- 目标字段：render_mode、pipeline_mode、show_grid、taa_enabled、fxaa_enabled、ssao_enabled。
	- 完成定义：设置后 1 帧内生效。

3. 任务 B3：崩溃安全 shutdown 顺序。
	- 顺序：render shutdown -> runtime shutdown -> resource shutdown。
	- 完成定义：重复启停 100 次无崩溃。

4. 任务 B4：协议回归测试。
	- 输入：[docs/engine-rpc-contract-v1.json](docs/engine-rpc-contract-v1.json)
	- 产出：契约比对测试。
	- 完成定义：方法名和参数键集完全一致。

5. 任务 B5：阶段里程碑标签。
	- 产出：Phase-0-stable tag。
	- 完成定义：可从 tag 重新构建并通过 smoke test。

## 8.3 每日验收命令

1. 构建与运行：在 [packages/guava-next](packages/guava-next) 执行 swift build 与 swift run EditorApp。
2. 旧引擎校验：在 [packages/engine](packages/engine) 执行现有 smoke 和 render-test 命令。
3. 协议校验：执行 RPC 契约比对脚本。

## 9. 下一份文档

下一份是 Editor 迁移方案，内容将与本文一一对应：

1. As-Is 面板架构与能力。
2. To-Be 的 GuavaUI 自渲染架构、DockModel 与 PanelModel。
3. 与 EngineHost 的命令总线契约。
4. GuavaUI 框架详细设计参见 [guava-ui-blueprint.md](guava-ui-blueprint.md)。

