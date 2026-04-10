# Guava Editor Qt 迁移方案

## 1. 概述

将 Guava 编辑器从 Electron + React 迁移至 **Qt 6 QML/Quick** 架构。

UI 层全部使用 **QML** 声明式编写，C++ 仅负责：
- QML 后端对象（`EngineClient`、`SceneModel`、`MetalViewportItem` 等）
- Metal/平台原生渲染桥接
- JSON-RPC 通信

**不使用 QWidget**，不使用 `QMainWindow`/`QDockWidget`，完全基于 QML `ApplicationWindow` + `SplitView` + 自定义 panel 组件。

### 为什么选择纯 QML

| QWidget 的问题 | QML 的解法 |
|---|---|
| 命令式 C++ 构建UI，代码冗长 | 声明式 UI，代码量少 50%+ |
| 样式需要 QSS hack | 内置属性绑定 + 组件主题系统 |
| 动画需要手动 QTimer/Property | `Behavior on x` / `NumberAnimation` 一行搞定 |
| Dock 系统僵硬，不支持浮动 panel | 自由实现 Dock/Tab/Float 布局 |
| Inspector 属性编辑需大量 C++ 工厂 | `Loader` + `Component` 按类型动态加载 |
| 未来跨平台移动端不可能 | QML 天然支持触屏/移动 |

### 为什么迁移（从 Electron）

| Electron/CEF 的痛点 | QML 的解法 |
|---|---|
| Viewport 需要 OSR + Metal 合成 hack | `MetalViewportItem` 原生嵌入 Metal 渲染，零拷贝 |
| 浮动层 (弹出菜单、Tooltip) 被 CEF 窗口遮挡 | QML `Menu`/`ToolTip` 天然支持 |
| CEF alpha 透明不可靠 | 无需 alpha 合成，3D 和 UI 在不同层 |
| 打包体积 ~200MB (Chromium) | Qt 静态链接 ~30-50MB |
| 启动速度慢 (V8 + Chromium 初始化) | 原生启动 < 0.5s |
| Web 技术栈调试链路长 | QML Inspector + LLDB 直调 |

### 目标架构

```
┌─────────────────────────────────────────────────────┐
│              GuavaEditor (Qt6 QML/Quick)             │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  main.qml (ApplicationWindow)                │   │
│  │  ┌──────────┐ ┌──────────────────────────┐   │   │
│  │  │ MenuBar  │ │  ToolBar                 │   │   │
│  │  └──────────┘ └──────────────────────────┘   │   │
│  │  ┌──────────────────────────────────────┐    │   │
│  │  │  SplitView (horizontal)              │    │   │
│  │  │  ┌────────┐ ┌──────┐ ┌──────────┐   │    │   │
│  │  │  │ Scene  │ │View- │ │Inspector │   │    │   │
│  │  │  │ Tree   │ │port  │ │          │   │    │   │
│  │  │  │  .qml  │ │.qml  │ │  .qml    │   │    │   │
│  │  │  ├────────┤ │      │ ├──────────┤   │    │   │
│  │  │  │ Assets │ │Metal │ │Console   │   │    │   │
│  │  │  │  .qml  │ │ VPI  │ │  .qml    │   │    │   │
│  │  │  └────────┘ └──────┘ └──────────┘   │    │   │
│  │  └──────────────────────────────────────┘    │   │
│  │  ┌──────────────────────────────────────┐    │   │
│  │  │  StatusBar                           │    │   │
│  │  └──────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  C++ Backend (QML context objects):                 │
│  ┌────────────┐ ┌───────────┐ ┌────────────────┐   │
│  │EngineClient│ │SceneModel │ │MetalViewport   │   │
│  │ (RPC WS)   │ │(QAbstract │ │Item (render)   │   │
│  │            │ │ItemModel) │ │                │   │
│  └────────────┘ └───────────┘ └────────────────┘   │
│  ┌────────────┐ ┌───────────┐                       │
│  │EngineProc  │ │Translator │                       │
│  │(QProcess)  │ │  QML      │                       │
│  └────────────┘ └───────────┘                       │
└─────────────────────────────────────────────────────┘
```

---

## 2. 技术选型

