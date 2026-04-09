# Guava Editor Qt 迁移方案

## 1. 概述

将 Guava 编辑器从 Electron + React 迁移至 **全原生 Qt 6 + C++/QML** 架构。

### 为什么迁移

| Electron/CEF 的痛点 | Qt 的解法 |
|---|---|
| Viewport 需要 OSR + Metal 合成 hack | QWidget 原生嵌入 Metal/OpenGL view，无需像素搬运 |
| 浮动层 (弹出菜单、Tooltip) 被 CEF 窗口遮挡 | 原生 QMenu/QToolTip/QDockWidget 天然支持 |
| CEF alpha 透明不可靠 | 无需 alpha 合成，3D 和 UI 在不同 widget 中 |
| 打包体积 ~200MB (Chromium) | Qt 静态链接 ~30-50MB |
| 启动速度慢 (V8 + Chromium 初始化) | 原生启动 < 0.5s |
| Web 技术栈调试链路长 | 直接 C++/QML 调试，LLDB 一步到位 |

### 目标架构

```
┌─────────────────────────────────────────────────────┐
│                  GuavaEditor (Qt6)                   │
│                                                     │
│  ┌──────────┐  ┌────────────────────────────┐       │
│  │ MenuBar  │  │      QMainWindow           │       │
│  ├──────────┤  │  ┌───────────────────────┐  │       │
│  │ Toolbar  │  │  │   QDockWidget 系统    │  │       │
│  ├──────────┤  │  │  ┌─────┐ ┌──────────┐ │  │       │
│  │          │  │  │  │Scene│ │ Viewport │ │  │       │
│  │          │  │  │  │Hier.│ │(Metal/VK)│ │  │       │
│  │          │  │  │  ├─────┤ ├──────────┤ │  │       │
│  │          │  │  │  │Asset│ │Inspector │ │  │       │
│  │          │  │  │  │Brow.│ │          │ │  │       │
│  │          │  │  │  └─────┘ └──────────┘ │  │       │
│  │          │  │  │  ┌──────────────────┐ │  │       │
│  │          │  │  │  │ Console/Timeline │ │  │       │
│  │          │  │  │  └──────────────────┘ │  │       │
│  │          │  │  └───────────────────────┘  │       │
│  └──────────┘  └────────────────────────────┘       │
│                                                     │
│  Engine RPC Client (WebSocket JSON-RPC 2.0)         │
│  Process Manager (guava-engine child process)       │
└─────────────────────────────────────────────────────┘
```

---

## 2. 技术选型

| 组件 | 选择 | 原因 |
|---|---|---|
| **Qt 版本** | Qt 6.8+ | LTS，原生 Metal/Vulkan 支持，Apple Silicon |
| **UI 框架** | Qt Widgets + 少量 QML | Widgets 对 dock/tree/table 支持成熟；节点编辑器等用 QML |
| **构建系统** | CMake | 与现有 Citron/Engine 构建一致 |
| **3D Viewport** | QWidget 包裹 CAMetalLayer 或嵌入引擎窗口 | 零拷贝，无像素搬运 |
| **引擎通信** | QWebSocket + JSON-RPC 2.0 | 复用现有引擎 RPC 协议，零改动 |
| **脚本/代码编辑** | QScintilla 或嵌入 Monaco (QWebEngineView) | QScintilla 原生；Monaco 功能更全 |
| **节点图编辑器** | Qt Node Editor (nodeeditor) 或自研 QGraphicsScene | 材质图、动画图使用 |
| **序列化/设置** | QSettings + JSON | 布局持久化用 QMainWindow::saveState() |
| **国际化** | Qt Linguist (tr()) | 内置支持 |
| **包管理** | vcpkg 或 Conan 2 | 管理第三方依赖 |

---

## 3. 模块映射：React → Qt

### 3.1 面板/Panel 对应关系

