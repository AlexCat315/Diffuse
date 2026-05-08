# Guava 总路线图

> 单一入口文档。描述三个包的推进顺序、并行关系和交付里程碑。
> 各包详细技术设计见 [engine-swift-wgpu-rewrite-blueprint.md](engine-swift-wgpu-rewrite-blueprint.md)、[guava-ui-blueprint.md](guava-ui-blueprint.md)、[editor-blueprint.md](editor-blueprint.md)。
> AI 原生架构总入口见 [architecture.md](architecture.md)。
>
> 文档分四类：
> - **基础三包**（Engine / GuavaUI / Editor）：M0–M6
> - **AI 原生交互层**（CapabilityGraph / IntentIR / TransactionIR / Observation Bus / Memory / Confirmation UI / Semantic Pipeline / Scene-from-Image）：M7 起逐步引入
> - **影视生产管线**（Sequencer / Cinematic Renderer / Color / EXR / Denoise / Render Farm）：M7 起与 AI 层并行推进
> - **域工作流**（Game / Film）：M9 起在前两类之上组装

---

## 依赖关系一览

```
Editor ──────────────────────────────────────────────► 依赖 GuavaUI（UI 组件）
Editor ───────────────────────────────────────────────► 依赖 Engine（场景/资产）
GuavaUI ──────────────────────────────────────────────► 依赖 Engine（wgpu device / surface）
Engine ──（运行时注入，InGameUIProviding）──────────────► 反向依赖 GuavaUI（游戏内 UI）

AI 原生交互层 ────────────────────────────────────────► 依赖 Editor（Transaction 入口、Confirmation UI 宿主）
AI 原生交互层 ────────────────────────────────────────► 依赖 Engine（SceneRuntime / SemanticMemoryStore / Observation Bus 内核）
影视生产管线 ─────────────────────────────────────────► 依赖 Engine 渲染深度（多线程 / RenderBackend / 资产）
影视生产管线 ─────────────────────────────────────────► 依赖 AI 原生 SequenceDocument（剪辑模型）
Game/Film 工作流 ──────────────────────────────────────► 同时依赖 AI 原生交互层 + 影视生产管线
```

**关键约束**

| 约束 | 说明 |
|------|------|
| GuavaUI 要渲染，只需要 `WGPUDevice` + `WGPUSurface` | RHIWGPU 已完成，不需要等 Engine 3D 渲染 |
| GuavaUI Phase 1–4（NodeTree/Layout/Text）不需要 GPU | 可以比 Engine Phase 1 更早开始 |
| Editor UI 面板全部阻塞于 GuavaUI Phase 6 | GuavaUI Compose API 完成前，Editor 界面无法开工 |
| Engine 游戏内 UI（菜单/HUD）阻塞于 GuavaUI Phase 7 | 通过 `InGameUIProviding` 协议注入，不产生循环依赖 |
| AI 原生交互层最早在 M7 启用 | 必须先有 Editor 的 Inspector / Console 与 Engine 的 SceneRuntime（M3 + M4 的产出） |
| 任何 AI 写操作必须经 Transaction IR + AmbiguityScorer | 总纲 §11；自由 patch 一律拒绝 |
| 任何 AI 推断的语义都标 `inferred` | 升格为 `authored` 唯一通道是 `asset.promote_inferred_to_authored` |
| 向量 / 渲染图 / embedding 不进 LLM prompt | 见 `ai-native-semantic-pipeline-design.md` §2.4.1 |
| 影视离线渲染最早在 M7 启用 | 需要 Engine Phase 5（资产管线）与 SequenceDocument 草版 |
| 影视渲染必须经 ColorPipeline (OCIO + ACES) | 编辑器显示与 EXR 输出共用一套色彩管理 |
| Render Farm 跨进程通信走 Observation Bus Bridge | 不允许新增独立 IPC 协议 |

---

## 并行轨道

M0–M6 仅两条并行轨；M7 起增加两条新轨。

```
M0–M6
轨道 A（Engine 渲染深度）   Engine Phase 1 → 2 → 3 → 4 → 5 → 6
轨道 B（UI 基础设施）       GuavaUI Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 7.5 → 8
                                                                      └──► Editor Phase 1 → 2 → 3 → 4 → 5 → 6

M7 起新增
轨道 C（AI 原生交互层）     Engine Phase 8 + Editor 的 AI 集成
                            （CapabilityRuntime / IntentIR / TransactionIR / Observation Bus / Confirmation UI
                             → SemanticPipeline → SceneFromImage → ContextMemoryIndex）
轨道 D（影视生产管线）       Engine Phase 7 + 11
                            （Sequencer / CinematicRenderer / ColorPipeline / ImageIO / DenoiseBridge → RenderFarm）
```