| 组件 | 选择 | 原因 |
|---|---|---|
| **Qt 版本** | Qt 6.8+ | LTS，原生 Metal/Vulkan 支持，Apple Silicon |
| **UI 框架** | **Qt Quick/QML (纯 QML)** | 声明式 UI、属性绑定、动画内置、代码量少 |
| **构建系统** | CMake | 与现有 Engine 构建一致 |
| **3D Viewport** | `MetalViewportItem : QQuickItem` + CAMetalLayer | 零拷贝 Metal 渲染，QML 原生集成 |
| **引擎通信** | QWebSocket + JSON-RPC 2.0 | 复用现有引擎 RPC 协议，零改动 |
| **场景树** | `SceneModel : QAbstractItemModel` + QML `TreeView` | C++ 模型 + QML 视图 |
| **Inspector** | QML `Loader` + 按类型的 `Component` | 声明式属性编辑器 |
| **脚本/代码编辑** | 嵌入 Monaco (QWebEngineView) 或 QML TextEdit | 后期考虑 |
| **节点图编辑器** | QML Canvas / Qt Quick Scene Graph 自研 | 材质图、动画图 |
| **序列化/设置** | QSettings + JSON | 布局持久化用自定义 JSON |
| **国际化** | `qsTr()` + Qt Linguist | QML 内置支持 |
| **主题** | QML `QtQuick.Controls` 主题 + 自定义 QML 组件 | Catppuccin Mocha 配色 |

---

## 3. 模块映射：React → QML

### 3.1 面板/Panel 对应关系

| React Panel | QML 组件 | 说明 |
|---|---|---|
| **Viewport.tsx** | `Viewport.qml` + `MetalViewportItem` | C++ QQuickItem 嵌入 Metal 渲染，QML 叠加 FPS/ViewCube overlay |
| **SceneHierarchy.tsx** | `SceneTree.qml` + `SceneModel` (C++) | C++ QAbstractItemModel 驱动 QML TreeView |
| **Inspector.tsx** | `Inspector.qml` + `PropertyEditors/` | QML Loader + 按类型的 Component 文件 |
| **AssetBrowser.tsx** | `Assets.qml` | 文件树 + 缩略图网格 + 预览 |
| **Console.tsx** | `Console.qml` | ListView + 日志级别过滤 |
| **Toolbar.tsx** | `main.qml` 中的 `ToolBar` | Gizmo 模式、Play/Pause/Stop |
| **MaterialEditor.tsx** | `MaterialEditor.qml` | 材质属性编辑 |
| **MaterialGraphEditor.tsx** | `MaterialGraph.qml` | QML Canvas 节点图 |
| **AnimationEditor.tsx** | `AnimationEditor.qml` | 状态机 + Timeline |
| **SequencerPanel.tsx** | `Sequencer.qml` | 多轨时间轴 |
| **ParticleEditor.tsx** | `ParticleEditor.qml` | VFX 参数编辑 |
| **ScriptEditor.tsx** | `ScriptEditor.qml` | 代码编辑 (后期) |
| **AiChat.tsx** | `AiChat.qml` | 聊天面板 |
| **RenderSettings.tsx** | `RenderSettings.qml` | 后处理参数面板 |
| **Settings.tsx** | `SettingsDialog.qml` | 全局设置 Dialog |
| **ViewCube.tsx** | `ViewCube.qml` (overlay in Viewport) | 3D 方向立方体 |
| **ViewportStatus.tsx** | Viewport 内 `RowLayout` | FPS、Draw Calls 等指标 |
| **PlaceActors.tsx** | `PlaceActors.qml` | Actor 类型列表 |
| **PrefabEditor.tsx** | `PrefabEditor.qml` | 预制体编辑 |
| **AudioMixer.tsx** | `AudioMixer.qml` | Bus 音量滑块 |
| **RhiStats.tsx** | `RhiStats.qml` | 渲染管线统计 |
| **PhysicsVisualization.tsx** | `PhysicsViz.qml` | 物理调试可视化 |
| **SkyPanel.tsx** | `SkyPanel.qml` | 天空/环境设置 |
| **CameraBookmarks.tsx** | `CameraBookmarks.qml` | 相机书签列表 |
| **RenderQueue.tsx** | `RenderQueue.qml` | 渲染队列管理 |
| **PluginManager.tsx** | `PluginManager.qml` | 插件启停控制 |
| **KeybindingsPanel.tsx** | `Keybindings.qml` | 快捷键配置 |
| **CommandTimeline.tsx** | `CommandTimeline.qml` | Undo/Redo 历史 |

### 3.2 核心 UI 组件

| React Component | QML 组件 | 说明 |
|---|---|---|
| FlexLayout dock 系统 | `SplitView` + 自定义 `DockPanel.qml` | 手写 dock/float/tab 系统 |
| ContextMenu.tsx | `Menu` | QML 原生右键菜单 |
| BuildDialog.tsx | `Dialog` | QML 对话框 |
| ToastContainer.tsx | 自定义 `Toast.qml` | `Popup` + `PropertyAnimation` |
| Tooltip.tsx | `ToolTip` | QML 内置 |
| Icons.tsx | `Icon.qml` + Qt Resource System | SVG 图标 + 颜色覆盖 |

