# 架构概览

Diffuse 建立在 [Cove](../) 提供的 UI、NativeRHI、平台服务与 CLI 之上，自身聚焦场景、三维渲染、物理、脚本、AI 运行时与编辑器。

## 顶层结构

```
Diffuse/
├── Engine/Sources/     渲染 / 场景 / 物理 / 资产 / AI 运行时 / 观察总线 / 影视管线
├── Editor/Sources/     创作工作站（文档、媒体时间线、场景、Agent）
├── DiffuseMCP/Sources/    MCP 服务器（把 Diffuse 编辑器能力暴露给 LLM agent）
└── .github/workflows/  CI 矩阵与 release
```

## 引擎模块

| 类别 | 模块 |
|------|------|
| 核心 | EngineCore、EngineKernel、EngineMath、Bridge |
| 渲染 | RenderBackend、CinematicRenderer、ColorPipeline、EXRIO、NativeRendererValidation |
| 场景 | SceneRuntime、SequenceRuntime、AssetPipeline |
| 运行时 | AIRuntime、ScriptRuntime、AudioRuntime、PluginRuntime |
| AI | IntentRuntime、PerceptionRuntime、ContextMemory、CapabilityRuntime、SemanticPipeline |
| 其他 | ObservationBus、CardBattleRuntime、DiffusePluginHost、SIMDCompat、NativeRHIPassProbe |

## 编辑器模块

- **EditorApp**：应用入口与生命周期
- **EditorCore**：文档、项目与命令核心
- **EditorUI**：工作站界面与面板
- **GameRuntime**：游戏预览与运行
- **CovePlayer**：内容播放器
- **CoveProjectExport**：项目导出

## 观察总线

`ObservationBus` 是引擎与 Agent 之间的桥梁：引擎把场景变化、碰撞事件、渲染状态以结构化事件形式发布，Agent 订阅后即可"理解"当前工程状态并做出决策。

## 影视与色彩管线

- **CinematicRenderer** 面向影视级输出
- **ColorPipeline** 负责色彩空间转换与调色
- **EXRIO** 基于 OpenEXR / Imath 读写高动态范围图像

## 媒体管线

视频时间线支持裁剪、排序、帧预览、播放与 MP4 导出：

- FFmpeg 负责解码、重采样与导出
- SDL 负责设备输出
- 文本 / 代码与视频工作流共用同一个 Agent 工具入口

## 插件体系

编辑器只面向 macOS、Windows、Linux；移动端目录属于 SDK 或游戏运行、导出路径。

插件统一使用 TypeScript，由应用随附的 Bun 执行。`PluginRuntime` 负责静态契约、授权摘要、贡献注册、生命周期和进程通信，`DiffusePluginHost` 代理插件与编辑器服务。

AI 模式、模型通信、会话数据与执行循环位于 `Editor/Plugins/AI`。面板和顶层模式使用同一套公开界面协议；服务和扩展点允许插件继续接入其他插件。插件退出时撤销其贡献，编辑器回到可用模式。

开发入口见[插件开发](/docs/plugin-development)和[服务与 AI 扩展](/docs/plugin-services)。

## 与 Cove 的边界

Cove 拥有 UI、NativeRHI、平台服务与 CLI；Diffuse 拥有场景、三维渲染、物理、脚本及其 UI 适配器。两者通过版本化 SDK 解耦，各自独立演进。
