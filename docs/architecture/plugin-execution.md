---
path: /zh/docs/architecture/plugin-execution
title: '跨平台插件执行'
description: '跨平台插件执行 — GuavaStudio documentation'
locale: zh
translationKey: architecture/plugin-execution
category: architecture
order: 100
kind: doc
---

# 跨平台插件执行

Guava 插件保持同一套三文件契约：`plugin.json` 声明身份和权限，`capabilities.wit` 声明输入类型，`component.wasm` 承载 Component Model 代码。权限和 schema 不由插件运行结果动态决定。

| 宿主 | 运行库 / 执行方式 | 生命周期与隔离 |
| --- | --- | --- |
| macOS、Windows、Linux 桌面 Editor | 静态链接 Wasmtime 49.0.2 | `GuavaPluginHost` 独立进程、带长度帧 RPC |
| Android 应用 | 同版本 Wasmtime C API | `EmbeddedPluginSession`，应用进程内的 fresh Store |
| iOS 16+ 应用 | 同版本 Wasmtime + Pulley | 强制解释执行，应用进程内的 fresh Store，不要求 guest JIT |
| Web | 经原生校验的 Component + Jco | 每次调用独立 Worker / Wasm 实例，超时终止 Worker |

原生包的版本与校验值来自 [Wasmtime catalog](../../Engine/third-party/wasmtime/catalog.json)。交付方式与构建步骤见 [构建说明](../../Engine/third-party/wasmtime/README.md)。所有原生目标使用 `Wasmtime.artifactbundle`，支持一次保存多个 variant，不依赖本地 Wasmtime CLI。原有无法调用强类型 ABI 的 CLI 适配器和动态 XCFramework 路径已移除。

桌面继续使用进程宿主的检查、授权、加载、准备、卸载流程。静态链接消除了发行包额外寻找 Wasmtime 动态库的要求。移动应用通过异步入口使用相同的授权校验和结果验证：

```swift
import Foundation
import PluginRuntime
import PluginWasmtimeRuntime

let inspection = try await EmbeddedPluginSession.inspect(at: packageURL)
// 应用展示身份、imports、access、contracts，取得用户授权后保存这份精确记录。
let authorization = try PluginAuthorizationRecord(inspection: inspection)
let plugin = try await EmbeddedPluginSession.open(at: packageURL, authorization: authorization)
let result = try await plugin.prepare(
    capabilityID: "safe.reader.inspect",
    input: Data(#"{"enabled":true}"#.utf8)
)
```

`open` 创建宿主私有执行副本并重新核对 code/WIT/manifest/契约；用户修改来源目录不会改变已经打开的会话。会话使用 actor 串行执行，昂贵工作不要求调用方安排主线程以外的线程。每次调用重新创建 Store，应用不需要传递 Wasmtime 内部上下文或句柄。自定义宿主写入能力的应用可传入自己的 `CapabilityRegistry`，返回的 host calls 必须由该应用现有的授权执行入口提交。

原生保留 fuel、Store memory/table/instance 限制、epoch interruption 和 wall-clock deadline。iOS 使用的 Pulley 保留这些 API，但执行性能不能按原生机器码估算。移动进程内隔离无法提供桌面独立进程对运行库崩溃的隔离；组件编译也不具备可抢占的 epoch 中断。

Web 构建阶段复用 Swift 宿主的真实 Component 类型检查和权限校验，运行时消费其导出的 WIT 类型、inspection 和 host contracts。应用可信目录固定转换产物的哈希；用户授权再绑定精确版本。Worker 只链接获准的三个 Guava 查询接口，使用本次 revision-bound JSON 快照。浏览器无法提供 Wasmtime fuel/epoch，采用 Worker wall-clock deadline 并在 core Wasm 中编码 memory/table 上限。完整步骤、API 和边界见 [Web 插件目标](../../Platforms/Web/Plugins/README.md)。

验证分两层：`PluginRuntimeTests` 检查 Swift 授权、immutable staging、typed input、进程 RPC、查询和中断；`Engine/Validation/Plugins` 的同一组 Component fixture 可在本机、Android 真机和 iOS Simulator 执行。Web 的浏览器 gate 再复用这些 fixture 检查转换与 Worker 路径。Windows/Linux 运行库由各自 CI runner 执行，Mac 上的交叉构建不能代替这两种系统的实际运行验证。