### 3.3 基础设施

| React/Electron | QML/Qt | 说明 |
|---|---|---|
| Zustand store | QML 属性绑定 + C++ context objects | 无需全局状态库，QML `property` 天然响应式 |
| Preload IPC | QWebSocket 直连引擎 | 无需中间层 |
| Electron main process | 无需（QML 单进程） | 简化 |
| Vite HMR | CMake 增量编译 + `QML Live Reload` (dev) | 开发体验 |
| CSS 主题 | QML 组件主题 (`Theme.qml` singleton) | Catppuccin Mocha 通过 QML 属性实现 |
| window.guavaEngine | `EngineClient` C++ context object | 所有 QML 通过 `EngineClient` 访问 |

---

## 4. Viewport 方案（QML + Metal）

### 推荐方案：MetalViewportItem (QQuickItem + CAMetalLayer)

```cpp
// MetalViewportItem — QQuickItem 子类，直接渲染 Metal 到 QML 场景
class MetalViewportItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(EngineClient* engine READ engine WRITE setEngine NOTIFY engineChanged)

    // QML 可访问的渲染状态
    Q_PROPERTY(int fps READ fps NOTIFY fpsChanged)
    Q_PROPERTY(int drawCalls READ drawCalls NOTIFY drawCallsChanged)

protected:
    // QQuickItem 接口
    void geometryChange(...) override;   // 通知引擎 viewport 尺寸变化
    void itemChange(...) override;       // 可见性变化时初始化 Metal

    // 输入事件 → 转发引擎 RPC
    void mousePressEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void wheelEvent(QWheelEvent*) override;
    void keyPressEvent(QKeyEvent*) override;
    void keyReleaseEvent(QKeyEvent*) override;

private:
    // Metal 渲染 (Objective-C++)
    void initializeMetalLayer();  // 创建 CAMetalLayer + MTLDevice + MTLCommandQueue
    void renderFrame();           // 从引擎 IOSurface blit 到 Metal layer
    void timerEvent(QTimerEvent*);// 60 FPS 渲染循环
};
```

**QML 中的使用：**

```qml
// Viewport.qml
Rectangle {
    color: "#000000"

    MetalViewportItem {
        id: metalViewport
        anchors.fill: parent
        engine: EngineClient

        onViewportReady: console.log("Metal ready")
        onEntityPicked: (entityId) => SceneModel.selectEntity(entityId)
    }

    // FPS 叠加层 (纯 QML)
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        // ...
        Text { text: metalViewport.fps + " FPS" }
    }

    // ViewCube 叠加层 (纯 QML)
    ViewCube {
        anchors.top: parent.top
        anchors.right: parent.right
    }
}
```

**关键优势：**
- Metal 渲染在 QML 场景图内，叠加层（FPS、ViewCube、Tooltip）自然覆盖
- 输入事件通过 QQuickItem 路由，无需额外窗口句柄
- QML `property` 绑定自动更新 UI
- 零拷贝：引擎 IOSurface → Metal texture → CAMetalLayer

### 备选方案：QQuickFramebufferObject

如果 IOSurface 方案有问题，可使用 `QQuickFramebufferObject` 将引擎帧 blit 到 FBO：

```cpp
class ViewportRenderer : public QQuickFramebufferObject::Renderer {
    void render() override {
        // 从引擎 IOSurface 读取像素 → 渲染到 FBO
    }
};
```

此方案多一次 GPU blit，但兼容性更好。

---

## 5. 引擎通信层

```cpp
// EngineClient — WebSocket JSON-RPC 2.0 client (C++ backend)
class EngineClient : public QObject {
    Q_OBJECT

    // QML 可调用的 RPC 方法
    Q_INVOKABLE void call(const QString& method,
                          const QJsonObject& params = {},
                          QJSValue callback = QJSValue());

signals:
    // QML 可监听的信号
    void connected();
    void disconnected();
    void sceneChanged(int revision);
    void selectionChanged(const QVariantList& entityIds);
    void consoleLog(const QString& level, const QString& message);
    void framerateChanged(double fps);
    void playbackStateChanged(const QString& state);
    void historyChanged(int cursor, int totalEntries);
};
```

**QML 中的使用：**

```qml
// 任意 QML 文件中
Connections {
    target: EngineClient
    function onFramerateChanged(fps) {
        fpsText.text = Math.round(fps) + " FPS"
    }
    function onSelectionChanged(entityIds) {
        // 更新 Inspector
    }
}

// 调用 RPC
EngineClient.call("scene.createEntity", {name: "New Entity"})
EngineClient.call("viewport.setGizmoMode", {mode: "translate"})
```