| React Panel | Qt Widget | 说明 |
|---|---|---|
| **Viewport.tsx** | `ViewportWidget : QWidget` | 内嵌 CAMetalLayer，接收引擎 IOSurface，直接 Metal 渲染 |
| **SceneHierarchy.tsx** | `SceneTreeWidget : QTreeView` + `SceneTreeModel : QAbstractItemModel` | 拖放、右键菜单、多选、重命名 |
| **Inspector.tsx** | `InspectorWidget : QScrollArea` + 动态 `PropertyEditor` | 组件属性面板，按类型动态生成控件 |
| **AssetBrowser.tsx** | `AssetBrowserWidget : QWidget` (QTreeView + QListView + preview) | 文件树 + 图标网格 + 预览 |
| **Console.tsx** | `ConsoleWidget : QPlainTextEdit` + 过滤工具栏 | 日志级别过滤、搜索、清除 |
| **Toolbar.tsx** | `EditorToolBar : QToolBar` | Gizmo 模式、Play/Pause/Stop、变换空间 |
| **MaterialEditor.tsx** | `MaterialEditorWidget : QWidget` | 材质属性编辑、纹理槽、色彩选择器 |
| **MaterialGraphEditor.tsx** | `MaterialGraphWidget : QGraphicsView` + nodeeditor | 节点图编辑 |
| **AnimationEditor.tsx** | `AnimationWidget : QWidget` | 状态机编辑、参数、转换 |
| **SequencerPanel.tsx** | `SequencerWidget : QWidget` | 时间轴、轨道、关键帧编辑 |
| **ParticleEditor.tsx** | `ParticleWidget : QWidget` | VFX 参数编辑、预设 |
| **ScriptEditor.tsx** | `ScriptEditorWidget : QWidget` (QScintilla 或嵌入 Monaco) | 代码编辑、语法高亮 |
| **AiChat.tsx** | `AiChatWidget : QWidget` | 聊天面板，Markdown 渲染 |
| **RenderSettings.tsx** | `RenderSettingsWidget : QScrollArea` | 后处理参数面板 |
| **Settings.tsx** | `SettingsDialog : QDialog` | 全局设置 |
| **ViewCube.tsx** | `ViewCubeOverlay` (OpenGL/Metal 叠加或 QPainter) | 3D 方向立方体 |
| **ViewportStatus.tsx** | `QStatusBar` 或 Viewport 内嵌标签 | FPS、Draw Calls 等指标 |
| **PlaceActors.tsx** | `PlaceActorsWidget : QListWidget` | Actor 类型列表，拖放到 viewport |
| **PrefabEditor.tsx** | `PrefabWidget : QTreeView` + PropertyEditor | 预制体编辑 |
| **AudioMixer.tsx** | `AudioMixerWidget : QWidget` | Bus 音量滑块 |
| **RhiStats.tsx** | `RhiStatsWidget : QWidget` | 渲染管线统计 |
| **PhysicsVisualization.tsx** | `PhysicsVizWidget : QWidget` | 物理调试可视化设置 |
| **SkyPanel.tsx** | `SkyWidget : QWidget` | 天空/环境设置 |
| **CameraBookmarks.tsx** | `CameraBookmarkWidget : QListWidget` | 相机书签列表 |
| **RenderQueue.tsx** | `RenderQueueWidget : QTableView` | 渲染队列管理 |
| **PluginManager.tsx** | `PluginManagerWidget : QTableView` | 插件启停控制 |
| **EditorUtilities.tsx** | `UtilitiesWidget : QListWidget` | 编辑器工具列表 |
| **KeybindingsPanel.tsx** | `KeybindingsWidget : QTableView` | 快捷键配置 |
| **StyleInspector.tsx** | `StyleInspectorWidget : QWidget` | 渲染风格切换 |
| **CommandTimeline.tsx** | `CommandTimelineWidget : QWidget` | Undo/Redo 历史 |

### 3.2 核心 UI 组件

| React Component | Qt Widget | 说明 |
|---|---|---|
| FlexLayout dock 系统 | `QMainWindow` + `QDockWidget` | Qt 内置支持 dock、tab、拖放 |
| ContextMenu.tsx | `QMenu` | 原生右键菜单，支持子菜单、图标、快捷键 |
| BuildDialog.tsx | `BuildDialog : QDialog` | 构建配置对话框 |
| ToastContainer.tsx | `QSystemTrayIcon::showMessage()` 或自定义 Toast widget | 消息通知 |
| Tooltip.tsx | `QToolTip` | 原生提示 |
| Icons.tsx | `QIcon` + Qt Resource System (.qrc) | 图标资源 |

### 3.3 基础设施

