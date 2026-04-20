# Editor 迁移蓝图（GuavaUI 自渲染，同进程）

## 1. 文档目标

这份文档回答四件事：

1. 当前 editor 架构是什么。
2. 当前 editor 能力边界和复杂度有多大。
3. 迁移到 GuavaUI（wgpu 自渲染）后的目标架构怎么落地。
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

1. 编辑器 UI 由 GuavaUI 框架渲染，GuavaUI 基于 wgpu 自渲染，与引擎共享同一 wgpu 实例。
2. 不依赖任何平台原生 UI 框架（SwiftUI / AppKit / Qt / Electron）。
3. 窗口创建和输入事件由 SDL3 提供，跨平台。
4. 保留一套 EditorCore 业务模型，不写多套 UI 业务。
5. Viewport 走同进程零拷贝：3D 场景渲染到 wgpu 纹理，GuavaUI 在 viewport 面板区域采样该纹理。
6. RPC 协议可先保留兼容层，再逐步内联命令总线。

## 3.2 分层模型

1. EditorCore（纯 Swift，无 UI 依赖）
- 面板模型 PanelModel。
- 命令系统 Undo/Redo。
- DockModel 与布局持久化模型。
- 选择态、播放态、工具态。

2. EngineBridge（Swift）
- 初期保留 RPC Compat。
- 逐步切换为进程内命令总线。

3. GuavaUI（Swift + wgpu）
- ViewTree：retained-mode 视图节点树。
- LayoutEngine：Yoga（C ABI）驱动 flexbox 布局。
- UIRenderer：wgpu 2D 图元批处理（圆角矩形、边框、阴影、文字四边形）。
- EventDispatch：hit test + 事件冒泡。
- StyleSystem：主题、颜色、间距、字体。
- WidgetKit：Label、Button、TextField、TreeView、PropertyGrid、TabBar、SplitPane。
- DockContainer：面板拖拽、分割、合并、布局持久化。

4. ViewportHost（wgpu 纹理采样）
- 引擎 3D 渲染到离屏纹理。
- GuavaUI DockContainer 的 viewport 面板区域采样该纹理。
- 输入路由：viewport 区域的鼠标/键盘事件转发给引擎。

5. PlatformShell（SDL3 + 平台适配）
- SDL3 窗口创建与事件泵。
- 平台特定功能封装（文件对话框、剪贴板、系统菜单）。
- macOS / Windows / Linux 共用同一套代码。

## 3.3 渲染管线

```
wgpu Device（引擎与 UI 共享）
│
├── Viewport Render Pass
│   ├── Base Pass（PBR 着色）
│   ├── Shadow Pass
│   ├── Post-processing Pass（Bloom/SSAO/TAA/SSR/DOF）
│   ├── Gizmo Pass
│   └── ID Pass（拾取）
│   → 输出到 wgpu Texture（离屏）
│
├── UI Render Pass
│   ├── GuavaUI 2D 图元批处理
│   │   ├── 面板背景、边框、分割线
│   │   ├── Widget 渲染（按钮、文字、图标）
│   │   └── Viewport 面板区域：采样引擎输出纹理
│   └── → 输出到 wgpu Surface（SDL3 窗口）
│
└── Present → SDL3 Window
```

同一 wgpu Device，同一帧内顺序执行两个 render pass，viewport 纹理不经 CPU，零拷贝。

## 3.4 线程模型

1. Main Thread
- SDL3 事件泵。
- GuavaUI 事件分发与 hit test。
- Yoga 布局计算（dirty flag 优化，非每帧重算）。
- 命令派发。

2. Engine Simulation Thread
- 场景与脚本更新，输出 RenderPacket。

3. Render Thread
- 引擎 3D 渲染（viewport texture）。
- GuavaUI 2D 渲染（含 viewport 纹理采样）。
- wgpu 命令编码与 present。

约束：

1. Main 不等待 GPU。
2. Render 不直接改 UI state。
3. UI 与渲染只通过不可变快照交换。

## 4. As-Is 到 To-Be 文件映射

