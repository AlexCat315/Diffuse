# Guava Engine: ImGui → Electron Editor Migration Plan

## Executive Summary

将编辑器从 ImGui 即时模式 UI 迁移到 Electron 进程外架构。引擎作为无头渲染服务器运行，通过 WebSocket JSON-RPC 与 Electron 编辑器通信。同时解决以下两个附带目标：

1. **Editor/Player 完全分离** — 确保游戏运行时零编辑器代码
2. **游戏内 Web 渲染** — 支持游戏中的交互式网页表面（如游戏中的电脑屏幕）

---

## Architecture Overview

```
┌─ Electron Editor Process ─────────────────────────────────────────┐
│                                                                    │
│  ┌─ Main Process (Node.js) ─┐   ┌─ Renderer Process (Chromium) ─┐│
│  │  EngineClient (WS)       │   │  React UI                     ││
│  │  ChildProcess management │   │  ├─ SceneHierarchy             ││
│  │  Native window handle    │   │  ├─ Inspector                  ││
│  └──────────┬───────────────┘   │  ├─ ContentBrowser             ││
│             │                   │  ├─ AnimationEditor             ││
│             │                   │  ├─ Console                     ││
│             │                   │  └─ ... 29 panels               ││
│             │                   └────────────────────────────────┘ │
└─────────────┼─────────────────────────────────────────────────────┘
              │ WebSocket (ws://127.0.0.1:9100)
              │ JSON-RPC 2.0
┌─────────────┼─────────────────────────────────────────────────────┐
│ Engine Process (guava-engine --editor-server)                      │
│                                                                    │
│  ┌─ EditorRpcServer ────────┐   ┌─ RHI + Renderer ─────────────┐ │
│  │  WebSocket listener      │   │  Offscreen / Embedded window  │ │
│  │  JSON-RPC dispatch       │   │  Metal / Vulkan swapchain     │ │
│  │  State subscriptions     │   └───────────────────────────────┘ │
│  │  Reuses protocol.zig     │                                      │
│  └──────────────────────────┘   ┌─ World + Physics + Scripts ───┐ │
│                                  │  (unchanged)                  │ │
│                                  └───────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

---

## Phase 0: Infrastructure Foundation

### 0.1 EditorRpcServer (Zig 侧)
- 新增 `src/engine/editor_rpc/server.zig` — WebSocket 服务器
- 复用 `src/engine/mcp/protocol.zig` 的 JSON-RPC 编解码
- 监听 `127.0.0.1:9100`（可配置端口）
- 支持多客户端连接（editor + 可能的扩展插件）
- 作为 Layer 挂载在 Application 上，每帧处理 pending RPC

### 0.2 CLI 扩展
- 新增 `--editor-server` 标志：启动引擎为无窗口/嵌入窗口模式
- 新增 `--editor-port <port>` 指定 RPC 端口
- 新增 `--parent-window <handle>` 接受 Electron 传入的原生窗口句柄

### 0.3 Electron App Scaffold
- `editor-electron/` 目录，独立 `package.json`
- Electron main process: 启动引擎子进程 + WebSocket 连接
- React + TypeScript renderer process
- 基础通信验证：ping/pong

### 0.4 Viewport 嵌入
- **方案 A（首选）**：原生子窗口
  - 引擎创建 SDL3 无边框窗口
  - Electron 获取 `BrowserWindow.getNativeWindowHandle()`
  - macOS: `[nsEngineWindow setParentWindow:electronNSWindow]`
  - Windows: `SetParent(engineHWND, electronHWND)`
  - 引擎窗口定位/缩放由 Electron 通过 RPC 控制

---

## Phase 1: Minimal Viable Editor

### RPC Methods (engine → electron 双向)

**State Queries:**
```
scene.getHierarchy()     → EntityNode[]
scene.getComponents(id)  → Component[]
scene.getTransform(id)   → Transform
asset.listDirectory(path) → AssetEntry[]
editor.getState()        → EditorStateSnapshot
```

**Mutations:**
```
scene.createEntity(parent?, name)    → EntityId
scene.deleteEntity(id)               → void
scene.setTransform(id, transform)    → void
scene.reparent(id, newParent)        → void
component.add(entityId, type, data)  → void
component.remove(entityId, type)     → void
component.update(entityId, type, k, v) → void
editor.undo()                        → void
editor.redo()                        → void
```

**Subscriptions (server → client push):**
```
on:scene.changed       → { revision, diff }
on:selection.changed    → { entityIds }
on:viewport.resized     → { width, height }
on:console.log          → { level, message, timestamp }
```

### Electron UI (Phase 1 Panels)
1. Scene Hierarchy — 树形视图 + 搜索 + 拖拽
2. Inspector — 属性编辑器 + 组件管理
3. Viewport — 嵌入式原生窗口（引擎渲染）
4. Console — 日志流
5. Toolbar — 播放/暂停/变换模式切换

---

## Phase 2: Full Panel Migration

逐步迁移剩余 24 个面板，优先级：

| Priority | Panel | Complexity |
|----------|-------|-----------|
| P0 | Content Browser | High — 缩略图、拖放 |
| P0 | Material Editor | Medium — PBR 参数 + 预览球 |
| P1 | Animation Editor | High — Timeline + 关键帧 |
| P1 | Sequencer | High — 多轨道 timeline |
| P1 | Post-Process Editor | Medium — 节点图 |
| P2 | Script Editor | High — 代码编辑器（考虑嵌入 Monaco） |
| P2 | Particle Editor | Medium |
| P2 | Prefab Browser/Editor | Medium |
| P3 | All debug panels | Low-Medium |
| P3 | Camera Bookmarks | Low |
| P3 | AI Chat | Medium — 已有 MCP 基础 |

---

## Phase 3: 游戏内 Web 渲染（In-Game Web Surfaces）

### 用途
游戏中的电脑屏幕、信息终端、交互式 UI、数据可视化等需要在 3D 场景中显示网页。

### 架构
```
┌─ Game World ─────────────────────────────────────────────┐
│                                                           │
│  Entity: "TerminalScreen"                                 │
│  ├─ MeshComponent (plane geometry)                        │
│  ├─ MaterialComponent (unlit, texture = web_surface)      │
│  └─ WebSurfaceComponent                                   │
│      ├─ url: "game://terminal/main.html"                  │
│      ├─ width: 1024                                       │
│      ├─ height: 768                                       │
│      ├─ interactive: true                                 │
│      └─ fps: 30                                           │
│                                                           │
│  ┌─ WebSurfaceSystem ──────────────────────────────────┐  │
│  │  Manages CEF (Chromium Embedded Framework) instances │  │
│  │  Renders HTML → offscreen texture → GPU upload       │  │
│  │  Routes input: raycast hit → mouse/keyboard events   │  │
│  └──────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