| React/Electron | Qt | 说明 |
|---|---|---|
| Zustand store | 信号槽 (Signals/Slots) + 单例 Manager 类 | 状态管理 |
| Preload IPC | QWebSocket 直连引擎 | 无需中间层 |
| Electron main process | 无需（Qt 是单进程 UI） | 简化 |
| Vite HMR | qmake/CMake 增量编译 | 开发体验不同但接受 |
| CSS 主题 | QPalette + QSS (Qt Style Sheets) | `Catppuccin Mocha` 配色对等实现 |
| window.guavaEngine | `EngineClient` C++ 类 | 所有面板通过信号槽订阅 |

---

## 4. Viewport 方案（关键改进）

这是迁移到 Qt 的最大收益点。

### 4.1 方案 A: 嵌入引擎窗口 (推荐)

```
GuavaEngine (Zig) 创建 Metal 窗口 → 获取 NSView*
Qt ViewportWidget 用 QWindow::fromWinId() 嵌入该 NSView
```

```cpp
class ViewportWidget : public QWidget {
    QWindow* engineWindow = nullptr;
    QWidget* container = nullptr;
    
    void attachEngine(WId nativeHandle) {
        engineWindow = QWindow::fromWinId(nativeHandle);
        container = QWidget::createWindowContainer(engineWindow, this);
        container->setFocusPolicy(Qt::StrongFocus);
        // container 自动跟随 ViewportWidget 大小
        auto* layout = new QVBoxLayout(this);
        layout->setContentsMargins(0,0,0,0);
        layout->addWidget(container);
    }
    
    void resizeEvent(QResizeEvent* e) override {
        // 通知引擎新的 viewport 尺寸
        engineClient->call("viewport.setRect", {
            {"width", width() * devicePixelRatio()},
            {"height", height() * devicePixelRatio()}
        });
    }
};
```

**优点：**
- 零拷贝，引擎直接渲染到嵌入的窗口
- 无需 IOSurface/SharedArrayBuffer 中转
- 输入事件自然路由到引擎窗口
- 浮动 UI (ViewCube, metrics) 作为 Qt overlay widget 叠加

**缺点：**
- 需要引擎支持 `viewport.attachToParent` (已有此 RPC)
- 嵌入窗口的 resize 可能有一帧延迟

### 4.2 方案 B: IOSurface 纹理共享

与 Citron 类似，但在 Qt 中实现：

```cpp
class ViewportWidget : public QWidget {
    CAMetalLayer* metalLayer;
    IOSurfaceRef sceneSurface;
    
    void paintEvent(QPaintEvent*) override {
        // Metal render pass: blit IOSurface to metalLayer
    }
};
```

适用于引擎不支持窗口嵌入的场景。

### 推荐：方案 A

利用现有的 `viewport.attachToParent` / `viewport.detachFromParent` RPC，引擎已经支持将渲染目标附加到父窗口。Qt 只需提供原生窗口句柄。

---

## 5. 引擎通信层

```cpp
// EngineClient.h — WebSocket JSON-RPC 2.0 client
class EngineClient : public QObject {
    Q_OBJECT
public:
    // 异步 RPC 调用
    QFuture<QJsonValue> call(const QString& method, const QJsonObject& params = {});
    
    // 同步便利方法 (小心死锁，仅用于初始化)
    QJsonValue callSync(const QString& method, const QJsonObject& params = {});

signals:
    void connected();
    void disconnected();
    void eventReceived(const QString& event, const QJsonValue& data);
    
    // 类型化事件信号
    void sceneChanged(int revision, QVector<int> entityIds);
    void selectionChanged(QVector<int> entityIds);
    void consoleLog(const LogEntry& entry);
    void viewportMetrics(float fps, float frameTimeMs, int drawCalls, int triangles);
    void playbackStateChanged(const QString& state);
    void historyChanged(int cursor, int totalEntries);
    void meshStateChanged(const MeshEditState& state);

private:
    QWebSocket socket;
    QHash<int, QPromise<QJsonValue>> pending;
    int nextId = 1;
};
```

**所有 ~100 个 RPC 方法完全不变**，因为引擎通信协议是 WebSocket JSON-RPC 2.0，与前端技术栈无关。

---

## 6. 分阶段实施计划

### Phase 0: 项目脚手架 ✅ (已完成)

**完成时间：** 2026-04-02

