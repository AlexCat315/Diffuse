# Guava Editor: Qt6 迁移计划

>  Qt6 原生桌面栈  
> 目标：统一 UI 技术栈、稳定 Dock/多窗口体验、保持引擎通信协议不变，并可平滑替换现有编辑器壳层

## 1. 迁移目标与边界

### 1.1 总目标

- 编辑器 UI 框架统一为 Qt6（C++）
- 保持 Engine 侧能力与协议不破坏：JSON-RPC 方法名/参数/事件保持兼容
- 优先完成核心工作流：Viewport、Scene、Inspector、Content Browser、Console、Play/Pause/Stop
- 允许阶段性并行：旧编辑器与 Qt6 编辑器可共存，确保可回滚

### 1.2 非目标（第一阶段不做）

- 不重写 Engine 渲染核心
- 不改动资源格式（scene/material/prefab/script）
- 不在 P0/P1 阶段追求所有次级面板 100% 完整（如 AI Chat、Particle Editor）

---

## 2. 为什么改为 Qt6

### 2.1 当前问题（从现状抽象）

- 维护两条 UI 路线成本高（历史 Web/CEF 路线 + 新 Avalonia 路线）
- Dock 行为、主题覆盖、布局持久化在跨框架组合下调试成本高
- 团队在图形工具领域对 Qt 生态（Dock、Model/View、OpenGL/Metal/Vulkan 窗口嵌入）成熟度更高

### 2.2 Qt6 价值

- 工业级桌面 UI 生态，Dock/多窗口行为稳定
- QML/Qt Quick 在动画、叠加层、可视化面板上表达力更强
- QAbstractItemModel 适合 Scene/Asset/Inspector 等高频树模型
- 可直接使用 QQuickItem + 原生层桥接承载渲染视口

### 2.3 授权与合规

- Qt LGPLv3：
  - 动态链接 Qt 库
  - 允许用户替换 Qt 动态库
  - 提供对应许可证与归档信息
- 若需静态链接或规避 LGPL 义务，需 Qt 商业授权

---

## 3. 目标架构

## 3.1 总体分层

```text
+------------------------------------------------------+
|                 Qt6 Editor (C++)                     |
|  +-----------------------------------------------+   |
|  | QML Shell (ApplicationWindow + Panels/Overlay)|   |
|  +-----------------------------------------------+   |
|  +-----------------------------------------------+   |
|  | Viewport Host (QQuickItem + native bridge)    |   |
|  +-----------------------------------------------+   |
+--------------------------|---------------------------+
                           |
                    WebSocket JSON-RPC
                           |
+------------------------------------------------------+
|                    Engine Runtime                     |
+------------------------------------------------------+
```

### 3.2 关键原则

- 协议不变：继续使用现有 ws://127.0.0.1:9100 JSON-RPC
- 数据流单向明确：UI 命令 -> RPC -> Engine；Engine 事件 -> 状态总线 -> UI
- 视图与状态分离：Panel 仅消费 Store，不直接持有网络细节

---

## 4. 技术选型与替代映射

| 能力 | 旧方案 | Qt6 方案 |
|------|--------|----------|
| 主框架 | Avalonia/Citron | Qt6 QML/Qt Quick（优先） |
| 停靠布局 | Dock.Avalonia | QML SplitView/布局管理（必要时局部补 Widgets） |
| 属性面板 | XAML 表单 | QML Form + C++ Model/Delegate |
| 树结构 | Avalonia TreeDataGrid | QTreeView + QAbstractItemModel |
| 代码编辑器 | AvaloniaEdit/Monaco | QML TextArea（P0）-> Scintilla/KSyntaxHighlighting（P1） |
| 视口承载 | NativeControlHost + IOSurfaceHost | QQuickItem 宿主 + 原生层桥接 |
| IPC | WebSocket JSON-RPC | QtWebSockets + QJsonDocument |
| 持久化布局 | Serializer | QML 布局状态 JSON 持久化 |
| 主题 | Fluent/自定义 | QML Theme Tokens + 统一调色板 |

### 4.1 推荐 UI 模式

- 第一版使用 QML/Qt Quick 为主
- 非必要不上 Widgets；仅在下列场景允许局部使用：
  - 原生视口桥接需要 createWindowContainer
  - 第三方控件暂无 QML 等价实现
  - 诊断工具临时性嵌入

---

## 5. 模块拆分（目录建议）

```text
packages/
  editor_qt6/
    CMakeLists.txt
    src/
      app/
        main.cpp
        Application.cpp
        Backend.cpp
      qml/
        Main.qml
        panels/
        overlays/
      docking/
        DockLayoutManager.cpp
      viewport/
        ViewportHostItem.cpp
        ViewportBridge_mac.mm
      rpc/
        RpcClient.cpp
        RpcRouter.cpp
      state/
        AppStore.cpp
        SceneStore.cpp
        ConsoleStore.cpp
      panels/
        ScenePanel.cpp
        InspectorPanel.cpp
        ContentBrowserPanel.cpp
        ConsolePanel.cpp
        RenderSettingsPanel.cpp
      models/
        SceneTreeModel.cpp
        AssetTreeModel.cpp
      services/
        ProjectService.cpp
        LayoutService.cpp
```

---

## 6. 视口迁移方案（重点）

### 6.1 目标

- 在 Qt 主窗口中嵌入 Engine 输出画面
- 保持输入事件（鼠标、键盘、滚轮）转发
- 保持 FPS/DrawCall 等指标订阅展示

### 6.2 macOS 建议实现

- 路线 A（推荐）：
  - 使用 NSView/CAMetalLayer 作为原生宿主
  - Qt 层优先通过 QQuickItem 桥接；必要时退回 QWidget::createWindowContainer
