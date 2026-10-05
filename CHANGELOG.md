# Changelog

## 0.0.9 — 2026-10-06

- 编辑器加入启动页项目管理、Crystal Rush 示例模板、场景和脚本并排工作区、统一深浅色主题及性能分析视图。
- Swift 脚本支持语法高亮、LSP 提示、编译诊断、文本撤销重做，以及随游戏导出后由 Player 直接运行。
- 渲染加入正交视图、地面网格与坐标轴、精确网格拾取、透明和双面材质、大场景剔除与实例化，以及真实 GPU 回归测试。
- 完善物理、粒子、AI/MCP 项目工具、脚本生命周期和 GuavaUI 交互。
- 本地与 CI 工具链统一使用 Swift 6.4.0、Rust 1.99.0、CMake 4.4.4、Ninja 1.13.2、Python 3.14.8；官网使用 Node.js 26.10.0 和 npm 12.2.0。
- 原生依赖更新为 SDL 3.4.18、Imath 3.2.3、OpenEXR 3.5.2、Jolt 5.6.0、FreeType 2.14.3、HarfBuzz 14.5.1、wgpu-native 29.0.1.1、Wasmtime 49.0.2、plutovg 1.3.3；swift-log 更新为 1.15.1。
- Lunasvg 3.5.0、libwebp 1.6.0、Yoga 3.2.1 和 stb_image 2.30 已是各自最新稳定版。
- 官网依赖升级到最新兼容版本。TypeScript 使用 6.0.3（typescript-eslint 8.71.1 要求 <6.1.0）；Unhead 使用 2.1.17、Beasties 使用 0.3.5（vite-ssg 28.3.0 的兼容版本）。
- 适配 OpenEXR 3.5 的静态打包与 Jolt 5.6 / Wasmtime 49 的桥接 API，并修复原生强制重建缓存失效。
- 修复 Linux 物理基准编译、静态库链接和重复的 CGRect 兼容扩展；修复 Windows 动态库加载和内存统计；完善 macOS SDK 与跨平台 C 模块映射发现。
- 修复无界面编辑器计时器的主 actor 隔离、跨平台 JSON 数字与布尔值区分、脚本编译取消超时、CI 并发测试线程调度，以及文档元数据缺失。
- 适配 Swift 6.4 带平台后缀的构建目录及 `.build/debug` 符号链接，修复 Windows LSP 可执行文件发现和跨平台脚本测试；Windows JSON 校验不再依赖 SDK 未公开的 CoreFoundation 模块。
- 适配新版 WinSDK 的布尔返回值，并从 Swift 独立运行时目录收集 Windows 发布包所需 DLL。
- 修复 Windows 短路径、路径大小写及尾部分隔符造成的脚本目录误判和音频导出遗漏；可执行文件查找验证候选文件确实存在，资产重新导入使用 Windows 原子替换 API。
- 修复 DevTools WebSocket 测试提前断开连接的竞争，并使用可控帧时钟验证事件驱动模式的时间步长。
- 规避 Windows Foundation 跳过目录后停止遍历其他子目录的问题，修复资产与音频扫描；脚本更新按实际文件位置匹配，保留稳定标识与未保存文本保护。
- 插件超时先终止宿主再关闭管道；完善渲染回调同步、UI 测试共享字体和动画调度器隔离，以及场景导出时间戳的测试处理。
- 编辑器项目生命周期测试覆盖三平台；完整 Swift ScriptBehavior 编译和导出运行沿用 macOS/Linux 支持范围，Windows 保留预置场景播放。
- 修复脚本库卸载后 Swift 运行时访问失效元数据的崩溃。热重载释放旧脚本实例，但已加载的 Swift 代码保留到进程退出。
- CI 更新到新版 GitHub Actions 和 Xcode 27.0 / Visual Studio 2026 runner，macOS 使用 `xcode-27` 镜像，避免回退到 Xcode 26.6。发布包通过安装与启动验证后，才公开 Release 草稿。
- macOS CI 使用 Xcode 27 自带的 Swift 6.4，避免独立开源工具链缺失 Apple 平台导致 Swift 构建失败；Linux 和 Windows 使用独立 Swift 6.4 工具链。

发布产物：macOS arm64、Windows x86_64、Linux x86_64 编辑器包，包含 Player 和 MCP 工具。