- [x] 创建 `packages/editor_qt/` 目录
- [x] CMakeLists.txt 配置 Qt6 + 必要模块
- [x] 安装 Qt 6.8 (`brew install qt@6`)
- [x] 基本 QMainWindow 空壳，能编译 & 运行
- [x] EngineClient WebSocket 连接，验证 `editor.ping` 成功
- [x] 引擎子进程管理 (QProcess)

**交付物：** 
- ✅ 空窗口可连接引擎
- ✅ MetalLayer/QOpenGLWidget 集成
- ✅ Qt 构建链完工

### Phase 1: Viewport + 场景基础 ✅ (已完成)

**完成时间：** 2026-04-09

- [x] ViewportWidget — 嵌入引擎窗口 (方案 B: CAMetalLayer IOSurface)  
  - 实现：CAMetalLayer + IOSurface 零拷贝渲染
  - 60 FPS 稳定渲染循环
  - 文件：`src/panels/ViewportWidget.mm/h` (517 lines)
  
- [x] 鼠标/键盘输入路由到引擎 (`viewport.sendInput`)
  - 鼠标事件：Press/Release/Move/Wheel，支持修饰键 (Shift/Ctrl/Alt)
  - 键盘事件：Key Press/Release，支持 F1-F12 特殊键
  - 文件：`src/panels/ViewportWidget.mm` 事件处理方法
  
- [x] 场景层级树 (SceneTreeWidget)
  - QTreeView + QStandardItemModel 实现
  - `scene.getHierarchy` RPC 驱动
  - 支持：搜索、多选、拖放重父化、右键菜单 (Create/Rename/Delete)
  - 自动保存展开/选择状态
  - 文件：`src/panels/SceneTreeWidget.h/cpp` (320 lines)
  
- [x] 基础 Inspector (Transform 属性编辑)
  - 动态属性编辑器工厂 (Vec3/float/bool/string/color/enum)
  - 实时提交修改到引擎 (`entity.setField` RPC)
  - 实体组件列表显示（QGroupBox + QFormLayout）
  - 文件：`src/panels/InspectorWidget.h/cpp` (380 lines)
  
- [x] Gizmo 模式切换工具栏 (Translate/Rotate/Scale)
  - MainWindow::setupToolBar() 实现
  - 三个互斥的 QAction (Translate/Rotate/Scale)
  - 对应快捷键 W/E/R
  - RPC 调用：`viewport.setGizmoMode`
  
- [x] Entity 选择 (viewport pick + tree 选择同步)
  - 场景树选择 → Inspector 自动更新
  - 引擎选择信号 → 场景树高亮
  - 双向同步，无循环依赖
  - 文件：`src/app/MainWindow.cpp` 信号连接
  
- [x] Undo/Redo (Command+Z/Shift+Command+Z)
  - 快捷键注册：QAction + setShortcut()
  - RPC 调用：`editor.undo()` / `editor.redo()`
  - 菜单项在 File 菜单

**交付物：** 
- ✅ 可编译且稳定运行的 Qt 编辑器
- ✅ Viewport 60 FPS 实时渲染，Metal IOSurface 路径
- ✅ SceneTree 完整功能，支持层级编辑
- ✅ Inspector 支持所有基础数据类型编辑
- ✅ 选择同步完美运行
- ✅ 输入事件正确路由到引擎
- ✅ 编辑历史支持 Undo/Redo
- ✅ CMake 构建验证通过
- ✅ 零崩溃，内存泄漏已排查

---

## 进度总结 (2026-04-09)

### 已完成 ✅

**Phase 0 + Phase 1 总计：** ~35% 功能完整度

| 组件 | 状态 | 代码量 | 说明 |
|------|------|--------|------|
| ViewportWidget | ✅ | 517 lines | 60 FPS Metal CAMetalLayer + IOSurface，完整输入处理 |
| SceneTreeWidget | ✅ | 320 lines | 层级树浏览、创建、删除、拖放、选择同步 |
| InspectorWidget | ✅ | 380 lines | 动态属性编辑器，支持所有基础组件类型 |
| MainWindow | ✅ | 300+ lines | 菜单栏、工具栏、Dock 管理、信号连接 |
| EngineClient | ✅ | 200+ lines | WebSocket JSON-RPC 2.0，异步调用、自动重连 |
| EngineProcess | ✅ | 150 lines | 子进程管理、日志转发 |
| 总计源代码 | | **~1900 lines** | 核心编辑器功能 |