`轨道 A` 和 `轨道 B Phase 1–4` 互相独立，可以同时推进。
`轨道 B Phase 5`（DrawList wgpu 渲染）需要 `轨道 A` 的 wgpu 初始化链路可用（已满足，RHIWGPU 完整）。
`Editor Phase 1` 需要 `轨道 B Phase 5` 完成。
`轨道 C` 与 `轨道 D` 在 M6 完成后启用，二者大量共享 Observation Bus 与 Transaction IR，约定：
- C 先实现 Bus / IntentIR / TransactionIR / Confirmation UI 的进程内骨架
- D 同期实现 Sequencer 与 CinematicRenderer 的最小可用版
- 二者首次交汇在 M9（CapabilityGraph 注册影视相关 verb）与 M11（Render Farm 走 Bus Bridge）

---

## 里程碑

### M0 — 地基 ✅ 已完成

**交付状态**：三包 SwiftPM 结构就位，基础依赖图正确，`swift build` 全部通过。

| 包 | 完成内容 |
|----|---------|
| Engine | RHIWGPU / PlatformShell / EngineCore / EngineKernel 完成；RenderBackend / SceneRuntime / ScriptRuntime 占位 |
| GuavaUI | Package.swift + 占位文件 |
| Editor | EditorCore 完整（状态机、DockModel、PanelRegistry、RPC）；EditorApp 占位 |

**验收**：
```bash
cd Engine  && swift build   # 0 error
cd GuavaUI && swift build   # 0 error
cd Editor  && swift build   # 0 error
```

---

### M1 — 首个 3D 帧 + UI 数据层

**目标**：Engine 渲染出第一个真实 3D 场景；GuavaUI 的节点树和状态系统可以独立运行和测试。

**并行推进**：

#### 轨道 A：Engine Phase 1（真实 wgpu 3D 渲染）✅ 已完成

`WGPURenderer` 已实现完整渲染管线：Lambert 光照 WGSL shader、深度缓冲、OBJ 网格上传、
5 个实例（1 个 FinalBaseMesh.obj + 4 个环绕旋转的 cube）、透视摄像机、每帧动画。

验收（已通过）：
```bash
cd Editor && swift build   # Build complete
cd Editor && swift run EditorApp
# [WGPURenderer] scene built: meshes=["builtin.cube", "FinalBaseMesh.obj"] instances=5
# [WGPURenderer] surface ready, size=(width: 2560, height: 1440), pipeline=true, depth=true
```

#### 轨道 B：GuavaUI Phase 1–2（NodeTree + Recomposer）✅ 已完成

必须实现的文件：

```
GuavaUI/Sources/GuavaUIRuntime/
├── Node.swift
├── NodeTree.swift
├── PlatformHost.swift
├── SDL3PlatformHost.swift
├── Recomposer.swift
├── State.swift
├── Binding.swift
└── CompositionLocal.swift
```

验收：
```bash
cd GuavaUI && swift test --filter NodeTreeTests
cd GuavaUI && swift test --filter RecomposerTests
# 状态变化只触发脏子树，不触发全树重组
```

**M1 完成标志**：轨道 A 和轨道 B 测试全部通过，可以独立演示。

---

### M2 — UI 可见帧

**目标**：GuavaUI 能打开窗口并在屏幕上渲染出真实文本和矩形。✅ 已完成

**依赖**：M1 两条轨道都完成。

**顺序执行**（轨道 B 内部有依赖）：

#### GuavaUI Phase 3：Yoga 布局

```
GuavaUI/Sources/
├── CYoga/                     # systemLibrary, pkgConfig: "yoga"
└── GuavaUIRuntime/
    ├── LayoutNode.swift
    ├── FlexProps.swift
    └── LayoutPass.swift
```

#### GuavaUI Phase 4：HarfBuzz + FreeType 文本 ✅ 已完成

```
GuavaUI/Sources/
├── CHarfBuzz/
├── CFreeType/
└── GuavaUIRuntime/
    ├── FontAtlas.swift
    ├── TextShaper.swift
    └── TextLayout.swift
```

#### GuavaUI Phase 5：DrawList + wgpu 渲染器 ✅ 已完成

```
GuavaUI/Sources/GuavaUIRuntime/
├── DrawList.swift
├── DrawListRenderer.swift
├── UIVertex.swift
└── UIShader.metal
```

> DrawListRenderer 接收外部注入的 `WGPUDevice`，与 Engine 共享同一 GPU 设备，不重复初始化。

验收：
```bash
cd GuavaUI && swift run GuavaUIDemo
# 打开窗口，渲染圆角矩形 + 中文文本，FPS ≥ 60，关闭无崩溃
```