**所有 ~100 个 RPC 方法完全不变**，因为引擎通信协议是 WebSocket JSON-RPC 2.0，与前端技术栈无关。

---

## 6. 分阶段实施计划

### Phase 0: 项目脚手架 ✅ (已完成)

**完成时间：** 2026-04-02

- [x] 创建 `packages/editor_qt/` 目录
- [x] CMakeLists.txt 配置 Qt6 + Quick/Qml 模块
- [x] 安装 Qt 6.8 (`brew install qt@6`)
- [x] EngineClient WebSocket 连接，验证 `editor.ping` 成功
- [x] 引擎子进程管理 (QProcess)

### Phase 1: QML 骨架 + 核心后端 ✅ (已完成)

**完成时间：** 2026-04-09

- [x] `main_qml.cpp` 入口 — QGuiApplication + QQmlApplicationEngine
- [x] `main.qml` — ApplicationWindow + MenuBar + ToolBar + SplitView + StatusBar
- [x] `MetalViewportItem : QQuickItem` — 输入事件完整，Metal 渲染骨架
- [x] `Viewport.qml` — 集成 MetalViewportItem + FPS overlay
- [x] `SceneModel : QAbstractItemModel` — 完整 CRUD + JSON 重建
- [x] `SceneNode` — 完整树节点
- [x] `SceneTree.qml` — UI 骨架 (placeholder 列表，待接入 TreeView)
- [x] `Inspector.qml` — 骨架 (placeholder)
- [x] `Console.qml` — 骨架
- [x] `Assets.qml` — 骨架
- [x] `TranslatorQML` — 完整国际化桥接
- [x] C++ 对象注册到 QML context（EngineClient、SceneModel、Translator）

**C++ 后端已实现：**
- ✅ `EngineClient` — WebSocket JSON-RPC 2.0，异步调用、自动重连
- ✅ `EngineProcess` — 子进程管理、日志转发
- ✅ `SceneModel` / `SceneNode` — 完整场景树模型
- ✅ `MetalViewportItem` — 输入事件路由，Metal 骨架
- ✅ `TranslatorQML` — 国际化 QML 桥接

### Phase 2: QML 核心面板功能化 (当前阶段)

**目标：** 将 QML 骨架变为可用编辑器

- [ ] **MetalViewportItem Metal 渲染实现**
  - 实现 `initializeMetalLayer()` — 创建 CAMetalLayer + MTLDevice + MTLCommandQueue
  - 实现 `renderFrame()` — 引擎 IOSurface → MTLTexture → Metal layer present
  - 接入引擎 `viewport.setIOSurfaceMode` RPC
  - 60 FPS 渲染循环验证

- [ ] **SceneTree.qml 接入 SceneModel**
  - 替换手动 Rectangle 列表为 QML `TreeView` + `SceneModel`
  - 右键菜单 (Create/Delete/Rename/Duplicate)
  - 拖放重父化
  - 搜索过滤
  - 双击重命名 (inline)
  - 展开/折叠状态持久

- [ ] **Inspector.qml 属性编辑器**
  - 创建 `PropertyEditors/` 目录，按类型的 QML 组件：
    - `FloatEditor.qml` — SpinBox + 拖拽微调
    - `Vec3Editor.qml` — 3 个 SpinBox (X/Y/Z)
    - `BoolEditor.qml` — CheckBox
    - `StringEditor.qml` — TextField
    - `ColorEditor.qml` — ColorDialog
    - `EnumEditor.qml` — ComboBox
    - `AssetRefEditor.qml` — 拖拽资源槽
  - `Inspector.qml` 用 `Loader` 按 `fieldType` 动态加载
  - 值变更 → `EngineClient.call("entity.setComponentField", ...)` 实时提交
  - Transform 组件优先

- [ ] **Console.qml 日志面板**
  - `ListView` + `ListModel` 显示日志
  - 订阅 `EngineClient.consoleLog` 信号
  - 日志级别过滤 (Info/Warning/Error)
  - 搜索过滤
  - 清除按钮

- [ ] **Play/Pause/Stop 播放控制**
  - 工具栏按钮连接 `playback.play/pause/stop` RPC
  - 播放状态指示器

- [ ] **Scene save/load**
  - File → Save 菜单 → `scene.save` RPC
  - File → Open → `scene.load` RPC

**交付物：** 功能可用的 QML 编辑器（渲染 + 场景编辑 + 属性编辑 + 日志）