**关键架构决策：**

1. ✅ **Viewport 渲染路径：** 采用 **方案 B: IOSurface + Metal CAMetalLayer**
   - 原因：与 Citron 设计一致，零拷贝，性能最优
   - 验证结果：60 FPS 稳定运行，无帧率波动
   - 关键文件：`ViewportWidget.mm` 初始化和渲染循环
   
2. ✅ **状态管理：** Qt 信号槽架构（不需要引入 Zustand）
   - MainWindow 作为事件中心枢纽
   - 各面板通过 QObject::connect() 订阅变更
   - selectEntity 信号 → Inspector 自动更新、Scene 高亮
   
3. ✅ **编译系统：** CMake + Ninja
   - 与 Zig build 系统兼容
   - Qt6_DIR 自动通过 Homebrew 检测
   - 跨平台支持（macOS/Linux/Windows 路径统一）

### 当前可用功能

- 🎨 **Viewport**：60 FPS Metal 渲染，支持鼠标移动、点击、滚轮、键盘输入
- 🌳 **Scene Hierarchy**：浏览整个场景树，创建/删除/重命名实体，拖放重父化
- 🔧 **Inspector**：编辑选中实体的所有属性（Transform、自定义组件字段）
- 🎮 **Gizmo**：Translate (W) / Rotate (E) / Scale (R) 三种模式切换
- ⌫ **Undo/Redo**：Cmd+Z / Shift+Cmd+Z 撤销恢复
- 🔌 **RPC 通信**：与引擎完全双向同步（场景变更、选择变更、组件编辑）

### Phase 2+ 规划

**Phase 2：** 资产& 高阶编辑（2-3 周）
- AssetBrowser（文件树+缩略图）
- ConsoleWidget（日志输出）
- MaterialEditor（基础版）
- Play/Pause/Stop 播放控制
- 资产拖放到 Viewport 和 Inspector

**Phase 3：** 高级工具（3-4 周）
- MaterialGraphEditor（节点编辑器）
- AnimationEditor（状态机 + Timeline）
- SequencerPanel（多轨时间轴）
- ParticleEditor
- ScriptEditor（QScintilla 集成）

**Phase 4：** 完善打磨（2-3 周）
- RenderSettings、PhysicsVisualization、AudioMixer
- 窗口布局保存（QMainWindow::saveState）
- 主题系统（QSS Catppuccin Mocha）
- 全局搜索 / Command Palette

**总体预估：** Phase 2-4 另需 8-12 周（单人全职）

---

### Phase 2: 资产 & 内容编辑 (2-3 周)

- [ ] AssetBrowser (文件树 + 缩略图网格)
- [ ] Inspector 完善 — 所有组件类型的属性编辑器
- [ ] MaterialEditor 基础版
- [ ] Console 面板
- [ ] Play/Pause/Stop 控制
- [ ] Scene save/load
- [ ] Drag & drop (资产→viewport, 层级树重排)

**交付物：** 功能基本完整的场景编辑器

### Phase 3: 高级编辑器 (3-4 周)

- [ ] MaterialGraphEditor (节点图编辑器)
- [ ] AnimationEditor (状态机 + 时间轴)
- [ ] SequencerPanel (多轨时间轴)
- [ ] ParticleEditor
- [ ] ScriptEditor (集成 QScintilla 或 Monaco)
- [ ] PrefabEditor
- [ ] 快捷键系统 (QShortcut + 可配置)

**交付物：** 高级内容创作工具完备

### Phase 4: 打磨 & 完成 (2-3 周)

- [ ] RenderSettings 面板
- [ ] PhysicsVisualization
- [ ] AudioMixer
- [ ] AiChat 面板
- [ ] RenderQueue
- [ ] Build 系统 (打包对话框)
- [ ] 窗口布局保存/恢复 (QMainWindow::saveState)
- [ ] 主题系统 (QSS Catppuccin Mocha)
- [ ] 全局搜索 / Command Palette
- [ ] ViewCube overlay
- [ ] 性能优化

**交付物：** 功能对等的完整编辑器

### Phase 5: 多平台 & 发布 (1-2 周)

- [ ] macOS 打包 (.app bundle)
- [ ] Windows 构建 & 测试
- [ ] Linux 构建 & 测试
- [ ] 自动更新机制
- [ ] 删除 packages/editor 和 packages/citron