### 实现选型
- **CEF (Chromium Embedded Framework)** — 最成熟，UE4/5 使用
- 替代方案：ultralight（轻量但功能受限）
- CEF 作为可选 third_party 库，仅在需要 web surface 的游戏中链接
- 与 Electron editor 共享零代码 — CEF 是独立的渲染层

### WebSurfaceComponent 生命周期
1. `onAttach` — 创建 CEF browser instance + offscreen RenderHandler
2. `onUpdate` — CEF 调用 `OnPaint()` → 将像素数据上传到 RHI Texture
3. `onInput` — Raycast 命中 → 转换为 CEF mouse/keyboard 事件
4. `onDetach` — 销毁 CEF browser instance

---

## Phase 4: Cleanup & Editor/Player Separation

### 当前状态（已做的好）
- `guava-player` (player_main.zig) **已经没有任何 editor 代码**
- `guava-engine` (main.zig) 包含完整 editor overlay

### 迁移后的目标构建矩阵

| Binary | 包含 | 用途 |
|--------|------|------|
| `guava-engine --editor-server` | Engine + EditorRpcServer | Electron editor 后端 |
| `guava-engine --mcp` | Engine + MCP Server | AI 协作模式 |
| `guava-player` | Engine only | 发布游戏运行时 |
| `guava-player --web-surface` | Engine + CEF | 带 web 渲染的游戏运行时 |

### ImGui 清理
- 从 editor build 中移除 ImGui（editor 完全在 Electron）
- ImGui 可保留为**可选的游戏内 debug overlay**组件
- `gui.zig` 抽象层保留，后端改为 noop/debug

---

## File Structure (new)

```
editor-electron/                    # Electron editor (独立仓库/目录)
├── package.json
├── tsconfig.json
├── electron-builder.yml
├── src/
│   ├── main/                       # Electron main process
│   │   ├── index.ts                # Entry: spawn engine, create window
│   │   ├── engine-client.ts        # WebSocket JSON-RPC client
│   │   ├── engine-process.ts       # Child process management
│   │   └── viewport-embed.ts       # Native window embedding
│   ├── renderer/                   # React UI
│   │   ├── App.tsx
│   │   ├── store/                  # State management
│   │   ├── components/             # Reusable UI widgets
│   │   └── panels/                 # Editor panels (1:1 with Zig panels)
│   │       ├── SceneHierarchy.tsx
│   │       ├── Inspector.tsx
│   │       ├── ContentBrowser.tsx
│   │       ├── Console.tsx
│   │       ├── AnimationEditor.tsx
│   │       └── ...
│   ├── shared/                     # Shared types
│   │   ├── rpc-types.ts            # JSON-RPC method types
│   │   └── engine-types.ts         # Engine data model types
│   └── preload/
│       └── preload.ts              # Context bridge
└── assets/                         # Editor icons, themes

src/engine/editor_rpc/              # Engine 侧 RPC 服务 (new)
├── server.zig                      # WebSocket server + dispatch
├── methods.zig                     # RPC method implementations
├── subscriptions.zig               # Push notification system
└── websocket.zig                   # Minimal WebSocket protocol

src/engine/web_surface/             # 游戏内 Web 渲染 (Phase 3, new)
├── cef_bridge.zig                  # CEF C API wrapper
├── web_surface_system.zig          # ECS system
└── web_surface_component.zig       # Component definition
```

---

## Migration Timeline

| Phase | Scope | 依赖 |
|-------|-------|------|
| **Phase 0** | RPC server + Electron scaffold + viewport embed | None |
| **Phase 1** | 5 core panels + basic editing workflow | Phase 0 |
| **Phase 2** | 24 remaining panels | Phase 1 |
| **Phase 3** | CEF in-game web surfaces | Independent |
| **Phase 4** | ImGui removal + build cleanup | Phase 2 |

---

## Key Decisions

1. **WebSocket over stdio** — 允许多客户端、双向 push、无序列化争用
2. **JSON-RPC 2.0** — 复用已有 protocol.zig 编解码，TypeScript 侧有成熟库
3. **Native child window** — 最低延迟 viewport 方案，无需帧传输
4. **CEF for in-game** — 与 Electron editor 完全独立，不共享进程
5. **React + TypeScript** — 最大生态、最快迭代、自然支持 Monaco editor 嵌入
