# Citron Framework: 演进计划 (Zig + CEF)

## 1. 愿景 (Vision)
将 `Citron` 从目前专属于 `Guava` 引擎的 macOS 编辑器壳，孵化成一个开源的、跨平台的、高性能通用桌面应用框架。
目标是打造一个比 Electron 更轻量、比 Tauri 具有更强 C/C++ 生态互操作性的框架，核心技术栈为 **Zig + CEF (Chromium Embedded Framework)**。

## 2. 为什么选择 Zig + CEF？
*   **Zig 的优势**：极简、无隐式内存分配、极致的性能。最重要的是它拥有完美的 C ABI 互操作性（`@cImport`），无需繁琐的 FFI 绑定即可直接调用 CEF C-API。同时，Guava 引擎本身也是用 Zig 编写的，这为未来引擎与编辑器壳的内存级零拷贝通信打下了基础。
*   **CEF 的优势**：提供与 Electron 级别一致的现代 Web 渲染能力（Chromium），但在主进程语言和生命周期控制上给予开发者完全的自由。

## 3. 架构演进方向
### 当前状态 (专用壳)
*   **语言**: Objective-C++ / C++
*   **构建**: CMake
*   **渲染**: WKWebView (仅限 macOS) + MetalViewport
*   **通信**: 强绑定 `EngineRPC` (WebSocket, `127.0.0.1:9100`)

### 目标架构 (通用框架)
*   **Core (主进程)**: 纯 Zig 编写，管理 OS 原生窗口、系统菜单、文件系统对话框等。
*   **WebView (渲染进程)**: CEF 托管的 Chromium 实例，加载前端 HTML/CSS/JS (React/Vue/Svelte)。
*   **IPC 桥接**: 基于 CEF 进程间通信 (Browser Process <-> Render Process) 实现的通用序列化消息路由，提供 `window.citron.invoke` 标准 API。
*   **业务解耦**: Guava 的特定逻辑（如 WebSocket 通信、Metal 渲染）将作为依赖 `Citron` 框架的上层应用逻辑，或者通过插件机制挂载，不再硬编码在框架内部。

## 4. 实施路线图 (Roadmap)

### 阶段一：基础设施搭建与 CEF 绑定 (Foundation & Bindings)
*   **目标**: 跑通 Zig 驱动的 CEF "Hello World" 窗口。
*   **任务**:
    1.  初始化新的 `packages/citron-framework` 目录。
    2.  彻底抛弃 CMake，编写 `build.zig`。配置 CEF 动态库下载、链接以及必需资源文件（`.pak`, `icudtl.dat` 等）的打包逻辑。
    3.  利用 Zig 的 `@cImport` 引入 `cef_app_capi.h` 等纯 C 接口头文件。
    4.  封装基础的 CEF 引用计数机制 (`cef_base_ref_counted_t`)，提供符合 Zig 习惯的内存管理 Wrapper。
    5.  实现主进程生命周期管理，启动 CEF 实例并创建一个加载远程 URL (如 `localhost:5173`) 的原生窗口。

### 阶段二：通用 IPC 桥接 (The IPC Bridge)
*   **目标**: 前端 JS 与后端 Zig 能够进行双向、异步的消息通信。
*   **任务**:
    1.  **JS 环境注入**: 在 CEF 渲染进程的 `OnContextCreated` 回调中，利用 V8 C-API 在 `window` 对象上挂载 `citron` 命名空间及基础 API。
    2.  **消息序列化**: 制定基于 JSON 的 IPC 消息协议（包含 `id`, `method`, `params`）。
    3.  **路由与分发**:
        *   前端 -> 后端: 通过 CEF 的进程间消息发送机制 (`cef_process_message_create`)，将 JS 调用发送至浏览器主进程。
        *   后端路由: Zig 主进程接收消息，解析 JSON，并根据 `method` 名称分发到注册的 Zig 处理函数。
        *   后端 -> 前端: Zig 处理完成后，通过 `ExecuteJavaScript` 或回调将结果/错误返回给指定的 Promise `id`。

### 阶段三：标准库与系统 API 开发 (Standard Library)
*   **目标**: 提供构建现代桌面应用所需的底层系统能力。
*   **任务**:
    1.  **窗口管理 (Window)**: 封装创建多窗口、设置大小、最大化/最小化、全屏、无边框模式等 API。
    2.  **原生对话框 (Dialog)**: 封装平台原生的文件选择、保存、消息提示弹窗 (`std.os` / 平台特定 API)。
    3.  **文件系统 (FS)**: 暴露安全的本地文件读写接口，提供应用数据目录获取等功能。
    4.  **系统级交互**: 剪贴板 (Clipboard)、系统托盘 (Tray)、全局快捷键 (Global Shortcuts)。

### 阶段四：开发者体验与工具链 (DX & Tooling)
*   **目标**: 提供类似 Tauri/Electron 的极简开发工作流。
*   **任务**:
    1.  开发 `citron-cli` 命令行工具 (也可使用 Zig 编写)。
    2.  **`citron dev`**: 自动启动前端构建工具（如 Vite）和 Zig 主进程，配置 HMR 环境变量。
    3.  **`citron build`**: 自动化构建流程。编译前端产物，静态链接 Zig 代码，打包 CEF 资源，生成目标平台的安装包（macOS `.app/.dmg`, Windows `.exe`, Linux `AppImage`）。

### 阶段五：Guava 引擎回迁 (Guava Integration)
*   **目标**: 使用重构后的通用 `Citron` 框架重新构建 Guava 编辑器。
*   **任务**:
    1.  将 Guava Editor 前端项目 (`packages/editor`) 迁移为 `Citron` 框架的应用。
    2.  **性能飞跃**: 由于现在 Citron 框架的主进程也是 Zig，Guava 引擎的核心代码可以作为静态库直接链接进 Citron 的主进程中。
    3.  **移除 WebSocket**: 将原有的 `EngineRPC` 替换为**进程内直接的函数调用**或**共享内存**，彻底消除网络序列化开销，实现真正的零延迟交互（可选）。
    4.  **原生视图插件**: 利用 CEF 的离屏渲染 (OSR) 或自定义原生窗口嵌入机制，将 `MetalViewport` 以后端插件的形式集成回编辑器中。

## 5. 技术挑战与风险评估
1.  **CEF C-API 的复杂性**: CEF 的 C-API 包含大量函数指针和手动引用计数，容易出现内存泄漏或 UAF (Use-After-Free)。
    *   *应对策略*: 尽早在 Zig 中抽象出安全的智能指针类型（如类似 `std.rc.Rc` 的结构）来管理 CEF 对象生命周期。
2.  **多进程架构的调试**: CEF 默认采用多进程模型（Browser, Renderer, GPU 等），调试 Zig 主进程和 CEF 渲染进程中的 C-API 调用较为复杂。
    *   *应对策略*: 初期可以配置 CEF 运行在单进程模式 (`single_process = true`) 以便快速跑通逻辑和断点调试，后期再切换回多进程以保证稳定性。
3.  **跨平台构建配置**: CEF 在 Windows/macOS/Linux 上的链接方式和产物结构差异巨大。
    *   *应对策略*: 充分利用 `build.zig` 的可编程能力，按平台编写清晰的下载、解压和拷贝逻辑。

## 6. 结语
将 Citron 演进为基于 Zig + CEF 的通用框架，不仅能为 Guava 带来极致的性能和内存安全性，更能填补开源社区中缺乏一个高性能、无缝集成 C/C++ 生态的现代桌面应用框架的空白。这不仅是一次代码重构，更是一次极具潜力的开源产品孵化。
