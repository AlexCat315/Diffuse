# 服务与 AI 扩展

插件可以提供自己的服务和扩展点。服务通过公开契约连接，扩展点由拥有它的插件定义业务数据，宿主负责注册、查找和退出清理。

## 提供服务

```json
{
  "cove.service/v1": [{
    "id": "example.translation/v1",
    "title": "Translation",
    "entryPoint": "translate"
  }]
}
```

服务入口使用 `{ record: { request: 'string' } }`。请求字符串包含调用方的 JSON 参数，入口返回 JSON 结果。服务名称包含版本。

调用方声明 `cove:service/host` import，并使用 SDK：

```ts
import { hostJob } from '@diffuse/plugin-sdk';
const translated = await hostJob(context, 'cove:service/host', {
  service: 'example.translation/v1',
  input: { text: 'Hello' }
}, signal);
```

宿主以作业标识执行跨插件请求。轮询、结果与取消均校验调用者身份。长任务应立即返回自己的流句柄，再通过短的 poll/cancel 调用处理后续事件。

## 提供扩展点

拥有者声明：

```json
{
  "cove.extensionPoint/v1": [{
    "id": "example.workflow.steps/v1",
    "title": "Workflow Steps"
  }]
}
```

扩展包在 `requires` 声明对拥有者的依赖，并提供：

```json
{
  "cove.extension/v1": [{
    "id": "translate",
    "point": "example.workflow.steps/v1",
    "data": { "service": "example.translation/v1" }
  }]
}
```

拥有者通过服务查询读取扩展，并验证其业务字段：

```ts
await context.query('cove:service/host', {
  operation: 'extensions', point: 'example.workflow.steps/v1'
});
```

拥有者未启用时，该扩展点不返回扩展。资源通过 `operation: 'resource'`、`pluginID` 与资源 `id` 读取，只接受所属包已经声明、通过摘要校验的文本资源。

## AI 扩展点

AI 插件拥有以下扩展点：

| 扩展点 | data 字段 |
| --- | --- |
| `studio.ai.providers/v1` | `title`、`service` |
| `studio.ai.tools/v1` | `name`、`description`、`parameters`、`service`、`readOnly` |
| `studio.ai.skills/v1` | `title`、`instructions` 或 `resource` |

模型 Provider 的服务接收 `start`、`poll`、`cancel`。start 请求包含模型配置、消息、项目和指令，返回 `handle`；poll 返回 `{ chunks: string[], done: boolean, error?: string }`。Provider 自己实现认证、网络协议和事件转换，无需向原生宿主增加 apiFormat 分支。

工具的服务接收 `{ conversation, workspace, arguments }`，返回工具结果。工具参数使用 JSON Schema。Skill 是指令与资源，不会自行授予系统权限；用户为会话选择 Skill 后，AI 插件才将其指令加入本轮上下文。

## 编辑器服务

声明 `diffuse:editor/host` 后，可读取目标项目的工具定义，并使用作业协议调用编辑器已有的项目工具及场景能力入口。项目由窗口目录解析，插件请求不能静默切换为另一个项目的文件根目录。

文件写入仍经过编辑器的路径、未保存缓冲区和版本校验；场景事务继续经过原有能力与确认管线。模型通信和执行循环由 AI 插件负责，原生编辑服务可以由其他插件使用。

## 文本补全

`diffuse.ai.completion/v1` 是通用文本补全服务，由 AI 插件实现。请求 `start` 时传入 `instructions`、`prompt` 和可选的 `maxTokens`，获得 `handle`；`poll` 返回 `done`、`text` 和可选 `error`，`cancel` 取消该句柄。编辑器的提交信息生成通过此服务请求模型。插件停用时取消所有未完成补全。
