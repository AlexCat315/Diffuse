# Changelog

## Unreleased

- 移除 wgpu-native、RHIWGPU、旧 WGSL 渲染路径与 Rust 构建要求；Engine、Editor、Player 和 GuavaUI 统一使用 NativeRHI。
- 增加原生场景 GPU 回归、着色器产物一致性校验与编译失败保护，修复共享 UI 绘制器的多窗口 MSAA 状态覆盖，并复用固定环境光的 CPU 烘焙结果。
- Android 显示帧时钟断言移入平台无关的 `GuavaAndroidContract` 测试；MCP stdio 协议契约成为 CI 门禁；`guava-dev` 命令标明 CI / Manual / Dev gate。
- `guava-dev` 的 DevTools 客户端从 `validate` 移到 `devtools`：`query-ui`、`input-ui`、`capture-ui`、`record-timings`、`session`。
- Toast 支持最多两个内联操作、四角定位与 `.automatic`（compact 底部、其余右上）并计入安全区；补齐 `toast.md`、单元测试与 DevTools 真实点击/截图验收。
- 诊断工具收进 `UIDiagnosticTool` 单一注册表：name/schema/即时读取标记同源，handler 使用类型化入参；DevTools 与 MCP 共用同一份定义。
- 新增 `ZStack` / `ZStackLayout`：按声明顺序层叠、测量到最大子视图、后声明优先命中、RTL 逻辑边；补齐 `zstack.md`、单元测试、Gallery 页与 DevTools 点击/截图验收。
- 新增 `View.overlay(alignment:)` / `OverlayLayout`：overlay 以 base 尺寸为准、不改变父级布局并优先命中；ZStack Gallery 卡片改用 overlay，避免并列 Text + padding 的偏移问题。
- 新增 `SearchField`：TextField chrome + 前导搜索图标 + clear，联想列表支持过滤、方向键/Return/Escape 与指针选择；补齐 `searchfield.md`、单元测试、Gallery 页与 DevTools 输入/截图验收。
- 新增 `BottomSheet`：44pt 拖拽柄、detent 展开/退档/关闭、compact 贴底与 expanded 居中退化；复用 Modal 焦点/Escape/backdrop，补齐 `bottom-sheet.md`、单元测试、Gallery 页与 DevTools 拖拽/截图验收。
- 新增 `MenuButton` 与 `Popover.triggerStyle`：常规按钮触发器 + Portal 菜单，保留 expanded 语义、Escape/外部点击关闭与菜单键盘导航；补齐 `menubutton.md`、单元测试、Gallery 页与 DevTools 打开/选择/截图验收。
- 新增 `RangeSlider`：双 thumb、就近 active thumb、`minimumSpan` 夹紧、键盘/Home/End 与组合 a11y 值；补齐 `rangeslider.md`、单元测试、Gallery 页与 DevTools 拖动/截图验收。两个 thumb 的独立 Tab/双 slider 语义仍待补。
- 新增 `SplitButton`：主按钮 + MenuButton 箭头，主/备两区独立命中与禁用同步；补齐 `splitbutton.md`、单元测试、Gallery 页与 DevTools 主/备动作验收。单一 Tab + 左右分区与共享 1px 分隔 chrome 仍待补。
- 新增 `DateRangePicker`：真实 Calendar 两击区间、端点/区间高亮、反向点击交换、触发器显示起止日期；补齐 `daterangepicker.md`、单元测试、Gallery 页与 DevTools 选择/截图验收。区间预设与最大长度由应用层负责。
- `ScrollView` 补齐触摸拖动/惯性、4pt 拖动阈值与指针捕获，以及聚焦后的 Arrow/Page/Home/End 键盘滚动；新增 `ScrollViewInputTests`，Gallery `scrollView` 页补充键盘/触摸提示，DevTools 实测 PageDown 偏移。滚动条辅助功能、锚定与带时长程序滚动仍待补。
- `CommandPalette` 结果改用 `VariableVirtualStack`：仅挂载视口 + overscan 行，键盘 highlight 通过 `scrollToIndex` 自动显露；1000 条命令挂载行 <60，行宽/选中背景铺满。补齐 `commandpalette.md`、虚拟化测试与 DevTools 搜索/执行验收。固定 440 的移动端高度与最近使用记录仍待补。
- 新增 `MultiSelectList`：稳定 ID 集合、普通点击/Shift 区间/Cmd-Ctrl 切换、Shift+Arrow、Cmd/Ctrl+A、Space 切换与 Return 激活；复用 `List` 的虚拟化/行 host/style。补齐 `MultiSelectListTests`、Gallery `multiSelectList` 页与 DevTools Shift 区间验收。区块/重排/swipe/下拉刷新仍待补。
- 新增 `SectionedList`：平面 section header/footer、跨区段键盘选择、`VirtualStack` 虚拟化与单行选中；header/footer 不进入焦点。补齐 `SectionedListTests`、Gallery `sectionedList` 页与 DevTools 行选择验收。重排/swipe/下拉刷新仍待补。
- `SectionedList` 增加 `stickyHeaders`：当前区段标题随滚动固定在视口顶部，下一标题上推并在到达顶部后接替；固定条覆盖行内容区、保留稳定滚动条槽并以 1pt 底部分隔线收边，固定副本不参与焦点、命中与语义，列表外层裁剪。`VirtualStack` 增加内部滚动 offset 观察入口，固定标题与 `scrollToIndex`/触摸行高/字号缩放共用同一几何。补齐 sticky 单元测试（含仅一份语义断言）、Gallery 三段可滚动示例、自适应预览与 DevTools 滚动条拖动/截图验收。重排/swipe/下拉刷新仍待补。
- 窄宽重排：`Stepper` 按每步 148pt 预算在宽/窄 retained 分支间切换，窄宽纵向堆叠并改用 Up/Down；`StepperOptions.minimumHorizontalStepWidth` 可提高长标题预算。`ButtonGroup` 段改为可换行且不压缩；`Vec3Field` 以 96pt 基准/88pt 最小宽换行，窄宽 X/Y 一行、Z 下一行。补齐 `NarrowReflowTests`（390/720、触摸、轴感知键盘）、三个 Gallery 页与自适应预览；DevTools 实测 390pt 三步骤为 56pt 纵向行、720pt 单行，并截图确认 ButtonGroup/Vec3 换行。原地切换同一 `Box` 方向曾把步骤压成 0pt，改用 retained 宽/窄树后修复。

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