**M2 完成标志**：GuavaUI 可以独立运行并可见，Engine 3D 场景也可以独立运行。

---

### M3 — 编辑器界面成形

**目标**：Editor 切换到真实 GuavaUI，核心三块面板（Hierarchy / Inspector / Console）可用。

**依赖**：M2 完成。

**窗口范围**：M3 只交付**单窗口编辑器**。多窗口（撕下面板、独立预览窗）按
`guava-ui-blueprint.md §9.4` 的窗口策略推迟到 M4–M5；当期所有 Runtime 接口
必须满足"窗口前瞻约束"（无 `.shared` 单例、`InputEvent` 携带 `WindowID`、
`EventDispatcher` 绑定单棵 `NodeTree`），以避免后期重构。

**轨道 B：GuavaUI Phase 6 → 7 → 7.5**

> Phase 6 详细设计见 `docs/guava-ui-phase6-design.md`。
> Phase 7.5 详细设计见 `docs/guava-ui-phase7.5-design.md`，收尾总结见 `docs/guava-ui-phase7.5-summary.md`（**已完成，179/179 测试通过**）。
> Phase 8 详细设计见 `docs/guava-ui-phase8-design.md`。

Phase 6（Compose API + 基础组件）：
```
GuavaUI/Sources/GuavaUICompose/
├── View.swift / ViewBuilder.swift / Modifier.swift
├── BuiltinModifiers.swift
├── Box.swift / Row.swift / Column.swift
├── Text.swift / Button.swift / Image.swift
├── Spacer.swift / Divider.swift / ScrollView.swift
```

Phase 7（桌面工具组件）：
```
GuavaUI/Sources/GuavaUICompose/
├── List.swift             # 虚拟化列表
├── Tree.swift             # 可折叠树
├── Tabs.swift / SplitView.swift
├── PropertyGrid.swift
├── ContextMenu.swift
├── DockContainer.swift / Panel.swift
└── ViewportHost.swift
```

Phase 7.5（Theme + DefaultStyles，必做，阻塞 Editor 接入）：
```
GuavaUI/Sources/GuavaUICompose/
├── Theme/
│   ├── Theme.swift
│   ├── ColorScheme.swift / Typography.swift / SpacingScale.swift / RadiusScale.swift / ElevationScale.swift
│   ├── DefaultDarkTheme.swift / DefaultLightTheme.swift
│   └── ThemeEnvironment.swift   # CompositionLocal<Theme>
├── Style/
│   ├── ButtonStyle.swift / PrimaryButtonStyle.swift / SecondaryButtonStyle.swift / GhostButtonStyle.swift
│   ├── TextFieldStyle.swift / DefaultTextFieldStyle.swift
│   ├── PanelStyle.swift / DefaultPanelStyle.swift
│   └── ListRowStyle.swift / TreeRowStyle.swift
└── Foundation/
    ├── SemanticColor.swift  # Color.surface / .onSurface / .accent / .border
    └── SemanticFont.swift   # Font.title / .body / .caption / .mono
```

**Editor Phase 1–2（接入 GuavaUI，核心面板）**

```
Editor/Sources/EditorApp/
├── MainWindow.swift
└── panels/
    ├── SceneHierarchyPanel.swift
    ├── InspectorPanel.swift
    └── ConsolePanel.swift
```

```swift
// EditorApplication.swift 关键改动
// 替换 MetalPlaceholderRenderer：
let drawListRenderer = DrawListRenderer(device: wgpuDevice, surface: surface)
InGameUIRegistry.shared.provider = GuavaUIProvider(renderer: drawListRenderer)
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 编辑器窗口出现三块面板，选中 Hierarchy 节点 → Inspector 刷新
# MetalPlaceholderRenderer 从代码中消失
# 调用点不再出现裸 Color(r:g:b:) 与 .system(size:) 字面量；
# 一行 .theme(DefaultDarkTheme()) 即可换肤
```

**M3 完成标志**：编辑器可以日常使用，UI 层完全由 GuavaUI 驱动，默认外观达到与 SwiftUI / Compose 同一档次。

---

### M4 — 完整编辑工作流

**目标**：编辑器支持拖拽 Asset 到 Viewport，3D gizmo 可用，Engine 多线程渲染稳定。

**并行推进**：

#### 轨道 A：Engine Phase 2–3（多线程渲染 + ECS）

Phase 2（多线程）✅ 已完成：
```
Engine/Sources/RenderBackend/
├── RenderPacket.swift
Engine/Sources/EngineCore/
├── RingBuffer.swift
├── SimulationThread.swift
├── RenderThread.swift
├── LockedState.swift
└── EngineCore.swift
```