| 现有文件 | 当前职责 | 目标模块 | 迁移动作 | 验收 |
|---|---|---|---|---|
| [packages/editor/src/renderer/App.tsx](packages/editor/src/renderer/App.tsx) | 面板组装与布局 | EditorCore/Dock/DockModel.swift | 抽出面板注册表、布局 schema、tabset 规则 | 能恢复默认布局并持久化 |
| [packages/editor/src/renderer/store/rpc-bridge.ts](packages/editor/src/renderer/store/rpc-bridge.ts) | RPC 事件到 store | EditorCore/Bridge/EventBridge.swift | 定义事件枚举与状态 reducer | 事件回放结果一致 |
| [packages/editor/src/renderer/store/*.ts](packages/editor/src/renderer/store) | 状态仓库 | EditorCore/State/* | 分拆为 typed state + reducer + command | 核心状态快照一致 |
| [packages/editor/src/renderer/engine-client.ts](packages/editor/src/renderer/engine-client.ts) | WS RPC 客户端 | EditorCore/Bridge/RpcCompatClient.swift | 先保持同协议，后切进程内调用 | ping/capabilities/scene 接口可用 |
| [packages/editor/src/renderer/panels/Viewport.tsx](packages/editor/src/renderer/panels/Viewport.tsx) | 视口与输入 | GuavaUI/Widgets/ViewportWidget.swift | 输入路由重建，viewport 纹理采样，移除像素流路径 | 视口交互正常，无 CPU readback |
| [packages/editor/src/renderer/panels/*](packages/editor/src/renderer/panels) | 业务面板视图 | GuavaUI/EditorPanels/* | PanelModel 与 GuavaUI Widget 分离 | 面板数据驱动渲染 |

## 5. 能力迁移优先级

## P0 必须先迁

1. Viewport（wgpu 纹理采样 + 输入路由）。
2. SceneHierarchy（TreeView widget）。
3. Inspector（PropertyGrid widget）。
4. Console（滚动列表 + 过滤）。
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
| E2 (3天) | E2-T1 GuavaUI 2D 渲染器（矩形 + 圆角矩形 + 文字） | packages/guava-next/Sources/GuavaUI/Render/* | 800 | wgpu 集成完成 | swift test --filter UIRenderTests |
| E2 | E2-T2 Yoga 布局集成 + ViewTree | packages/guava-next/Sources/GuavaUI/Layout/* | 500 | E2-T1 | swift test --filter LayoutTests |
| E3 (3天) | E3-T1 基础 Widget（Label/Button/TextField/Slider） | packages/guava-next/Sources/GuavaUI/Widgets/* | 600 | E2-T2 | swift test --filter WidgetTests |
| E3 | E3-T2 DockContainer + 拖拽分割 | packages/guava-next/Sources/GuavaUI/Dock/* | 450 | E3-T1 | swift test --filter DockTests |
| E4 (3天) | E4-T1 ViewportWidget（纹理采样 + 输入路由） | packages/guava-next/Sources/GuavaUI/Widgets/ViewportWidget.swift | 360 | E3-T2 + 引擎 viewport 纹理 | swift test --filter ViewportWidgetTests |
| E4 | E4-T2 TreeView + PropertyGrid | packages/guava-next/Sources/GuavaUI/Widgets/TreeView.swift + PropertyGrid.swift | 520 | E3-T1 | swift test --filter TreeViewTests |
| E5 (2天) | E5-T1 SceneHierarchy + Inspector 面板 | packages/guava-next/Sources/GuavaUI/EditorPanels/* | 400 | E4-T2 + E1-T2 | swift test --filter PanelRenderingTests |
| E5 | E5-T2 Console 面板 + 日志事件 | packages/guava-next/Sources/GuavaUI/EditorPanels/Console* | 240 | E1-T1 | swift test --filter ConsolePanelTests |
| E6 (2天) | E6-T1 AssetBrowser 最小可用 | packages/guava-next/Sources/GuavaUI/EditorPanels/AssetBrowser* | 340 | E5-T1 | swift test --filter AssetBrowserTests |
| E6 | E6-T2 端到端回归脚本 | packages/guava-next/Scripts/editor-smoke.sh | 120 | E6-T1 | bash packages/guava-next/Scripts/editor-smoke.sh |

## 7. 验收标准（必须可执行）

1. 启动与渲染：swift run EditorApp（SDL3 窗口打开，GuavaUI 渲染面板，viewport 显示 3D 场景）。
2. 核心 Widget 回归：swift test --filter WidgetTests。
3. 视口输入回归：swift test --filter ViewportWidgetTests。
4. Dock 布局回归：swift test --filter DockTests。
5. 协议兼容回归：swift test --filter RpcCompatTests。
6. 端到端 smoke：bash packages/guava-next/Scripts/editor-smoke.sh。

## 8. 风险与缓解

风险 1：GuavaUI 渲染器实现复杂度超预期。

缓解：Phase 0 只实现 5 种图元（填充矩形、圆角矩形、边框、文字四边形、图片四边形），足以渲染所有编辑器面板。不实现通用矢量图形。

风险 2：文字渲染跨平台一致性。

缓解：macOS 首版用 CoreText 做 glyph 光栅化（最快出结果），后续迁移到 HarfBuzz + FreeType 统一跨平台。Glyph atlas 层抽象为协议，两套实现可切换。

风险 3：Panel 业务与视图耦合过深。

缓解：先提取 PanelModel（纯数据），再用 GuavaUI Widget 做视图；不在 Widget 中直接读取 Engine 对象。

风险 4：RPC 到同进程总线切换时行为不一致。

缓解：先做 RpcCompatClient，保持 method 契约；对关键方法做录制回放测试。

风险 5：Viewport 输入路由回归。

缓解：保留旧输入语义映射表，逐项比对鼠标事件、框选、拾取结果。

风险 6：Docking 系统拖拽交互体验。

缓解：DockModel 数据结构（split/leaf 树）先固化并通过单元测试，拖拽视觉反馈分阶段迭代。

## 9. GuavaUI 框架详细设计

详见 [guava-ui-blueprint.md](guava-ui-blueprint.md)。

## 10. 本周开工清单

1. 建立 EditorCore 模块骨架。
2. 实现 DockModel 和布局序列化。
3. 实现 GuavaUI 2D 渲染器最小原型（圆角矩形 + 文字）。
4. 集成 Yoga 布局引擎。
5. 实现 RpcCompatClient 的 ping/capabilities/scene.getHierarchy。
6. 写 4 个基础测试：DockModelTests、RpcCompatTests、UIRenderTests、LayoutTests。