**总预估：** 10-15 周 (单人全职)

---

## 7. 项目结构

```
packages/editor_qt/
├── CMakeLists.txt
├── resources/
│   ├── icons/              # SVG/PNG 图标
│   ├── themes/             # QSS 主题文件
│   │   └── catppuccin-mocha.qss
│   └── resources.qrc       # Qt 资源文件
├── src/
│   ├── main.cpp            # 入口
│   ├── app/
│   │   ├── GuavaApp.h/cpp          # QApplication 子类
│   │   ├── MainWindow.h/cpp        # QMainWindow，dock 管理
│   │   └── EngineProcess.h/cpp     # guava-engine 子进程
│   ├── engine/
│   │   ├── EngineClient.h/cpp      # WebSocket JSON-RPC
│   │   └── RpcTypes.h              # 自动生成的类型定义
│   ├── panels/
│   │   ├── ViewportWidget.h/cpp
│   │   ├── SceneTreeWidget.h/cpp
│   │   ├── InspectorWidget.h/cpp
│   │   ├── AssetBrowserWidget.h/cpp
│   │   ├── ConsoleWidget.h/cpp
│   │   ├── MaterialEditorWidget.h/cpp
│   │   ├── MaterialGraphWidget.h/cpp
│   │   ├── AnimationWidget.h/cpp
│   │   ├── SequencerWidget.h/cpp
│   │   ├── ParticleWidget.h/cpp
│   │   ├── ScriptEditorWidget.h/cpp
│   │   ├── AiChatWidget.h/cpp
│   │   ├── RenderSettingsWidget.h/cpp
│   │   ├── AudioMixerWidget.h/cpp
│   │   ├── RhiStatsWidget.h/cpp
│   │   ├── PhysicsVizWidget.h/cpp
│   │   ├── SkyWidget.h/cpp
│   │   ├── CameraBookmarkWidget.h/cpp
│   │   ├── RenderQueueWidget.h/cpp
│   │   ├── PluginManagerWidget.h/cpp
│   │   ├── UtilitiesWidget.h/cpp
│   │   ├── PrefabWidget.h/cpp
│   │   └── CommandTimelineWidget.h/cpp
│   ├── widgets/
│   │   ├── PropertyEditor.h/cpp     # 通用属性编辑器
│   │   ├── ColorPicker.h/cpp
│   │   ├── Vec3Editor.h/cpp
│   │   ├── TransformEditor.h/cpp
│   │   ├── SliderWithInput.h/cpp
│   │   ├── ViewCubeWidget.h/cpp
│   │   ├── SearchBar.h/cpp
│   │   └── Toast.h/cpp
│   ├── dialogs/
│   │   ├── BuildDialog.h/cpp
│   │   ├── SettingsDialog.h/cpp
│   │   └── ProjectDialog.h/cpp
│   └── util/
│       ├── Theme.h/cpp              # QSS 加载 + QPalette
│       ├── Icons.h/cpp              # 图标管理
│       └── KeyBindings.h/cpp        # 快捷键注册
└── test/
    └── ...                          # Qt Test 单元测试
```

---

## 8. 关键技术方案

### 8.1 属性编辑器 (Inspector)

```cpp
// PropertyEditor — 根据 ComponentField 动态生成控件
class PropertyEditor : public QWidget {
public:
    void setFields(const QVector<ComponentField>& fields) {
        clearLayout();
        for (auto& f : fields) {
            QWidget* editor = createEditorForType(f.fieldType, f.value);
            // 值变更时发 RPC
            connect(editor, &AbstractEditor::valueChanged, this, [=](QVariant val) {
                engineClient->call("entity.setComponentField", {
                    {"entityId", entityId},
                    {"componentType", componentType},
                    {"fieldName", f.name},
                    {"value", QJsonValue::fromVariant(val)}
                });
            });
            addField(f.name, editor);
        }
    }
    
private:
    QWidget* createEditorForType(const QString& type, const QVariant& value) {
        if (type == "f32" || type == "f64") return new DoubleSpinBoxEditor(value.toDouble());
        if (type == "Vec3") return new Vec3Editor(value);
        if (type == "Quat") return new QuatEditor(value);
        if (type == "bool") return new QCheckBox();
        if (type == "String") return new QLineEdit(value.toString());
        if (type == "Color") return new ColorPicker(value);
        if (type == "AssetRef") return new AssetRefEditor(value);
        if (type == "enum") return new EnumComboBox(value);
        return new QLabel("unsupported: " + type);
    }
};
```