- 路线 B：
  - 使用共享纹理 + Qt 渲染通道绘制（复杂，首版不建议）

### 6.3 事件转发

- Qt 输入事件 -> 统一映射 -> JSON-RPC viewport.sendInput
- 保持现有字段语义：type/x/y/button/key/shift/ctrl/alt

### 6.4 视口矩形同步

- 在 resizeEvent/moveEvent/paintEvent 时更新 viewport.setRect
- 节流（16ms~33ms）避免高频抖动

---

## 7. 面板迁移优先级

## 7.1 P0（可用编辑器）

- Viewport
- Scene Hierarchy
- Inspector
- Content Browser
- Console
- Top Toolbar（Play/Pause/Stop）

### 7.2 P1（常用扩展）

- Render Settings
- Script Editor
- Camera Bookmarks
- RHI Stats

### 7.3 P2（进阶工具）

- Material Graph
- Sequencer
- Animation Editor
- Prefab/Particle/Style Inspector 等

---

## 8. 状态管理与数据流

### 8.1 Store 划分

- SceneStore：层级与选中
- ConsoleStore：日志与过滤
- ViewportStore：fps、模式、gizmo 状态
- UiStore：当前布局、主题、语言

### 8.2 通知路由

- RpcClient 收到 on:* 事件后，分发给 RpcRouter
- RpcRouter 只做事件归类，不直接改 UI
- Store 负责状态变更，Panel 监听 Store

---

## 9. 布局与持久化

### 9.1 默认布局

- 左：Scene/Place Actors
- 中：Viewport
- 右：Inspector/Render Settings
- 下：Console/Content Browser

### 9.2 用户布局保存

- 退出时保存：QML 布局状态（JSON）
- 启动时恢复：读取 JSON 并恢复 SplitView/Panel 状态
- 增加版本号：布局结构变化时可自动回退默认布局

---

## 10. 构建与打包

### 10.1 CMake 基线

- CMake >= 3.24
- C++20
- Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::WebSockets

### 10.2 macOS 打包要点

- macdeployqt 打包 Framework
- codesign --deep --force --options runtime
- notarization（若对外分发）

### 10.3 与现有仓库并行

- 保留现有编辑器目录，不直接删除
- 新增独立 target：GuavaEditorQt6
- CI 增加独立构建任务，互不阻塞

---

## 11. 分阶段里程碑（建议 12 周）

### 11.1 第 0-2 周：基础骨架

- 建立 editor_qt6 工程与主窗口
- 跑通 RPC connect/ping/基础事件订阅
- 接入最小 Console 面板

验收：

- 可启动、可连接引擎、可显示日志

### 11.2 第 3-5 周：Viewport + 核心面板

- 完成 Viewport 宿主和输入转发
- 完成 Scene/Inspector/Content Browser
- 完成底栏 Console

验收：

- 可选中实体并编辑 Transform
- Viewport 交互稳定，帧率可读

### 11.3 第 6-8 周：编辑器可用闭环

- 工具栏（Play/Pause/Stop）
- 保存布局、恢复布局
- Render Settings + 基础快捷键

验收：

- 满足日常编辑最小闭环

### 11.4 第 9-12 周：增强与收尾

- Script Editor
- 统计与调试面板
- 性能优化与崩溃恢复

验收：

- 可作为默认编辑器候选

---

## 12. 风险与应对

| 风险 | 等级 | 应对 |
|------|------|------|
| 视口嵌入在 macOS 下出现黑屏/刷新不同步 | 高 | 先做 1 周 Spike，优先验证原生 NSView 路线 |
| Dock 状态恢复在复杂布局下错位 | 中 | 布局版本化 + 一键重置布局 |
| 代码编辑器能力不足 | 中 | P0 用 QPlainTextEdit，P1 引入 QScintilla |
| LGPL 合规遗漏 | 高 | 提前建立第三方清单和发布检查表 |
| 迁移期间需求漂移 | 中 | 冻结 P0 范围，新增需求进入 P1/P2 |

---

## 13. 回滚与并行策略

- 在 Qt6 达到 P0 验收前，旧编辑器继续可运行
- 启动参数切换：
  - --editor=qt6
  - --editor=legacy
- CI 同时构建两套编辑器，避免单点失败

---

## 14. 测试策略

### 14.1 自动化

- RPC 层：请求/响应/超时/重连单测
- Store 层：事件驱动状态变更单测
- 模型层：QAbstractItemModel 行列与索引一致性测试

### 14.2 手工回归（每日）

- 启动连接
- 视口交互（旋转、平移、缩放）
- Scene 选择同步 Inspector
- Content Browser 打开资源
- Console 日志滚动与清空
- 布局保存与恢复

---

## 15. 迁移清单（可执行）

- [ ] 建立 packages/editor_qt6 与 CMake 工程
- [ ] 接入 QtWebSockets JSON-RPC 客户端
- [ ] 接入 QML 主壳与基础面板布局
- [ ] 打通 Viewport 宿主与输入转发
- [ ] 完成 Scene/Inspector/Content Browser/Console
- [ ] 实现布局保存恢复
- [ ] 加入启动参数切换 legacy/qt6
- [ ] 补齐测试与发布脚本
- [ ] 完成 LGPL 合规文档

---

## 16. 建议的下一步（立即执行）

1. 先做一个 3 天 Spike：只验证 Qt6 窗口 + Engine 视口嵌入 + 输入转发。  
2. Spike 通过后，按 P0 面板顺序落地，不要并行开太多面板。  
3. 同步建立发布合规清单（LICENSES、第三方依赖、动态链接说明），避免后期返工。
