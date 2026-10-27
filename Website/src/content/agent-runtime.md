# Agent 运行时

Diffuse 的核心特色是 AI Agent 驱动。Agent 不是外挂的聊天框，而是深度嵌入引擎的运行时能力。

## 运行时组成

| 模块 | 职责 |
|------|------|
| `AIRuntime` | Agent 执行循环与工具调度 |
| `IntentRuntime` | 解析用户意图，映射为可执行动作 |
| `PerceptionRuntime` | 感知当前工程与场景状态 |
| `ContextMemory` | 上下文与长期记忆 |
| `CapabilityRuntime` | 能力声明与权限控制 |
| `SemanticPipeline` | 语义分析与信息检索 |
| `ObservationBus` | 引擎事件的可观察总线 |

## 工作循环

```
用户自然语言
   │
   ▼
IntentRuntime 意图解析
   │
   ▼
PerceptionRuntime + ContextMemory  感知状态、回忆上下文
   │
   ▼
CapabilityRuntime  匹配可用工具与权限
   │
   ▼
AIRuntime  调度工具调用（可多步、可回滚）
   │
   ▼
ObservationBus  观察引擎执行结果
   │
   ▼
向用户汇报 / 继续下一步
```

## 统一工具入口

文本、代码、视频与场景工作流共用同一个 Agent 工具入口。这意味着同一句"帮我把这段视频的第三段剪掉并加个标题"，可以跨时间线、文本与渲染模块协同完成。

## MCP 服务器

`DiffuseMCP` 实现了 MCP（Model Context Protocol）服务器，把 Diffuse 编辑器与引擎的能力标准化地暴露给外部 LLM agent：

```bash
./cove internal build-package DiffuseMCP --product DiffuseMCP
```

## 插件与 Agent

Agent 可以调用插件提供的能力：

- 原生插件通过 `PluginRuntime` 直接接入
- WASM 插件通过 `PluginWasmtimeRuntime` 在沙箱中运行，能力通过 `CapabilityRuntime` 受控暴露

## 确定性与安全

- 工具调用经过 `CapabilityRuntime` 的权限校验
- WASM 插件在 Wasmtime 沙箱中运行，无法直接访问宿主资源
- 每一步操作都可观察、可回放，便于审计与撤销
