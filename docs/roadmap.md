# Guava 总路线图

> 单一入口文档。描述三个包的推进顺序、并行关系和交付里程碑。
> 各包详细技术设计见 [engine-swift-wgpu-rewrite-blueprint.md](engine-swift-wgpu-rewrite-blueprint.md)、[guava-ui-blueprint.md](guava-ui-blueprint.md)、[editor-blueprint.md](editor-blueprint.md)。

---

## 依赖关系一览

```
Editor ──────────────────────────────────────────────► 依赖 GuavaUI（UI 组件）
Editor ───────────────────────────────────────────────► 依赖 Engine（场景/资产）
GuavaUI ──────────────────────────────────────────────► 依赖 Engine（wgpu device / surface）
Engine ──（运行时注入，InGameUIProviding）──────────────► 反向依赖 GuavaUI（游戏内 UI）
```

**关键约束**

| 约束 | 说明 |
|------|------|
| GuavaUI 要渲染，只需要 `WGPUDevice` + `WGPUSurface` | RHIWGPU 已完成，不需要等 Engine 3D 渲染 |
| GuavaUI Phase 1–4（NodeTree/Layout/Text）不需要 GPU | 可以比 Engine Phase 1 更早开始 |
| Editor UI 面板全部阻塞于 GuavaUI Phase 6 | GuavaUI Compose API 完成前，Editor 界面无法开工 |
| Engine 游戏内 UI（菜单/HUD）阻塞于 GuavaUI Phase 7 | 通过 `InGameUIProviding` 协议注入，不产生循环依赖 |

---

## 并行轨道

任何时候只有两条并行轨：

```
轨道 A（Engine 渲染深度）   Engine Phase 1 → 2 → 3 → 4 → 5
轨道 B（UI 基础设施）       GuavaUI Phase 1 → 2 → 3 → 4 → 5 → 6 → 7
                                                            └──► Editor Phase 1 → 2 → 3 → 4
```

`轨道 A` 和 `轨道 B Phase 1–4` 互相独立，可以同时推进。
`轨道 B Phase 5`（DrawList wgpu 渲染）需要 `轨道 A` 的 wgpu 初始化链路可用（已满足，RHIWGPU 完整）。
`Editor Phase 1` 需要 `轨道 B Phase 5` 完成。

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

Phase 2（多线程）：
```
Engine/Sources/EngineCore/
├── RenderPacket.swift
├── RingBuffer.swift
├── SimulationThread.swift
└── RenderThread.swift
```

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

**推进建议（单人）**：先走完 M1 轨道 A（看到 3D 帧，验证 wgpu 链路），再全力推 M1 轨道 B → M2（GuavaUI 基础设施），之后 M3 GuavaUI → Editor 的路是连续的，一气呵成。Engine 的深度工作（ECS、物理、脚本）放在 M3 完成后的 M4 阶段，此时 Editor 已经可用，等待的不是 UI，而是功能深度。

---

## 关键风险与卡点

| 卡点 | 影响 | 应对 |
|------|------|------|
| Yoga C ABI 在 SwiftPM 中 pkg-config 不可用 | GuavaUI Phase 3 阻塞 | 预案：嵌入 Yoga 源码作为 SwiftPM C target，避免外部依赖 |
| HarfBuzz / FreeType 跨平台头文件差异 | GuavaUI Phase 4 阻塞 | 先只在 macOS 上跑，通过 `#if os(macOS)` 隔离平台差异 |
| wgpu-native API 版本升级破坏 RHIWGPU 绑定 | Engine Phase 1 可能返工 | 固定 vendor 版本，升级前跑完整回归 |
| GuavaUI Phase 7（DockContainer）复杂度高 | Editor Phase 1 延迟 | Editor 可以先用 SplitView 模拟布局，DockContainer 在 M3 后期再补 |
| Jolt Physics C++ 编译环境 | Engine Phase 3 阻塞 | 首版用简单 AABB 碰撞替代，Jolt 集成放到 M4 后期 |
