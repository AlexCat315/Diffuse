# Editor 蓝图（Swift + GuavaUI）

## 0. 定位

Editor 是 Guava 引擎的可视化编辑工具，基于 Engine 提供的渲染能力和 GuavaUI 提供的 Compose 组件构建。
它本身不是一个通用库，所有 UI 组件和业务逻辑都服务于编辑器场景。

**依赖关系：**

```
Editor → GuavaUI → Engine
Editor → Engine（直接访问 SceneRuntime、AssetPipeline）
```

## 1. 架构概览

```
Editor/
├── Package.swift
└── Sources/
    ├── EditorCore/          # 状态机、服务注册、RPC、后端逻辑
    │   ├── EditorApplication.swift
    │   ├── EditorState.swift
    │   ├── EditorReducer.swift
    │   ├── DockModel.swift
    │   ├── PanelRegistry.swift
    │   ├── InputState.swift
    │   └── RpcCompatClient.swift
    └── EditorApp/           # 面板 UI（GuavaUI Compose 组件）
        ├── MainWindow.swift
        ├── panels/
        │   ├── SceneHierarchyPanel.swift
        │   ├── InspectorPanel.swift
        │   ├── ConsolePanel.swift
        │   ├── AssetBrowserPanel.swift
        │   ├── ViewportPanel.swift
        │   ├── MaterialEditorPanel.swift
        │   └── AnimationEditorPanel.swift
        └── toolbar/
            └── MainToolbar.swift
```

## 2. 模块职责

| 模块 | 职责 |
|------|------|
| `EditorApplication` | 生命周期：init → runLoop → shutdown。持有所有服务引用。 |
| `EditorState` | 只读快照，代表编辑器当前状态（选中对象、活跃面板、工具模式等）。 |
| `EditorReducer` | 纯函数：`(EditorState, EditorAction) → EditorState`，驱动状态变迁。 |
| `DockModel` | 面板布局树，持久化到 `~/.guava/layout.json`。 |
| `PanelRegistry` | 面板 ID → 面板工厂函数注册表，支持插件扩展。 |
| `InputState` | 键盘/鼠标原始状态快照，由 SDL3 事件填充。 |
| `RpcCompatClient` | 与外部工具（语言服务器、调试器）通信的协议适配层。 |

## 3. 状态机

```
Initializing
    │ engine ready
    ▼
Idle ◄─────────── PlayStopped
    │ play()         │ stop()
    ▼                │
Playing ─────────────┘
    │ pause()
    ▼
Paused ──► Playing (resume)
```

状态转换全部通过 `EditorReducer` 处理，禁止 UI 层直接修改 `EditorState`。

## 4. 与 GuavaUI 的集成边界

- EditorApp 中所有 UI 组件均为 GuavaUI `View`。
- `ViewportPanel` 通过 `ViewportHost` 嵌入 wgpu 渲染区域，不绕过 GuavaUI 布局。
- Engine 的 `InGameUIRegistry` 在 Editor 启动时注册 GuavaUI provider，用于运行模式下游戏内 UI。

## 5. 路线图

### Phase 0 — EditorCore 骨架 ✅

**状态：已完成**

| 产出物 | 路径 |
|--------|------|
| 编辑器应用主类 | `EditorCore/EditorApplication.swift` |
| 状态快照 | `EditorCore/EditorState.swift` |
| 状态机 | `EditorCore/EditorReducer.swift` |
| 面板布局模型 | `EditorCore/DockModel.swift` |
| 面板注册表 | `EditorCore/PanelRegistry.swift` |
| 输入状态 | `EditorCore/InputState.swift` |
| RPC 兼容层 | `EditorCore/RpcCompatClient.swift` |

当前限制：UI 层使用 `MetalPlaceholderRenderer`，无真实 GuavaUI 组件。

验收：
```bash
cd Editor && swift build
```

---

### Phase 1 — 接入真实 GuavaUI

**目标：替换 `MetalPlaceholderRenderer`，EditorApp 的窗口由 GuavaUI 驱动。**

前置条件：GuavaUI Phase 5（DrawList + wgpu 渲染器）完成。

修改点：

```swift
// EditorApplication.swift
// 替换：
let renderer = MetalPlaceholderRenderer(surface: surface)
// 改为：
let drawListRenderer = DrawListRenderer(device: wgpuDevice, surface: surface)
InGameUIRegistry.shared.provider = GuavaUIProvider(renderer: drawListRenderer)
```

新增文件：

```
EditorApp/
└── MainWindow.swift     # struct MainWindow: View { DockContainer { ... } }
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 能打开窗口，窗口背景由 GuavaUI DrawListRenderer 绘制，无崩溃
```

---

### Phase 2 — 核心三面板

**目标：SceneHierarchy、Inspector、Console 三块面板可用。**

前置条件：GuavaUI Phase 6（Compose API + 基础组件）完成。

新增文件：