### Phase 3: 资产 & 内容编辑 (2-3 周)

- [ ] **Assets.qml 资产浏览器**
  - 文件树 + 缩略图网格 (GridView)
  - 资产拖放到 Viewport / Inspector
  - 右键菜单 (Import/Delete/Rename)
  - 搜索过滤
  - 缩略图生成 (图片/Mesh 预览)

- [ ] **Inspector 完善 — 所有组件类型**
  - Material 组件编辑器
  - Light 组件编辑器
  - Camera 组件编辑器
  - Physics 组件编辑器
  - Script 组件编辑器

- [ ] **MaterialEditor.qml 基础版**
  - 材质属性面板
  - 纹理槽 (拖拽)
  - 色彩选择器

- [ ] **拖放系统**
  - 资产 → Viewport 创建实体
  - 资产 → Inspector 纹理槽
  - 层级树重排

**交付物：** 功能基本完整的场景编辑器

### Phase 4: 高级编辑器 (3-4 周)

- [ ] **MaterialGraph.qml** — 节点图编辑器 (QML Canvas)
- [ ] **AnimationEditor.qml** — 状态机 + Timeline
- [ ] **Sequencer.qml** — 多轨时间轴
- [ ] **ParticleEditor.qml**
- [ ] **ScriptEditor.qml** — 代码编辑 (嵌入 Monaco 或 QML TextEdit)
- [ ] **PrefabEditor.qml**
- [ ] **快捷键系统** — 可配置的 QML Shortcut

**交付物：** 高级内容创作工具完备

### Phase 5: 打磨 & 完成 (2-3 周)

- [ ] **RenderSettings.qml**
- [ ] **PhysicsViz.qml**
- [ ] **AudioMixer.qml**
- [ ] **AiChat.qml**
- [ ] **RenderQueue.qml**
- [ ] **Build 系统** — 打包对话框
- [ ] **窗口布局保存/恢复** — JSON 序列化 SplitView 比例
- [ ] **主题系统** — Catppuccin Mocha QML theme singleton
- [ ] **全局搜索 / Command Palette** — QML Popup + 过滤
- [ ] **ViewCube.qml** — 3D 方向立方体 overlay
- [ ] **性能优化**

**交付物：** 功能对等的完整编辑器

### Phase 6: 多平台 & 发布 (1-2 周)

- [ ] macOS 打包 (.app bundle)
- [ ] Windows 构建 & 测试
- [ ] Linux 构建 & 测试
- [ ] 自动更新机制
- [ ] 删除 `packages/editor` 和 `packages/citron`
- [ ] 删除 QWidget 旧代码 (`main.cpp`、`MainWindow`、`ViewportWidget`、`SceneTreeWidget`、`InspectorWidget`)

**总预估：** 12-18 周 (单人全职)

---

## 7. 项目结构

```
packages/editor_qt/
├── CMakeLists.txt
├── resources/
│   ├── icons/                  # SVG 图标
│   ├── themes/
│   │   └── catppuccin-mocha.qss  # (可能不再需要，QML 自带主题)
│   └── resources.qrc           # Qt 资源文件
├── src/
│   ├── main_qml.cpp            # QML 入口 (QGuiApplication + QQmlApplicationEngine)
│   ├── app/
│   │   └── EngineProcess.h/cpp # guava-engine 子进程
│   ├── engine/
│   │   └── EngineClient.h/cpp  # WebSocket JSON-RPC
│   ├── panels/
│   │   └── MetalViewportItem.h/cpp  # QQuickItem Metal 渲染 (唯一需要的 C++ panel)
│   ├── util/
│   │   ├── Theme.h/cpp              # QPalette 设置 (QGuiApplication)
│   │   ├── IconProvider.h/cpp       # QML 图标提供器
│   │   ├── Translator.h/cpp         # 国际化后端
│   │   ├── TranslatorQML.h/cpp      # 国际化 QML 桥接
│   │   ├── SceneNode.h/cpp          # 场景树节点
│   │   └── SceneModel.h/cpp         # QAbstractItemModel
│   └── qmlapi/                      # QML 可调用的 API 封装
│       ├── InspectorModel.h/cpp     # Inspector 数据模型
│       ├── ConsoleModel.h/cpp       # Console 日志模型
│       └── AssetModel.h/cpp         # 资产浏览器模型
└── resources/qml/
    ├── main.qml                     # ApplicationWindow 主窗口
    ├── Viewport.qml                 # Metal 视口 + overlay
    ├── SceneTree.qml                # 场景层级树
    ├── Inspector.qml                # 属性编辑器
    ├── Console.qml                  # 控制台
    ├── Assets.qml                   # 资产浏览器
    ├── PropertyEditors/             # 属性编辑器组件
    │   ├── FloatEditor.qml
    │   ├── Vec3Editor.qml
    │   ├── BoolEditor.qml
    │   ├── StringEditor.qml
    │   ├── ColorEditor.qml
    │   ├── EnumEditor.qml
    │   └── AssetRefEditor.qml
    ├── MaterialEditor.qml
    ├── MaterialGraph.qml
    ├── AnimationEditor.qml
    ├── Sequencer.qml
    ├── ParticleEditor.qml
    ├── ScriptEditor.qml
    ├── AiChat.qml
    ├── RenderSettings.qml
    ├── PhysicsViz.qml
    ├── AudioMixer.qml
    ├── SkyPanel.qml
    ├── SettingsDialog.qml
    ├── ViewCube.qml
    └── Components/                  # 通用 QML 组件
        ├── DockPanel.qml            # 可拖拽/浮动的面板
        ├── SearchBar.qml
        ├── Toast.qml
        ├── Icon.qml                 # SVG 图标 + 颜色覆盖
        └── CommandPalette.qml
```

