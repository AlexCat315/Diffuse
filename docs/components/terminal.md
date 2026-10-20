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
| `TerminalView(session:fontSize:onOpenLink:)` | 填满给定空间，布局变化时把新的行列数通知程序；`onOpenLink` 处理 ⌘-点击的超链接 |

子进程环境设置 `TERM=xterm-256color`、`COLORTERM=truecolor`、`TERM_PROGRAM=GuavaUI`，缺少 locale 时补 `LANG=en_US.UTF-8`。

## 交互

- 点击获得焦点；聚焦时光标按程序设定闪烁（DECSCUSR，默认闪烁；减弱动态效果时常亮），失焦时显示为空心框。
- 可打印字符走平台文字输入（支持 IME 预编辑、macOS Option 组合字符）；输入法组合期间回车、退格、方向键留给输入法，不发给程序。方向键、功能键、Ctrl 组合等交给 Ghostty 编码器，自动遵循程序的应用光标键、keypad、Kitty 键盘协议等模式。
- 拖动选择文本，双击选词、三击选行，按住 Option 拖动选择矩形块；拖出上下边缘时滚动回滚。⌘C 复制选区（无选区时交给宿主），⌘V 粘贴；其余 ⌘ 快捷键留给宿主。键入会清除选区。
- 程序开启鼠标上报（vim `mouse=a`、htop、tmux 等）时，点击、拖动、滚轮按程序请求的格式（X10/UTF-8/SGR/urxvt/SGR-pixels）上报；按住 Shift 仍可选择文本。
- 超链接：OSC 8 链接始终带下划线；普通文本里的 URL（`https://`、`www.`、`mailto:` 等，去掉句末标点）在悬停时加下划线。两者悬停都显示手形指针，⌘-点击打开：传入 `onOpenLink` 时交给调用方，否则交给系统（仅 http/https/mailto/file）。
- Kitty 图形协议：内联传输的 RGB/RGBA/灰度/PNG 图像按放置位置绘制，`z<0` 画在文字下方；Unicode 占位符（`U=1` 虚拟放置 + U+10EEEE 单元格，tmux 等场景使用）按 Kitty 规则在占位格内等比居中绘制。出于安全，不接受文件与共享内存传输。
- 文字 SGR 5/6 闪烁（只闪文字，背景保持）；减弱动态效果时常亮。
- 方框绘制（U+2500–257F，含粗线、双线、虚线、圆角、斜线）、块元素（U+2580–259F）与 Powerline 分隔符（U+E0B0–E0B3）按几何绘制，跨单元格严丝合缝，不依赖字体。
- 滚轮在主屏滚动回滚缓冲；全屏程序收到上下方向键（或鼠标滚轮上报）。任何输入都会回到实时屏幕。
- 视图填满所在容器（在 `Column`/`Row` 中沿主轴伸展并横向拉伸）；容器未给尺寸时至少显示约 4 行。
- 默认前景/背景色跟随主题的 `onSurface` / `surface`；程序设置的调色板与真彩色照常生效。

## 线程

会话和视图在 UI 线程使用。PTY 输出在后台队列读取，按批合并后经宿主的 UI 调度器（`UIWorkSchedulerHolder`）回到 UI 线程交给 Ghostty，一次只触发一次重绘。

## 构建

`swift run --package-path Tools/Developer guava-dev native-bootstrap` 用 Zig 从固定的子模块 `GuavaUI/third-party/ghostty` 构建 `libghostty-vt.a`，并放入 `GuavaUI/vendor/GhosttyVt.artifactbundle/<triple>`（见 `GuavaUI/third-party/cmake/BuildGhosttyVt.cmake`）。需要 **Zig 0.16.0**；PATH 上版本不对时用 `-DGUAVA_ZIG=/path/to/zig` 指定。macOS 上构建会优先使用 Xcode 的 `libtool`，避免 Homebrew GNU libtool 抢占。

试用：

```bash
swift run --package-path GuavaUI/Terminal TerminalDemo
```

或带开发者工具运行（`GuavaUI/Terminal/guava.json`）：

```bash
./guava run GuavaUI/Terminal --devtools
```

开发者工具可调整窗口尺寸来验证缩放：`guava devtools resize 640 400 --capture small.jpg`（在 `GuavaUI/Terminal` 目录下运行）。

## 限制

- 进程后端：macOS / Linux 用 `forkpty`；Windows 用 ConPTY（Windows 10 1809+，默认 shell 为 PowerShell）。Windows 后端与 Windows 上的 libghostty-vt 构建尚未在 Windows 机器上验证。
- 跨行折返的普通文本 URL 只识别当前行的部分。
