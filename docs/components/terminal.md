# Terminal

`GuavaUITerminal` 是桌面端终端组件：在伪终端（PTY）上运行一个程序，用 GuavaUI 的 DrawList 绘制它的屏幕。VT 解析、屏幕/回滚缓冲、键盘编码和粘贴编码来自 [Ghostty](https://github.com/ghostty-org/ghostty) 的 **libghostty-vt**（零依赖 C 库）；进程、输入路由与绘制在 GuavaUI 内实现。Ghostty 的 C 类型只出现在 `Engine/` 目录，不进入公开 API。

它是独立包 `GuavaUI/Terminal`，不是 `GuavaUI` 包的一部分，因此 iOS、Android 与浏览器构建不会加载 Ghostty 产物。

```swift
// Package.swift
.package(path: "../GuavaUI/Terminal"),
// target
.product(name: "GuavaUITerminal", package: "Terminal"),
```

## API

```swift
import GuavaUI
import GuavaUITerminal

final class Console: View {
    @State var shell = TerminalSession()   // 默认 $SHELL -l
    @State var title = ""

    var body: some View {
        shell.onEvent = { [weak self] event in
            if case .titleChanged(let title) = event { self?.title = title }
        }
        return TerminalView(session: shell, fontSize: 13)
            .frame(height: 320)
    }
}
```

| API | 说明 |
| --- | --- |
| `TerminalSession(command:scrollbackLines:)` | 终端会话；放在 `@State` 等长生命周期位置，重组不会重启程序 |
| `TerminalCommand(executable:arguments:workingDirectory:)` | 要运行的程序；无斜杠的名字按 `PATH` 查找；`environment` 覆盖继承的环境变量 |
| `TerminalCommand.loginShell` | `$SHELL -l`，缺省 `/bin/sh` |
| `start()` | 启动程序。`TerminalView` 首次出现时会自动启动 `idle` 会话；失败写入 `status = .failed` 并显示在终端里 |
| `send(_:)` / `paste(_:)` | 以键入方式发送文本；按程序的 bracketed-paste 模式粘贴 |
| `terminate()` | 挂断（SIGHUP），等同关闭终端窗口 |
| `status` / `title` / `onEvent` | `.idle/.running/.exited(code:)/.failed`；OSC 0/2 标题；标题变化、响铃与退出事件（UI 线程） |
| `TerminalView(session:fontSize:)` | 填满给定空间；布局变化时把新的行列数通知程序 |

子进程环境设置 `TERM=xterm-256color`、`COLORTERM=truecolor`、`TERM_PROGRAM=GuavaUI`，缺少 locale 时补 `LANG=en_US.UTF-8`。

## 交互

- 点击获得焦点；失焦时光标显示为空心框。
- 可打印字符走平台文字输入（支持 IME 预编辑、macOS Option 组合字符）；方向键、功能键、Ctrl 组合等交给 Ghostty 编码器，自动遵循程序的应用光标键、keypad、Kitty 键盘协议等模式。
- ⌘V 粘贴剪贴板；其余 ⌘ 快捷键留给宿主。
- 滚轮在主屏滚动回滚缓冲；全屏程序（vim、less、htop，使用备用屏）收到上下方向键。任何输入都会回到实时屏幕。
- 默认前景/背景色跟随主题的 `onSurface` / `surface`；程序设置的调色板与真彩色照常生效。

## 线程

会话和视图在 UI 线程使用。PTY 输出在后台队列读取，按批合并后经宿主的 UI 调度器（`UIWorkSchedulerHolder`）回到 UI 线程交给 Ghostty，一次只触发一次重绘。

## 构建

`swift run --package-path Tools/Developer guava-dev native-bootstrap` 用 Zig 从固定的子模块 `GuavaUI/third-party/ghostty` 构建 `libghostty-vt.a`，并放入 `GuavaUI/vendor/GhosttyVt.artifactbundle/<triple>`（见 `GuavaUI/third-party/cmake/BuildGhosttyVt.cmake`）。需要 **Zig 0.16.0**；PATH 上版本不对时用 `-DGUAVA_ZIG=/path/to/zig` 指定。macOS 上构建会优先使用 Xcode 的 `libtool`，避免 Homebrew GNU libtool 抢占。

试用：

```bash
swift run --package-path GuavaUI/Terminal TerminalDemo
```

## 限制

- 仅 macOS / Linux（`forkpty`）；Windows（ConPTY）尚未实现，`start()` 抛出 `.unsupportedPlatform`。
- 尚未实现：鼠标选择与复制、程序的鼠标上报（mouse tracking）、超链接、Kitty 图形协议、光标闪烁。
- 方框绘制字符使用字体字形，回退字体下线条可能不衔接（Ghostty 自身用程序化绘制）。