> 现状：`EditorApplication` 不再直接驱动 `WGPURenderer`；主线程只提交输入和窗口尺寸，Simulation 发布 `RenderPacket`，Render 线程消费最新可用快照。

Phase 3（ECS + 物理）：
```
Engine/Sources/SceneRuntime/
├── ECS.swift / Components.swift / SceneGraph.swift
Engine/Sources/Bridge/CPhysicsBridge/
├── include/physics_bridge.h
└── physics_bridge.cpp        # Jolt Physics
```

#### Editor Phase 3–4（Asset Browser + Viewport）

Phase 3（Asset Browser）：
```
Editor/Sources/EditorCore/
├── ProjectManager.swift
└── AssetImporter.swift
Editor/Sources/EditorApp/panels/
└── AssetBrowserPanel.swift
```

Phase 4（Viewport + Gizmo）：
```
Editor/Sources/EditorCore/
├── GizmoSystem.swift
└── ToolMode.swift
Editor/Sources/EditorApp/panels/
└── ViewportPanel.swift        # ViewportHost + gizmo overlay
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 能打开项目目录，拖拽 .obj 到 Viewport，出现网格
# 点击选中物体，Move gizmo 显示并可拖拽，Undo 还原
```

**M4 完成标志**：基础编辑工作流通畅，Engine 帧率稳定 ≥ 240fps（Sim 固定步长 4ms）。

---

### M5 — 游戏内 UI + 资产管线完整

**目标**：Engine 通过 `InGameUIProviding` 注入 GuavaUI，运行模式下游戏内菜单/HUD 可用；GLTF 2.0 可导入。

**并行推进**：

#### 轨道 A：Engine Phase 4–5（脚本 + 资产 + 游戏内 UI）

Phase 4（脚本运行时）：
```
Engine/Sources/ScriptRuntime/
├── ScriptContext.swift / ScriptComponent.swift / ScriptLifecycle.swift
```

Phase 5（资产管线补全）：
```
Engine/Sources/Bridge/CGLTFBridge/
Engine/Sources/AssetPipeline/
├── GLTFImporter.swift / TextureImporter.swift
├── MaterialAsset.swift / AssetRegistry.swift / AssetLoader.swift
```

**Engine 游戏内 UI 接入**（此时 GuavaUI 已成熟）：
```swift
// 游戏启动时注入：
InGameUIRegistry.shared.provider = GuavaUIProvider(renderer: drawListRenderer)
// Engine 通过协议调用，永远不 import GuavaUI 模块
```

#### Editor Phase 5（Material Editor + Animation Editor）

```
Editor/Sources/EditorApp/panels/
├── MaterialEditorPanel.swift
└── AnimationEditorPanel.swift
Editor/Sources/EditorCore/
├── MaterialGraph.swift
└── AnimationClipEditor.swift
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 能加载 Box.gltf，纹理正确显示
# 切换到运行模式，游戏内 HUD 由 GuavaUI 渲染，与编辑器 UI 共享同一 GPU pass
```

**M5 完成标志**：Engine + GuavaUI 的双向关系完全打通，资产管线达到生产可用标准。

---

### M6 — 跨平台 + 构建发布

**目标**：Windows / Linux 可编译运行；能打出独立 .app 包。

#### 轨道 A：Engine Phase 6（跨平台移植）

```
Engine/Sources/PlatformShell/
├── Win32Shell.swift
└── LinuxShell.swift
.github/workflows/engine.yml    # CI 矩阵
```

#### Editor Phase 6（Build 系统）

```
Editor/Sources/EditorCore/
├── BuildPipeline.swift
├── BuildConfiguration.swift
└── PlatformExporter.swift
Editor/Sources/EditorApp/
└── BuildSettingsPanel.swift
```

验收：
```bash
# macOS
cd Editor && swift run GuavaEditor
# 点击 Build → 输出目录出现可运行的 .app 包

# CI（GitHub Actions）
# engine.yml 在 ubuntu-latest 和 windows-latest 通过
```

**M6 完成标志**：Guava 作为完整工具链可以对外发布 macOS 版本。

---

### M7 — Sequencer 草版 + 影视渲染地基 + AI 交互层骨架

**目标**：

- 影视侧：Engine 内出现 `SequenceRuntime` 与 `CinematicRenderer` 最小可用版；ImageIO 能写多图层 EXR；ColorPipeline 走通 OCIO + ACES 基线。
- AI 侧：`ObservationBus`（进程内）、`CapabilityRuntime`、`IntentIR/TransactionIR` 执行框架、`MinimalConfirmationUI` 的 Editor 宿主全部可用。

**依赖**：M6 完成（Engine 资产管线 / 三线程 / Editor 完整工作流）。

