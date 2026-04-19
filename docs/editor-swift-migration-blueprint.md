# Editor 迁移蓝图（SwiftUI/AppKit，同进程）

## 1. 文档目标

这份文档回答四件事：

1. 当前 editor 架构是什么。
2. 当前 editor 能力边界和复杂度有多大。
3. 迁移到 SwiftUI/AppKit 后的目标架构怎么落地。
4. 每个阶段改哪些文件、如何验收、如何并行。

## 2. 现状架构（As-Is）

## 2.1 复杂度量化

- 面板文件数：35。
- store 文件数：14。
- renderer 目录下 TSX 文件数：45。

这说明当前 editor 已经是复杂工作台，不是简单壳层。

## 2.2 UI 组织方式

核心入口在 [packages/editor/src/renderer/App.tsx](packages/editor/src/renderer/App.tsx)：

1. 采用 flexlayout-react 管理 docking 与 tabset。
2. 使用本地布局持久化（localStorage）。
3. 面板注册集中在 ALL_PANELS，当前约 26 个核心面板 id。
4. viewport 位于中心 tabset，底部 tabset 聚合 console/assets/timeline 等。

## 2.3 状态管理方式

状态桥接在 [packages/editor/src/renderer/store/rpc-bridge.ts](packages/editor/src/renderer/store/rpc-bridge.ts)：

1. engine 通知事件分发到多个 Zustand store。
2. 事件类型包含 scene changed、selection changed、console logs、mesh state changed、playback state changed。
3. 连接状态与错误状态由 connection store 管理。

## 2.4 引擎通信方式

通信客户端在 [packages/editor/src/renderer/engine-client.ts](packages/editor/src/renderer/engine-client.ts)：

1. WebSocket JSON-RPC。
2. 调用超时与重连逻辑内建。
3. 通知与请求共用同一事件总线。

## 2.5 视口链路

viewport 面板在 [packages/editor/src/renderer/panels/Viewport.tsx](packages/editor/src/renderer/panels/Viewport.tsx)：

1. 有输入转发（鼠标、滚轮、框选、拾取）。
2. 同时支持 native overlay 与像素流逻辑。
3. 存在对跨边界渲染链路的适配复杂度。

## 3. 目标架构（To-Be）

## 3.1 总体原则

1. 保留一套 Editor Core 业务模型，不写三套 UI 业务。
2. 平台层只做薄壳，不承载业务逻辑。
3. Viewport 走同进程零拷贝渲染呈现。
4. RPC 协议可先保留兼容层，再逐步内联命令总线。

## 3.2 分层模型

1. EditorCore（纯 Swift）
- 面板模型 PanelModel。
- 命令系统 Undo/Redo。
- DockModel 与布局持久化模型。
- 选择态、播放态、工具态。

2. EngineBridge（Swift）
- 初期保留 RPC Compat。
- 逐步切换为进程内命令总线。

3. ViewportHost（AppKit/Metal）
- 输入路由。
- CAMetalLayer 呈现。
- 帧统计回传。

4. PlatformShell（AppKit）
- 菜单、快捷键、窗口生命周期、文件对话框、剪贴板。

## 3.3 线程模型

1. Main Thread
- SwiftUI/AppKit 视图、Dock 交互、命令派发。

2. Engine Simulation Thread
- 场景与脚本更新，输出 RenderPacket。

3. Render Thread
- 编码渲染命令并提交到 GPU。

约束：

1. Main 不等待 GPU。
2. Render 不直接改 UI state。
3. UI 与渲染只通过不可变快照交换。

## 4. As-Is 到 To-Be 文件映射

