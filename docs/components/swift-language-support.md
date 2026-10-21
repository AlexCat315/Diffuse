---
path: /zh/docs/components/swift-language-support
title: 'Swift 语言支持'
description: 'Swift 工具链、语言服务与脚本编辑操作'
locale: zh
translationKey: components/swift-language-support
category: components
order: 100
kind: doc
---

# Swift 语言支持

Swift Support 是随编辑器捆绑的轻量 WASM 插件，不包含 Swift 编译器、SourceKit-LSP 或 Apple SDK。语言服务进程仍受 PluginHost 授权与生命周期约束，下载与工具链选择由宿主负责，不授予插件任意网络访问或安装权限。

## 本机优先

宿主先检查显式编译器参数、`GUAVA_SWIFTC_PATH`、`GUAVA_SWIFT_TOOLCHAIN_PATH` 与本机保存的工具链路径，再查询 PATH 和 macOS 的 Xcode / Command Line Tools。`GUAVA_SOURCEKIT_LSP_PATH` 是宿主配置，若与编译器不是同一套工具链则拒绝启动。项目文件不能改变这些选择。

解析器通过编译器报告的标准库资源目录固定真实工具链，避免 swiftly shim 因工作目录或项目版本文件选择另一套版本。脚本编译与语言分析共享编译器目录、`SDKROOT`、`SOURCEKIT_TOOLCHAIN_PATH`、`SWIFT_EXEC` 和模块搜索路径。

语言服务启动前运行隔离的类型检查，验证 Swift 标准库、ScriptRuntime、SceneRuntime 与 Clang module map/include 路径。检查失败给出具体错误，不把“进程运行中”当作分析正常。切换工具链必须等待当前编译结束，校验成功后重建语言服务的插件挂载；不会自动编译或执行项目脚本。

分析参数还显式固定 SDK 与 Swift 资源目录，并用于临时 fallback 设置。生成的分析缓存记录工作区位置、编译器、SDK、Guava 模块和参数身份；目录迁移、工具链/SDK 更新或身份缺失时，只清理生成的 `.build`，避免复用包含旧绝对路径的模块缓存而报“标准库加载失败”。正常重启保留匹配的缓存，缓存目录为符号链接时拒绝清理。

## 显式安装

底栏“语言服务 → Swift 工具链”提供路径输入、本机安装选择、自动检测、固定版本下载和下载版本清理。下载前必须再次确认。下载、校验、展开与环境检查均可报告状态；取消或失败后可重新尝试。

macOS 的自动安装目录为用户 Application Support 下的 `GuavaStudio/SwiftToolchains/Installed`。偏好也存放在该用户目录，Editor.app 与项目目录都不存放下载的工具链。当前目录提供固定的官方 Swift 6.4.1 / 6.4.0 macOS 通用安装包；只接受 download.swift.org 的 HTTPS 成功响应与同源重定向。展开前用系统 pkgutil 验证受信任签名及 Swift Open Source 的安装者身份，检查版本并通过同卷移动原子发布。进程退出会释放安装互斥锁，取消与失败会删除本次 staging。

签名身份以 [Swift 官方 macOS 安装说明](https://www.swift.org/install/macos/package_installer/) 为准。清理入口拒绝移除当前实例选中的工具链；清理前也须停止其他仍使用该版本的编辑器实例或外部编译任务。

工具链本身不提供 Apple SDK；macOS 仍需安装 Xcode 或 Command Line Tools。Linux、Windows 可检测与选择本机工具链，但当前不提供自动安装目录项，须先通过官方安装方式安装。安装包体积较大，测试不会自动下载真实工具链。

## 编辑操作

| 操作 | 快捷键 |
| --- | --- |
| 定义跳转 | F12 |
| 查找引用 | Shift+F12 |
| 重命名符号 | F2 |
| 快速修复 / Code Actions | Cmd/Ctrl+. |
| 参数提示 | Cmd/Ctrl+Shift+Space；输入参数时自动请求 |
| 文档大纲 | Cmd/Ctrl+Shift+O |
| 格式化文档 | Option/Alt+Shift+F |
| 返回上一位置 | Option/Alt+Left |

这些操作也可从代码编辑器右键菜单或脚本工具栏菜单触发。定义与引用结果可打开项目脚本；项目外定义以只读形式打开，并保留返回位置。补全直接使用编辑器现有的 snippet 会话，Tab / Shift+Tab 在占位符之间移动。

重命名、格式化及提供 WorkspaceEdit 的 Code Actions 只修改已有项目脚本的编辑缓冲区。请求前固定文档版本，应用前整体核验 revision、路径、UTF-16 范围与重叠；任何一处冲突都会拒绝整组修改。跨文件操作作为一个事务撤销/重做，不自动写盘或执行代码。后续输入尚未撤销时，工作区撤销不会覆盖它。外部文件修改、创建/删除/移动资源操作及需要执行服务端命令的 Code Actions 会明确拒绝，而不是偷偷修改磁盘。

每份游戏脚本仍按独立编译目标分析，以符合其独立动态库的运行方式；语言服务不会把所有同名 GameScript 声明合并到一个模块。具体语义功能还取决于安装的 SourceKit-LSP 版本与索引完成情况。