#### 轨道 D：Engine Phase 7（影视渲染地基）

详细见 engine 蓝图 Phase 7。

```
Engine/Sources/SequenceRuntime/
├── SequenceDocument.swift       # 见 ai-native-sequence-document-design.md
├── ShotEvaluator.swift          # 五步合成规则
└── ClipScheduler.swift

Engine/Sources/CinematicRenderer/
├── PathTracer.swift             # 单 bounce → 多 bounce 渐进版
├── SamplingStrategy.swift
└── AOVRegistry.swift            # diffuse / specular / depth / normal / cryptomatte

Engine/Sources/ColorPipeline/
├── OCIOBridge.swift             # OpenColorIO C ABI
├── ACESConfig.swift
└── ViewTransform.swift

Engine/Sources/ImageIO/
├── EXRWriter.swift              # OpenEXR multipart + AOV
└── EXRReader.swift

Engine/Sources/Bridge/COCIOBridge/
Engine/Sources/Bridge/COpenEXRBridge/
```

#### 轨道 C：Engine Phase 8（AI 交互层骨架）

详细见 engine 蓝图 Phase 8。

```
Engine/Sources/ObservationBus/
├── EventKindRegistry.swift      # 闭集事件类型，见 ai-native-observation-bus-design.md
├── EventEnvelope.swift
├── Publisher.swift
├── Subscriber.swift
├── OutboxRelay.swift
└── ColdLog.swift

Engine/Sources/CapabilityRuntime/
├── CapabilityRegistry.swift     # Validation 层约束来源，见 architecture.md
├── PreconditionChecker.swift
├── EffectAnalyzer.swift
└── ReleasePhaseGate.swift

Engine/Sources/IntentRuntime/
├── IntentIR.swift
├── TransactionIR.swift
├── TransactionExecutor.swift
└── AmbiguityScorer.swift

Editor/Sources/EditorApp/ai/
├── ConfirmationHostPanel.swift  # 见 ai-native-minimal-confirmation-ui-design.md
└── IntentInputPanel.swift
```

**验收**：

```bash
# 影视
cd Engine && swift test --filter SequenceRuntimeTests CinematicRendererTests ColorPipelineTests ImageIOTests
# 单镜头 1024x1024 64spp + Lambert + 单光源 + EXR 输出 + ACES 视图变换可见

# AI
cd Engine && swift test --filter ObservationBusTests CapabilityRuntimeTests IntentRuntimeTests
cd Editor && swift run GuavaEditor
# 用 Inspector 触发一个最小 capability（如 transform.set）
# 走完 IntentIR → AmbiguityScorer → MinimalConfirmationUI（必要时） → TransactionIR → SceneRuntime → Bus 事件回放
```

**M7 完成标志**：

1. CinematicRenderer 能输出可被 DJV / Nuke 正确读取的 ACEScg EXR。
2. Editor 的"AI 操作面板"已存在，但目前只有人类手动构造 IntentIR；LLM 接入留到 M9。
3. Observation Bus cold_log 可回放 transaction stream。

---

### M8 — 影视渲染深度第一阶段

**目标**：CinematicRenderer 进入生产可用门槛——多 bounce 路径追踪、降噪、Cryptomatte、AOV 完整化、deep EXR、Lookdev 工作台；ColorPipeline 支持 LUT / View / Display 全套。

**依赖**：M7 完成。

#### 轨道 D：Engine Phase 10（影视渲染深度）

```
Engine/Sources/CinematicRenderer/
├── BSDFRegistry.swift           # principled BSDF / glass / hair / sss
├── LightTransport.swift         # MIS / ReSTIR / next event estimation
├── VolumeIntegrator.swift
└── ProgressivePass.swift

Engine/Sources/DenoiseBridge/
├── OIDNDenoiser.swift           # Intel Open Image Denoise
└── OptiXDenoiser.swift          # CUDA 平台可选

Engine/Sources/ColorPipeline/
├── DisplayTransform.swift
├── LUTLibrary.swift
└── LookConfig.swift

Engine/Sources/ImageIO/
├── DeepEXRWriter.swift
└── CryptomatteEncoder.swift

Engine/Sources/Bridge/COIDNBridge/
```

#### Editor 影视面板

```
Editor/Sources/EditorApp/film/
├── LookdevPanel.swift           # HDRI / 材质球 / 三视图
├── SequencerPanel.swift         # SequenceDocument 时间线
├── ShotInspectorPanel.swift     # ShotOverride 编辑
├── AOVManagerPanel.swift
└── ColorViewerPanel.swift       # OCIO 视图变换 + scope（waveform / vectorscope）
```

**验收**：

