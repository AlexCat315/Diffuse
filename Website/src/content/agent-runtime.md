# Agent 运行时

AI 模式由 `studio.ai` 插件提供。它使用 TypeScript/Bun 实现模型通信、执行循环、项目分组、独立会话和界面。宿主提供窗口、原生组件以及文档、场景和媒体编辑服务。

## 工作流程

```text
会话输入
   ↓
AI 插件：会话上下文、选中的 Skill、可用工具
   ↓
模型 Provider：流式响应与工具请求
   ↓
工具扩展服务 / 编辑器作业
   ↓
项目版本与权限校验、场景事务确认
   ↓
结果回到原会话，继续执行或结束
```

每个执行绑定自己的会话和项目。切换前台页面不会改变目标，也不会清空其他会话的消息。

## 原生编辑服务

`CapabilityRuntime` 负责能力声明与参数校验，`IntentRuntime` 继续承载场景事务及确认管线。`PerceptionRuntime`、`ContextMemory`、`SemanticPipeline` 和 `ObservationBus` 提供项目感知、记忆和观察服务。

这些原生模块不决定第三方模型使用什么 HTTP 格式。AI 插件与其他插件通过公开服务接口使用编辑能力。现有 `DiffuseMCP` 也继续使用相同的项目工具与能力入口。

## 扩展

AI 插件声明 Provider、工具和 Skill 扩展点。第三方提供服务和业务数据，AI 插件负责发现及使用；插件开发者不需要修改宿主的 Provider 枚举或增加专用页面。

具体契约见[服务与 AI 扩展](/docs/plugin-services)，并发与恢复行为见[项目与会话](/docs/conversations)。

## 退出

禁用 AI 插件后，其模式和贡献退出，所属执行停止。会话历史保留为用户数据。Bun 插件采用可信桌面扩展模型，不能沿用 Wasm 沙箱的权限承诺。