```
EditorApp/panels/
├── SceneHierarchyPanel.swift   # Tree 组件展示场景节点，支持选中/重命名/拖拽
├── InspectorPanel.swift        # PropertyGrid 展示选中对象的组件属性，支持编辑
└── ConsolePanel.swift          # List 展示日志，支持 filter + 清空
```

关键接口：
```swift
// SceneHierarchyPanel.swift
public struct SceneHierarchyPanel: View {
    @Binding var selectedEntity: EntityID?
    var scene: SceneSnapshot          // EditorState 中的只读快照
}

// InspectorPanel.swift
public struct InspectorPanel: View {
    var entity: EntityID?
    var components: [ComponentDescriptor]
    var onEdit: (ComponentEdit) -> Void
}
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 选中场景节点 → Inspector 展示对应属性，修改属性 → State 更新，面板同步刷新
```

---

### Phase 3 — Asset Browser + 项目管理

**目标：资产列表可浏览，支持导入外部文件，双击打开预览。**

前置条件：GuavaUI Phase 6，Engine AssetPipeline GLTF 支持完成。

新增文件：

```
EditorApp/panels/
└── AssetBrowserPanel.swift    # Grid / List 视图，文件树，缩略图，拖拽到场景
EditorCore/
├── ProjectManager.swift       # 项目目录 open/create/recent
└── AssetImporter.swift        # 调用 AssetPipeline，生成 .guavaasset 缓存
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 能打开项目目录，浏览 .obj / .gltf，拖拽到 Viewport 出现占位网格
```

---

### Phase 4 — Viewport + 工具模式

**目标：Viewport 显示真实 3D 场景，支持 Select / Move / Rotate / Scale 工具。**

前置条件：Engine Phase 4（RenderBackend 完整实现）、GuavaUI Phase 7（ViewportHost）完成。

新增文件：

```
EditorApp/panels/
└── ViewportPanel.swift        # ViewportHost + gizmo overlay（Draw2D）
EditorCore/
├── GizmoSystem.swift          # 射线检测、变换 handle 拖拽、snap 功能
└── ToolMode.swift             # enum ToolMode: select/move/rotate/scale
```

关键接口：
```swift
// GizmoSystem.swift
public final class GizmoSystem {
    public func hitTest(ray: Ray, entities: [EntityID]) -> EntityID?
    public func beginDrag(handle: GizmoHandle, startPoint: simd_float3)
    public func updateDrag(currentPoint: simd_float3) -> Transform
    public func endDrag()
}
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 场景中出现网格，点击选中高亮，拖拽 Move gizmo 物体移动，Undo 能还原
```

---

### Phase 5 — Material Editor + Animation Editor

**目标：材质节点图可视化编辑，动画时间轴关键帧编辑。**

前置条件：Phase 4 完成，Engine 材质/动画系统有基础数据结构。

新增文件：

```
EditorApp/panels/
├── MaterialEditorPanel.swift   # 节点图：Shader 节点连线，实时预览球
└── AnimationEditorPanel.swift  # 时间轴：关键帧轨道，曲线编辑器，播放控制
EditorCore/
├── MaterialGraph.swift         # 节点图数据模型（节点、边、参数）
└── AnimationClipEditor.swift   # 关键帧增删改，曲线插值选择
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 能打开材质编辑器，连接节点后 Viewport 中模型实时更新材质
# 能在时间轴添加关键帧，点击播放按钮场景动画运行
```

---

### Phase 6 — Build / Package 系统

**目标：能将项目打包为独立可运行的游戏，支持 macOS，预留 Windows / Linux 位。**

新增文件：

```
EditorCore/
├── BuildPipeline.swift         # 资产打包、代码编译（调用 swiftc）、Bundle 生成
├── BuildConfiguration.swift    # Debug / Release，目标平台，输出路径
└── PlatformExporter.swift      # macOS: .app bundle；未来：Windows exe、Linux bin
EditorApp/
└── BuildSettingsPanel.swift    # 构建配置 UI
```

验收：
```bash
cd Editor && swift run GuavaEditor
# 点击"Build macOS"，等待完成，输出目录出现可直接双击运行的 .app 包
```

## 6. 风险与约束

| 风险 | 缓解措施 |
|------|----------|
| GuavaUI Phase 7 阻塞 Editor Phase 4+ | ViewportPanel 先用最简 NSView 包装，等 GuavaUI 就绪后替换 |
| GizmoSystem 射线检测精度 | 先用 AABB 粗检测，Phase 5 再换三角形精检测 |
| Material 节点图复杂度 | Phase 5 只做预设节点（Diffuse/Normal/Emission），Phase 6+ 才支持自定义 WGSL |
| Build Pipeline 跨平台 | Phase 6 只打 macOS，Windows/Linux 留到 Phase 7+ |
| 性能：大场景 Hierarchy 卡顿 | GuavaUI List 使用虚拟化，只渲染可见行 |