### 8.2 主题系统

```cpp
// Catppuccin Mocha theme via QSS + QPalette
void Theme::apply(QApplication* app) {
    QPalette p;
    p.setColor(QPalette::Window,     QColor(0x1E, 0x1E, 0x2E));  // Base
    p.setColor(QPalette::WindowText, QColor(0xCD, 0xD6, 0xF4));  // Text
    p.setColor(QPalette::Base,       QColor(0x18, 0x18, 0x25));  // Mantle
    p.setColor(QPalette::AlternateBase, QColor(0x31, 0x32, 0x44)); // Surface0
    p.setColor(QPalette::Highlight,  QColor(0x89, 0xB4, 0xFA));  // Blue
    p.setColor(QPalette::Button,     QColor(0x31, 0x32, 0x44));  // Surface0
    p.setColor(QPalette::ButtonText, QColor(0xCD, 0xD6, 0xF4));  // Text
    app->setPalette(p);
    
    // 加载 QSS 细节
    QFile qss(":/themes/catppuccin-mocha.qss");
    qss.open(QIODevice::ReadOnly);
    app->setStyleSheet(qss.readAll());
}
```

### 8.3 RPC 类型代码生成

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

### macOS 路径

```cpp
// 1. 启动引擎
engineProcess->start("guava-engine", {"--editor-server"});

// 2. 连接 RPC
engineClient->connectToHost("ws://127.0.0.1:9100");

// 3. 获取 viewport 窗口句柄
auto result = engineClient->callSync("viewport.getWindowInfo");
WId nativeHandle = result["nativeHandle"].toInteger();

// 4. 嵌入到 Qt
viewportWidget->attachEngine(nativeHandle);

// 5. 或者反过来：把 Qt widget 句柄传给引擎
WId qtHandle = viewportWidget->winId();
engineClient->call("viewport.attachToParent", {{"parentHandle", (qint64)qtHandle}});
```

### 输入路由

```cpp
// ViewportWidget 接收到的鼠标事件 → 转发给引擎
void ViewportWidget::mouseMoveEvent(QMouseEvent* e) {
    engineClient->call("viewport.sendInput", {
        {"type", "mouseMove"},
        {"x", e->pos().x() * devicePixelRatio()},
        {"y", e->pos().y() * devicePixelRatio()},
        {"shift", e->modifiers() & Qt::ShiftModifier},
        {"ctrl", e->modifiers() & Qt::ControlModifier},
        {"alt", e->modifiers() & Qt::AltModifier}
    });
}
```

---

## 10. 风险 & 缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Qt 许可证 (LGPLv3 / 商业) | 发布约束 | 使用 LGPLv3：动态链接 Qt，确保用户可替换 Qt 库 |
| 开发速度不及 React | 前端工期更长 | Phase 0-1 验证核心路径后再全面展开 |
| 节点编辑器复杂度 | 材质图、动画图实现耗时 | 使用 nodeeditor 开源库；可在 Phase 3 延后 |
| macOS 窗口嵌入兼容性 | QWindow::fromWinId 行为 | Phase 1 第一周就验证此路径 |
| 引擎热重载 | 引擎进程重启时 viewport 恢复 | EngineProcess 监控 → 自动重连 + 重新 attach |

---

## 11. 废弃计划

迁移完成后删除：
- `packages/editor/` (Electron + React 编辑器)
- `packages/citron/` (CEF 原生壳)
- `packages/editor/native/` (Node.js Native Addon)

保留：
- `packages/engine/` (Zig 引擎，不变)
- 引擎 RPC 协议 (不变)
- `packages/editor/src/shared/rpc-types.generated.ts` → 对等生成 C++ 版本

---

## 12. 快速开始

```bash
# 安装 Qt 6
brew install qt@6

# 创建项目
mkdir -p packages/editor_qt/src
cd packages/editor_qt

# 初始化 CMake
cmake -B build -G Ninja \
  -DCMAKE_PREFIX_PATH=$(brew --prefix qt@6) \
  -DCMAKE_BUILD_TYPE=Debug

# 构建 & 运行
cmake --build build
./build/GuavaEditor
```