### 与旧 QWidget 方案的对比

| 旧 (QWidget) | 新 (QML) | 变化 |
|---|---|---|
| `main.cpp` → `QApplication` | `main_qml.cpp` → `QGuiApplication` | 不需要 Widgets 模块 |
| `MainWindow : QMainWindow` | `main.qml : ApplicationWindow` | QML 声明式 |
| `QDockWidget` 面板 | `SplitView` + 自定义 `DockPanel.qml` | 灵活布局 |
| `ViewportWidget : QWidget` | `MetalViewportItem : QQuickItem` | QML 原生集成 |
| `SceneTreeWidget : QTreeView` | `SceneTree.qml` + `TreeView` | QML 声明式 |
| `InspectorWidget : QScrollArea` | `Inspector.qml` + `Loader` | 动态组件加载 |
| 每个面板一个 C++ 类 | QML 文件 + 共享 C++ 模型 | C++ 代码量大幅减少 |
| QSS 主题 | QML 属性主题 | 更灵活 |

---

## 8. 关键技术方案

### 8.1 属性编辑器 (Inspector)

QML 方案 — 使用 `Loader` + 按类型的 `Component`：

```qml
// Inspector.qml
ScrollView {
    id: inspector

    property var selectedEntity: null

    Column {
        spacing: 4
        padding: 8
        width: inspector.width

        // 实体名称
        TextField {
            text: selectedEntity ? selectedEntity.name : ""
            onAccepted: EngineClient.call("entity.setName", {
                entityId: selectedEntity.id,
                name: text
            })
        }

        // 组件列表
        Repeater {
            model: selectedEntity ? selectedEntity.components : []

            Column {
                spacing: 4
                property var comp: modelData

                // 组件头部
                Row {
                    Text { text: comp.type; color: "#cdd6f4"; font.bold: true }
                }

                // 属性列表
                Repeater {
                    model: comp.fields

                    Row {
                        spacing: 8
                        property var field: modelData

                        Text {
                            text: field.name
                            width: 80
                            color: "#a6adc8"
                        }

                        // 根据类型加载对应编辑器
                        Loader {
                            source: {
                                switch (field.type) {
                                case "f32": case "f64": return "PropertyEditors/FloatEditor.qml"
                                case "Vec3": return "PropertyEditors/Vec3Editor.qml"
                                case "bool": return "PropertyEditors/BoolEditor.qml"
                                case "String": return "PropertyEditors/StringEditor.qml"
                                case "Color": return "PropertyEditors/ColorEditor.qml"
                                case "enum": return "PropertyEditors/EnumEditor.qml"
                                default: return ""
                                }
                            }
                            property var fieldValue: field.value
                            property string fieldName: field.name
                            property string componentType: comp.type
                            property string entityId: selectedEntity.id

                            onLoaded: {
                                if (item) {
                                    item.value = Qt.binding(() => fieldValue)
                                    item.valueChanged.connect(() => {
                                        EngineClient.call("entity.setComponentField", {
                                            entityId: entityId,
                                            componentType: componentType,
                                            fieldName: fieldName,
                                            value: item.value
                                        })
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
```

```qml
// PropertyEditors/Vec3Editor.qml
Row {
    spacing: 2
    property var value: ({x: 0, y: 0, z: 0})
    signal valueChanged()

    SpinBox {
        from: -9999; to: 9999
        value: parent.value.x * 100
        onValueChanged: { parent.value.x = value / 100; parent.valueChanged() }
        // ... X label
    }
    SpinBox { /* Y */ }
    SpinBox { /* Z */ }
}
```