```bash
cd Engine && swift test --filter CinematicRendererTests DenoiseBridgeTests
cd Editor && swift run GuavaEditor
# 加载内置场景 → 渲染 1080p 256spp → OIDN 去噪 → ACEScg EXR + Cryptomatte
# Sequencer 内拖入 3 个 shot 拼接，预览能正确切换镜头
# ColorViewerPanel 切换 sRGB / Rec.709 / ACEScg 视图
```

**M8 完成标志**：

1. 单帧 1080p 256spp + 单 GPU + 去噪后噪点可接受（与 Cycles GPU 同档）。
2. Cryptomatte 可在 Nuke 中正确取 ID。
3. SequenceDocument 时间线在 Editor 内可编辑、可预览。

---

### M9 — Semantic Pipeline B.5 + CapabilityGraph 实例化

**目标**：

- AI 侧：B.5 流水线（StructureExtractor / GeometryAnalyzer / CandidateRegionBuilder / GeometryFingerprinter / SemanticAnalyzer / SemanticMemoryStore）走通；CapabilityGraph 注册第一批 verb（场景 / 资产 / 影视）。
- 工作流侧：Game DiagnosticsView 与 Film Dailies 走 ContextMemoryIndex 折算视图。

**依赖**：M7 + M8 完成。

#### 轨道 C：Engine Phase 9（语义流水线）

```
Engine/Sources/SemanticPipeline/
├── StructureExtractor.swift
├── GeometryAnalyzer.swift
├── CandidateRegionBuilder.swift
├── GeometryFingerprinter.swift     # SHA + spectral hash
├── SemanticAnalyzer.swift          # 多 backend 抽象
├── SemanticMemoryStore.swift       # KNN 检索（向量永不进 LLM）
└── backends/
    ├── HeuristicBackend.swift
    └── VisionBackend.swift         # 留接口；视觉模型按 m9.5 引入

Engine/Sources/ContextMemory/
├── EntryKindRegistry.swift         # Session.WorldView 内部状态，见 architecture.md
├── Reducers.swift
├── MemoryStore.swift
└── SnapshotProvider.swift

Engine/Sources/Bridge/CFingerprintBridge/   # 几何指纹 SIMD 加速
```

#### Capability 注册批次

| 域 | 首批 verb |
|---|---|
| scene | `entity.create` / `entity.delete` / `transform.set` / `parent.reassign` |
| asset | `material.assign` / `import.from_path` / `promote_inferred_to_authored` |
| sequence | `shot.create` / `clip.bind` / `shot.override.set` |
| cinematic | `render.shot` / `render.range` / `aov.toggle` / `lookdev.swap_hdri` |
| diagnostics | `issue.dismiss` / `issue.resolve` |

详细约束定义见 `architecture.md` Validation 层。

**验收**：

```bash
cd Engine && swift test --filter SemanticPipelineTests ContextMemoryTests
# 重导入同一 .obj 后，SemanticMemoryStore 命中率 > 90%（按几何指纹）
# Memory 的 reducer 在 fuzz event 流下纯函数性质成立（同序列重放 bit-equal）

cd Editor && swift run GuavaEditor
# AI 操作面板能列出所有已注册 capability
# 触发 render.shot，CapabilityRuntime 在 ship 阶段会过滤掉 inferred 输入
```

**M9 完成标志**：

1. 第一批 capability 可被 LLM agent 通过结构化调用使用（agent 适配层留待 M10）。
2. Memory 给 LLM 的 `MemorySymbolicView` 可用，且不出现自然语言原文 / 向量 / 图像 bytes。
3. SequenceDocument 的所有 shot/clip 修改全部经 TransactionIR。

---

### M10 — Scene-from-Image + Game/Film 工作流首版

**目标**：

- AI 侧：Phase F 流水线（参考图 → SceneDocument 草稿 → 用户确认 → 写入）跑通；LLM agent 适配层接入 CapabilityGraph。
- 工作流侧：Game 的 PlaytestLoop 与 Film 的 ShotPlanning / Dailies 跑首个端到端样例。

**依赖**：M9 完成。

#### 轨道 C：Engine Phase 10.5（场景图理解）

```
Engine/Sources/SceneFromImage/
├── ReferenceImageIntake.swift      # 见 ai-native-scene-from-image-design.md
├── LayoutInference.swift
├── AssetMatcher.swift              # 走 SceneMemoryStore（pHash + CLIP handle）
├── SceneDraftBuilder.swift
└── SceneMemoryStore.swift

Engine/Sources/AIAgentBridge/
├── LLMTransport.swift              # 进程外 LLM 的 stdio / WebSocket 适配
├── PromptBudget.swift
├── SymbolicViewSerializer.swift    # 复用 Bus / Memory 的 SymbolicView
└── ToolCallDispatcher.swift        # LLM tool_call → IntentIR
```