| 现有文件 | 当前职责 | 目标文件 | 迁移动作 | 验收 |
|---|---|---|---|---|
| [packages/editor/src/renderer/App.tsx](packages/editor/src/renderer/App.tsx) | 面板组装与布局 | Sources/EditorCore/Dock/DockModel.swift | 抽出面板注册表、布局 schema、tabset 规则 | 能恢复默认布局并持久化 |
| [packages/editor/src/renderer/store/rpc-bridge.ts](packages/editor/src/renderer/store/rpc-bridge.ts) | RPC 事件到 store | Sources/EditorCore/Bridge/EventBridge.swift | 定义事件枚举与状态 reducer | 事件回放结果一致 |
| [packages/editor/src/renderer/store/*.ts](packages/editor/src/renderer/store) | 状态仓库 | Sources/EditorCore/State/* | 分拆为 typed state + reducer + command | 核心状态快照一致 |
| [packages/editor/src/renderer/engine-client.ts](packages/editor/src/renderer/engine-client.ts) | WS RPC 客户端 | Sources/EditorCore/Bridge/RpcCompatClient.swift | 先保持同协议，后切进程内调用 | ping/capabilities/scene 接口可用 |
| [packages/editor/src/renderer/panels/Viewport.tsx](packages/editor/src/renderer/panels/Viewport.tsx) | 视口与输入 | Sources/Viewport/ViewportHostView.swift | 输入路由重建，移除像素流路径 | 视口交互正常，无 CPU readback |
| [packages/editor/src/renderer/panels/*](packages/editor/src/renderer/panels) | 业务面板视图 | Sources/EditorUI/Panels/* | PanelModel 与 PanelView 分离 | 面板数据驱动渲染 |

## 5. 能力迁移优先级

## P0 必须先迁

1. Viewport。
2. SceneHierarchy。
3. Inspector。
4. Console。
5. AssetBrowser（最小导入和浏览）。

## P1 第二批

1. RenderSettings。
2. MaterialEditor。
3. Sequencer。
4. ScriptEditor。

## P2 可延后

1. AiChat。
2. PluginManager。
3. PhysicsVisualization。
4. 低频调试面板。

## 6. 可执行任务分解（2 天粒度）

| 阶段 | 任务 | 产出文件路径 | 代码行数预估 | 前置任务 | 自动化测试命令 |
|---|---|---|---:|---|---|
| E0 (2天) | E0-T1 建立 EditorCore 模块 | packages/guava-next/Sources/EditorCore/* | 450 | 无 | swift build |
| E0 | E0-T2 DockModel schema 与序列化 | packages/guava-next/Sources/EditorCore/Dock/* | 320 | E0-T1 | swift test --filter DockModelTests |
| E1 (2天) | E1-T1 EventBridge 与状态 reducer | packages/guava-next/Sources/EditorCore/State/* | 420 | E0-T1 | swift test --filter StateReducerTests |
| E1 | E1-T2 RpcCompatClient 最小实现 | packages/guava-next/Sources/EditorCore/Bridge/* | 380 | E1-T1 | swift test --filter RpcCompatTests |
| E2 (2天) | E2-T1 ViewportHost 嵌入 SwiftUI | packages/guava-next/Sources/Viewport/* | 360 | E1-T2 | swift test --filter ViewportHostTests |
| E2 | E2-T2 输入路由迁移（鼠标/滚轮/拾取） | packages/guava-next/Sources/Viewport/InputRouter.swift | 260 | E2-T1 | swift test --filter ViewportInputTests |
| E3 (2天) | E3-T1 SceneHierarchy/Inspector 首版 | packages/guava-next/Sources/EditorUI/Panels/* | 520 | E1-T1 | swift test --filter PanelRenderingTests |
| E3 | E3-T2 Console 与日志事件 | packages/guava-next/Sources/EditorUI/Panels/Console* | 240 | E1-T1 | swift test --filter ConsolePanelTests |
| E4 (2天) | E4-T1 AssetBrowser 最小可用 | packages/guava-next/Sources/EditorUI/Panels/AssetBrowser* | 340 | E3-T1 | swift test --filter AssetBrowserTests |
| E4 | E4-T2 端到端回归脚本 | packages/guava-next/Scripts/editor-smoke.sh | 120 | E4-T1 | bash packages/guava-next/Scripts/editor-smoke.sh |

## 7. 验收标准（必须可执行）

1. 启动与渲染：swift run EditorApp。
2. 核心面板回归：swift test --filter PanelRenderingTests。
3. 视口输入回归：swift test --filter ViewportInputTests。
4. 协议兼容回归：swift test --filter RpcCompatTests。
5. 端到端 smoke：bash packages/guava-next/Scripts/editor-smoke.sh。

## 8. 风险与缓解

风险 1：Panel 业务与视图耦合过深。

缓解：先提取 PanelModel，再做视图重写；不得跨层读取 Engine 对象。

风险 2：RPC 到同进程总线切换时行为不一致。

缓解：先做 RpcCompatClient，保持 method 契约；对关键方法做录制回放测试。

风险 3：Viewport 输入路由回归。

缓解：保留旧输入语义映射表，逐项比对鼠标事件、框选、拾取结果。

风险 4：迁移期间功能膨胀导致延期。

缓解：执行 P0/P1/P2 严格分层，不允许 P2 阶段功能插队。

## 9. 本周开工清单

1. 建立 EditorCore 模块骨架。
2. 实现 DockModel 和布局序列化。
3. 实现 RpcCompatClient 的 ping/capabilities/scene.getHierarchy。
4. 创建 ViewportHostView 并接入 EngineHost。
5. 写 3 个基础测试：DockModelTests、RpcCompatTests、ViewportHostTests。