### 8.2 主题系统

QML 方案 — 使用 singleton 提供全局主题：

```qml
// Theme.qml (pragma Singleton)
pragma Singleton
import QtQuick

QtObject {
    // Catppuccin Mocha
    readonly property color base:      "#1e1e2e"
    readonly property color mantle:    "#181825"
    readonly property color crust:     "#11111b"
    readonly property color surface0:  "#313244"
    readonly property color surface1:  "#45475a"
    readonly property color surface2:  "#585b70"
    readonly property color overlay0:  "#6c7086"
    readonly property color text:      "#cdd6f4"
    readonly property color subtext:   "#a6adc8"
    readonly property color blue:      "#89b4fa"
    readonly property color green:     "#a6e3a1"
    readonly property color red:       "#f38ba8"
    readonly property color yellow:    "#f9e2af"
    readonly property color peach:     "#fab387"
    readonly property color mauve:     "#cba6f7"

    // 语义色
    readonly property color background:    base
    readonly property color panel:         surface0
    readonly property color panelHeader:   surface1
    readonly property color border:        surface1
    readonly property color accent:        blue
    readonly property color textPrimary:   text
    readonly property color textSecondary: subtext
    readonly property color error:         red
    readonly property color warning:       yellow
    readonly property color success:       green

    // 尺寸
    readonly property int panelMinWidth: 200
    readonly property int panelPreferredWidth: 300
    readonly property int toolbarHeight: 36
    readonly property int panelHeaderHeight: 32
    readonly property int rowHeight: 28
    readonly property int spacing: 4
}
```

```qml
// 使用
Rectangle {
    color: Theme.background
    border.color: Theme.border

    Text {
        text: "Hello"
        color: Theme.textPrimary
    }
}
```

### 8.3 SceneModel — QAbstractItemModel for QML

```cpp
// SceneModel 已经完整实现，支持以下 QML 使用：

// SceneTree.qml
TreeView {
    model: SceneModel
    delegate: Item {
        Row {
            Text { text: model.display }  // 实体名称
        }
        TapHandler {
            onDoubleTapped: SceneModel.renameEntity(model.id, "New Name")
            onLongPressed: contextMenu.popup()
        }
    }
}
```

### 8.4 RPC 类型代码生成

扩展引擎现有的 `gen_types.zig`，新增 C++ 头文件输出：

```cpp
// RpcTypes.h — auto-generated
struct Vec3 { double x, y, z; };
struct Quat { double x, y, z, w; };
struct Transform { Vec3 position; Quat rotation; Vec3 scale; };
struct EntityNode { int id; QString name; bool visible; bool selectable; QVector<EntityNode> children; };
// ... 所有类型
```

---

## 9. Viewport 嵌入详细方案

### macOS 路径 (QML + Metal)

```
1. main_qml.cpp 启动 → 创建 QQmlApplicationEngine
2. 加载 main.qml → Viewport.qml → MetalViewportItem
3. MetalViewportItem::itemChange(visible) → initializeMetalLayer()
   - 获取 QQuickItem 的 native window (NSView*)
   - 创建 CAMetalLayer 附加到 NSView
   - 创建 MTLDevice + MTLCommandQueue
4. MetalViewportItem::attachToEngine()
   - 调用 RPC "viewport.setIOSurfaceMode" {enabled: true}
   - 启动 60 FPS timer
5. MetalViewportItem::renderFrame() (每 16ms)
   - 查询引擎当前 IOSurface ID
   - MTLTexture → Metal render pass → CAMetalLayer present
6. 输入事件: QQuickItem 事件 → sendMouseInput/sendKeyInput → RPC
```

### 输入路由

```cpp
// MetalViewportItem 的输入路由 (已实现)
void MetalViewportItem::mouseMoveEvent(QMouseEvent* event) {
    if (!engine_) return;
    engine_->call("viewport.onMouseEvent", {
        {"type", "move"},
        {"x", static_cast<int>(event->position().x())},
        {"y", static_cast<int>(event->position().y())},
        {"modifiers", static_cast<int>(event->modifiers())}
    });
    event->accept();
}
```

---