#### 工作流首版

```
Editor/Sources/EditorApp/game/
├── PlaytestPanel.swift              # 见 ai-native-game-workflow-design.md
└── BalanceReportView.swift

Editor/Sources/EditorApp/film/
├── ShotPlanningPanel.swift
├── DailiesPanel.swift
└── ShotReviewSession.swift
```

**验收**：

```bash
cd Engine && swift test --filter SceneFromImageTests AIAgentBridgeTests
cd Editor && swift run GuavaEditor

# Film 端到端：
# 1. 拖入参考图 → SceneFromImage 给出布局草稿（标 inferred）
# 2. AmbiguityScorer 触发 MinimalConfirmationUI 多次确认
# 3. 用户确认后写入 SceneDocument，ShotPlanning 自动创建 shot 序列
# 4. 渲染 dailies → DailiesPanel 显示 ACEScg 视图与 review notes

# Game 端到端：
# 1. PlaytestPanel 启动一次 5 分钟 sim run
# 2. Telemetry 经 Bus 进 ContextMemoryIndex
# 3. LLM agent 读 MemorySymbolicView 给出 BalanceReport（结构化），不出现自由叙事
```

**M10 完成标志**：

1. 参考图 → 可编辑 SceneDocument 的最短路径打通。
2. 至少一个商业 LLM 能通过 tool_call 调用 CapabilityGraph 全部首批 verb。
3. ShotPlanning 与 PlaytestLoop 的诊断信息全部走 ContextMemoryIndex，没有旁路。

---

### M11 — Render Farm + 跨机协作 + 长会话 Memory

**目标**：

- 影视侧：RenderFarm orchestrator 与 worker 完成；远端节点经 Observation Bus Bridge 上报进度与 EXR handle；可在编辑器内提交一个 sequence 的全帧渲染。
- AI 侧：ContextMemoryIndex 跨会话对账；ObservationBus 跨进程 / 跨机 bridge 启用；用户可关掉编辑器再重连 agent，上下文不丢失。

**依赖**：M9 + M10 完成。

#### 轨道 D：Engine Phase 11（Render Farm）

```
Engine/Sources/RenderFarm/
├── FarmOrchestrator.swift
├── FarmWorker.swift                # 远端节点常驻进程
├── JobScheduler.swift              # 按 shot / range / aov 切分
├── ResultCollector.swift           # EXR handle 入 ImageStore
└── ProgressBridge.swift            # 走 ObservationBus.runtime.metric.sampled

Engine/Sources/ObservationBus/
├── BridgeNode.swift                # 跨进程 / 跨机
├── BridgePolicy.swift              # cross_process_allowed 校验
└── ResyncProtocol.swift
```

#### Editor 农场面板

```
Editor/Sources/EditorApp/film/
├── FarmDashboardPanel.swift        # job / worker / queue 监控
└── FarmJobSubmissionDialog.swift
```

**验收**：

```bash
# 单机两进程
cd Engine && swift run FarmWorker --listen 127.0.0.1:7000
cd Editor && swift run GuavaEditor
# 在 FarmDashboardPanel 提交 100 帧 sequence
# 编辑器关闭再重启 agent，ContextMemoryIndex 对账完成后能列出昨天未 resolve 的 confirmation

# 跨机
# 在第二台机器启动 FarmWorker，编辑器自动发现并分配 job
# Bridge 断连恢复后，订阅者状态完整恢复，无重复消费
```

**M11 完成标志**：

1. 单 sequence 多帧渲染可由 farm 驱动，结果在编辑器内可直接进 DailiesPanel。
2. 长会话（关闭—重开）下 agent 上下文连续，且 SymbolicView 不出现陈旧条目。
3. Observation Bus 跨机 bridge 在断连—重连场景下达成 §17 验收（见 `ai-native-observation-bus-design.md`）。

---

## 推进顺序速查表

