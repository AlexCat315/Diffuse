# Guava Engine 项目文档

> AI-Native 游戏引擎与影视创作编辑器，基于 Swift 构建

## 一、项目概述

Guava Engine 是由 AlexCat315 开发的 AI-Native 游戏引擎与影视创作编辑器。项目采用 Swift 作为主要开发语言，目标是构建一个现代化、可扩展的实时渲染与创作工具。

### 技术栈

| 层级 | 技术 |
|------|------|
| 语言 | Swift 6.0 |
| 渲染后端 | WGPU (WebGPU) |
| UI 布局 | Yoga (Facebook) |
| 文本渲染 | FreeType + HarfBuzz |
| 平台 | macOS 14+ |

---

## 二、架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                        Editor                                │
│                    (GuavaEditor)                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    EditorCore                        │   │
│  │  EditorApplication / EditorStore / EditorSceneAdapter │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────────────────┬──────────────────────────────────┘
                           │ 依赖
           ┌───────────────┴───────────────┐
           ▼                               ▼
┌──────────────────────┐       ┌──────────────────────┐
│      GuavaUI         │       │       Engine          │
│   (UI 框架)          │       │    (引擎核心)          │
└──────────────────────┘       └──────────────────────┘
```

---

## 三、Engine（引擎核心）

**路径**: `/Engine/`

Engine 是底层渲染和运行时库，提供核心引擎功能。

### 3.1 模块清单

| 模块 | 描述 |
|------|------|
| `EngineKernel` | 核心引擎生命周期管理，处理 boot → tick → shutdown 流程 |
| `EngineCore` | 引擎核心数据类型与协议定义 |
| `RHIWGPU` | WebGPU 渲染接口抽象层 |
| `RenderBackend` | 渲染后端实现 |
| `SceneRuntime` | 场景运行时，管理实体、世界、命令缓冲 |
| `AssetPipeline` | 资源管线，处理资源加载与转换 |
| `CapabilityRuntime` | 能力运行时，管理系统能力 |
| `IntentRuntime` | 意图运行时，处理用户意图 |
| `ObservationBus` | 观察者总线，事件分发系统 |
| `SequenceRuntime` | 序列运行时，影视时间线 |
| `ScriptRuntime` | 脚本运行时 |
| `PlatformShell` | 平台外壳，操作系统抽象 |

### 3.2 EngineKernel 帧循环

`EngineKernel` 定义了引擎的帧循环阶段：

```swift
public enum EngineKernelPhase: CaseIterable, Sendable {
    case boot      // 启动阶段
    case input    // 输入处理
    case simulation  // 仿真计算
    case script   // 脚本执行
    case renderPrepare  // 渲染准备
    case renderSubmit   // 渲染提交
}
```

每帧按顺序执行上述阶段，生成 `EngineKernelFrameReport` 报告。

### 3.3 SceneRuntime

场景运行时核心结构：

```swift
public struct SceneRuntime {
    private var world = RuntimeWorld()
    private var commandBuffer = RuntimeCommandBuffer()
    private var schedule = RuntimeWorldSchedule()
    
    // 快照与摘要
    public var snapshot: SceneRuntimeSnapshot
    public var summary: RuntimeWorldSummary
    
    // 渲染资源
    public var extractedRenderScene: ExtractedRenderSceneResource?
    public var renderScene: RenderScene
}
```

---

## 四、GuavaUI（UI 框架）

**路径**: `/GuavaUI/`

GuavaUI 是声明式 UI 框架，提供类似 SwiftUI 的组合式 API。

### 4.1 模块清单

| 模块 | 描述 |
|------|------|
| `GuavaUICompose` | 声明式 API、状态系统、modifier、布局组合器 |
| `GuavaUIRuntime` | UI 运行时，视图管理与渲染 |
| `GuavaUIApp` | 应用宿主，负责窗口与 WGPU Surface 装配 |
| `GuavaUIDevTools` | 开发工具（调试、预览等） |
| `GuavaUIDemo` | 示例演示程序 |
| `CYoga` | Yoga C 库绑定（静态库） |
| `CFreeType` | FreeType 字体绑定 |
| `CHarfBuzz` | HarfBuzz 文本 shaping 绑定 |
| `Font` | 字体管理模块 |

### 4.2 架构特点

- **声明式 UI**: 类似 SwiftUI 的组合式 API
- **多平台渲染**: 基于 WGPU 的跨平台渲染能力
- **模块化设计**: Compose / Runtime / App 分离

---

## 五、Editor（编辑器）

**路径**: `/Editor/`

Editor 是顶层编辑器应用，集成 Engine 与 GuavaUI。

### 5.1 模块清单

| 模块 | 描述 |
|------|------|
| `EditorApp` | 可执行程序入口 |
| `EditorCore` | 编辑器核心：状态管理、Store、引擎宿主 |

### 5.2 EditorApplication

```swift
public final class EditorApplication {
    public let engine: EngineHost        // 引擎宿主
    public let projectDirectory: String  // 项目目录
    public let store: EditorStore        // 编辑器状态存储
    public let inputState: InputState     // 输入状态
    public let scene: EditorSceneAdapter  // 场景适配器
    
    private let observationBus: ObservationBus
    private let intentCoordinator: IntentRuntimeCoordinator
    private let events: PlatformEventBridge
}
```

### 5.3 职责

- 管理 Engine 生命周期（boot / tick / shutdown）
- 协调 UI（GuavaUIApp）与引擎仿真
- 处理平台事件输入
- 管理视口与渲染表面状态

---

## 六、依赖关系

```
Editor
├── EditorCore
│   ├── Engine (EngineKernel, SceneRuntime, AssetPipeline, ...)
│   └── GuavaUI (GuavaUICompose, GuavaUIRuntime, GuavaUIApp)
│
GuavaUI
├── Engine (RHIWGPU, RenderBackend, ObservationBus, ...)
├── swift-log
├── CYoga (vendored)
├── CFreeType (vendored)
└── CHarfBuzz (vendored)
│
Engine
├── swift-log
└── wgpu (vendored)
```

---

## 七、构建系统

### 7.1 构建工具

- **Swift Package Manager**: 主构建系统
- **CMake**: 底层 C/C++ 库构建（wgpu, yoga, freetype, harfbuzz）
- **Ninja**: CMake 生成后端

### 7.2 平台要求

- macOS 14+ (Sonoma)
- Swift 6.0

### 7.3 构建命令

```bash
# Editor
cd Editor && swift build

# Engine  
cd Engine && swift build

# GuavaUI
cd GuavaUI && swift build
```

---

## 八、文档索引

| 文档 | 路径 | 描述 |
|------|------|------|
| AI Native Capability Catalog | `docs/ai-native-capability-catalog.md` | AI 能力目录 |
| UI Blueprint | `docs/guava-ui-blueprint.md` | UI 架构蓝图 |
| UI Design System | `docs/guava-ui-design-system.md` | UI 设计系统 |
| Dock Component | `docs/components/dock.md` | 停靠组件 |
| Scene Runtime Design | `docs/ai-native-scene-model-design.md` | 场景模型设计 |
| Observation Bus Design | `docs/ai-native-observation-bus-design.md` | 观察者总线设计 |

---

## 九、总结

Guava Engine 是一个现代化的 Swift 原生游戏引擎与编辑器项目：

1. **分层架构**: Editor → GuavaUI → Engine，职责清晰
2. **现代化技术**: Swift 6.0 + WGPU + 并发原生
3. **模块化设计**: 每个模块可独立使用
4. **AI-Native**: 内置 AI 能力支持

项目当前处于 WIP 阶段，API 可能会有突破性变更。