## 10. 风险 & 缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| QML TreeView 功能不如 QTreeView 成熟 | 场景树交互受限 | Qt 6.8 TreeView 已大幅改善；必要时用自定义 delegate |
| Metal + QQuickItem 叠加层性能 | Metal layer 和 QML scene graph 冲突 | 使用 `QQuickItem::update()` 同步；必要时用 `QQuickRenderControl` |
| Dock/浮动面板需自实现 | 开发时间增加 | QML `SplitView` 够用；Phase 5 再做高级 dock |
| QML 调试不如 C++ 直观 | 问题定位更难 | QML Inspector + `console.log` + LLDB 混合调试 |
| 引擎热重载 | 引擎进程重启时 viewport 恢复 | EngineProcess 监控 → 自动重连 + 重新 attach |

---

## 11. 废弃计划

迁移完成后删除：
- `packages/editor/` (Electron + React 编辑器)
- `packages/citron/` (CEF 原生壳)
- `packages/editor/native/` (Node.js Native Addon)
- `packages/editor_qt/src/main.cpp` (QWidget 入口)
- `packages/editor_qt/src/app/MainWindow.h/cpp` (QMainWindow)
- `packages/editor_qt/src/panels/ViewportWidget.h/cpp/mm` (QWidget 视口)
- `packages/editor_qt/src/panels/SceneTreeWidget.h/cpp` (QWidget 场景树)
- `packages/editor_qt/src/panels/InspectorWidget.h/cpp` (QWidget Inspector)

保留：
- `packages/engine/` (Zig 引擎，不变)
- 引擎 RPC 协议 (不变)
- `packages/editor_qt/src/main_qml.cpp` (QML 入口，将成为唯一入口)
- `packages/editor_qt/src/panels/MetalViewportItem.h/cpp` (QQuickItem)
- `packages/editor_qt/src/util/SceneModel.h/cpp` + `SceneNode.h/cpp`
- `packages/editor_qt/src/engine/EngineClient.h/cpp`
- `packages/editor_qt/src/app/EngineProcess.h/cpp`
- `packages/editor_qt/src/util/TranslatorQML.h/cpp`

---

## 12. 快速开始

```bash
# 安装 Qt 6
brew install qt@6

# 创建项目
mkdir -p packages/editor_qt/resources/qml
cd packages/editor_qt

# 初始化 CMake
cmake -B build -G Ninja \
  -DCMAKE_PREFIX_PATH=$(brew --prefix qt@6) \
  -DCMAKE_BUILD_TYPE=Debug

# 构建 & 运行 (QML 版)
cmake --build build
./build/GuavaEditor
```

---

## 进度总结 (2026-04-10)

### 已完成 ✅

**Phase 0 + Phase 1 总计：** ~25% 功能完整度

| 组件 | 类型 | 状态 | 说明 |
|------|------|------|------|
| `main_qml.cpp` | C++ | ✅ | QML 入口，context objects 注册 |
| `main.qml` | QML | ✅ | ApplicationWindow + MenuBar + ToolBar + SplitView + StatusBar |
| `EngineClient` | C++ | ✅ | WebSocket JSON-RPC 2.0，异步调用、自动重连 |
| `EngineProcess` | C++ | ✅ | 子进程管理、日志转发 |
| `MetalViewportItem` | C++ | ✅ (输入) / TODO (渲染) | 输入事件完整，Metal 渲染待实现 |
| `Viewport.qml` | QML | ✅ (骨架) | 集成 MetalViewportItem + FPS overlay |
| `SceneModel` + `SceneNode` | C++ | ✅ | QAbstractItemModel 完整实现 |
| `SceneTree.qml` | QML | 骨架 | 未接入 TreeView，placeholder 列表 |
| `Inspector.qml` | QML | 骨架 | 纯 placeholder 文本 |
| `Console.qml` | QML | 骨架 | 纯 placeholder 文本 |
| `Assets.qml` | QML | 骨架 | 纯 placeholder 文本 |
| `TranslatorQML` | C++ | ✅ | 国际化 QML 桥接完整 |
| `Theme` | C++ | ✅ | QPalette Catppuccin Mocha |

### 旧 QWidget 代码 (待废弃)

以下代码在迁移完成后将被删除，QML 完成前暂时保留：

| 文件 | 说明 |
|---|---|
| `src/main.cpp` | QWidget 入口 |
| `src/app/MainWindow.h/cpp` | QMainWindow |
| `src/panels/ViewportWidget.h/cpp/mm` | QWidget Metal 视口 (517 行) |
| `src/panels/SceneTreeWidget.h/cpp` | QWidget 场景树 (320 行) |
| `src/panels/InspectorWidget.h/cpp` | QWidget Inspector (380 行) |

### 当前阶段：Phase 2

**下一步优先级：**
1. MetalViewportItem 实现渲染（最关键）
2. SceneTree.qml 接入 TreeView + SceneModel
3. Inspector.qml 属性编辑器
4. Console.qml 日志面板