| 阶段 | Engine | GuavaUI | Editor | 能做什么 |
|------|--------|---------|--------|---------|
| **M0** ✅ | Phase 0 | Phase 0 | Phase 0 | 三包构建通过 |
| **M1** | Phase 1 ✅ | Phase 1–2 | — | 3D 帧可见；NodeTree/State 单测通过 |
| **M2** | — | Phase 3–5 | — | GuavaUI 窗口出现文本 |
| **M3** | — | Phase 6 → 7 → 7.5 | Phase 1–2 | 编辑器界面成形（含 Theme + DefaultStyles） |
| **M4** | Phase 2–3 | — | Phase 3–4 | 完整编辑工作流 |
| **M5** | Phase 4–5 | — | Phase 5 | 游戏内 UI；GLTF 资产 |
| **M6** | Phase 6 | — | Phase 6 | 跨平台；构建发布 |
| **M7** | Phase 7（影视地基）+ Phase 8（AI 骨架） | — | AI 操作面板 + Sequencer 雏形 | 单镜头 EXR 输出；手工构造 IntentIR 走通 |
| **M8** | Phase 10（影视深度） | — | Lookdev / Sequencer / AOV / Color 面板 | 1080p 256spp + 去噪 + Cryptomatte 生产可用 |
| **M9** | Phase 9（Semantic Pipeline + Memory） | — | Capability 列表面板 | 第一批 capability 注册；Memory 视图可给 LLM |
| **M10** | Phase 10.5（SceneFromImage + AgentBridge） | — | Game/Film 工作流首版面板 | 参考图 → SceneDocument；LLM agent 端到端 |
| **M11** | Phase 11（Render Farm + Bus Bridge） | — | Farm Dashboard | 跨机渲染；长会话 Memory 对账 |

**推进建议（单人）**：先走完 M1 轨道 A（看到 3D 帧，验证 wgpu 链路），再全力推 M1 轨道 B → M2（GuavaUI 基础设施），之后 M3 GuavaUI → Editor 的路是连续的，一气呵成。Engine 的深度工作（ECS、物理、脚本）放在 M3 完成后的 M4 阶段，此时 Editor 已经可用，等待的不是 UI，而是功能深度。

M6 完成后进入 M7。M7 强烈建议把"AI 骨架"与"影视地基"同周期推进——它们共享 ObservationBus 与 TransactionIR，分开做会重复设计。M8 与 M9 可并行：影视深度（M8）是渲染算法工作，AI 语义（M9）是数据流水线，二者代码路径几乎不交叉。M10 是首次端到端组装，M11 是把所有东西放到跨机长会话场景下加固。

---

## 关键风险与卡点

| 卡点 | 影响 | 应对 |
|------|------|------|
| Yoga C ABI 在 SwiftPM 中 pkg-config 不可用 | GuavaUI Phase 3 阻塞 | 预案：嵌入 Yoga 源码作为 SwiftPM C target，避免外部依赖 |
| HarfBuzz / FreeType 跨平台头文件差异 | GuavaUI Phase 4 阻塞 | 先只在 macOS 上跑，通过 `#if os(macOS)` 隔离平台差异 |
| wgpu-native API 版本升级破坏 RHIWGPU 绑定 | Engine Phase 1 可能返工 | 固定 vendor 版本，升级前跑完整回归 |
| GuavaUI Phase 7（DockContainer）复杂度高 | Editor Phase 1 延迟 | Editor 可以先用 SplitView 模拟布局，DockContainer 在 M3 后期再补 |
| Jolt Physics C++ 编译环境 | Engine Phase 3 阻塞 | 首版用简单 AABB 碰撞替代，Jolt 集成放到 M4 后期 |
| OpenColorIO 跨平台编译与 ACES config 体积 | Engine Phase 7 阻塞 | 仅集成 OCIO 2.x C ABI，自带 ACES studio config 子集；完整 LUT 库异步下载 |
| OpenEXR / Imath 依赖链复杂（zlib / Imath） | Engine Phase 7 阻塞 | 用 vcpkg / SwiftPM C target 静态链接；先不支持 deep EXR，M8 再加 |
| Path tracer 在 wgpu 上无原生 RT | Engine Phase 7 / 10 风险 | 首版走 BVH on compute shader；CUDA / Metal RT 加速作为后端选项，不进 RHI 抽象 |
| OIDN 仅 CPU 加速链 | Engine Phase 10 性能不足 | 单帧降噪走 CPU 异步线程不阻塞 RT；批量去噪在 RenderFarm worker 上做 |
| LLM 接入协议变化频繁 | Engine Phase 10.5 / Editor AI 面板 | 把 LLMTransport 与 ToolCallDispatcher 隔离；面向 CapabilityGraph 而非具体 LLM API |
| Observation Bus 跨机协议字节级编码未定 | Engine Phase 11 阻塞 | M11 之前只做进程内 + 单机跨进程；跨机协议在 M11 之初做选型决议（CBOR vs Cap'n Proto） |
| ContextMemoryIndex 对账成本随事件量增长 | M11 长会话场景 | 强制 cold_log retention 上限；超出窗口的 entry 直接丢弃重新冷启 |
| Capability 设计漂移导致与 schema 文档脱节 | M9 起持续风险 | CI 强制：CapabilityGraph schema 校验 + side_band_emits 与 EventKindRegistry 双向校验 |
