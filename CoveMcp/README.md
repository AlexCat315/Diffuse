# Cove MCP

本地 stdio MCP 服务，连接正在运行的 Diffuse。项目脚本工具与内置 AI 助手共用实现，详见 [工具文档](../docs/api/ai-tools.md)。

先构建并启动编辑器，再将 MCP 可执行文件配置到支持 stdio 的客户端：

```bash
swift build --package-path Editor
swift build --package-path CoveMcp
swift run --package-path Editor EditorApp --project-dir "$PWD/examples/CrystalRush"
swift build --package-path CoveMcp --show-bin-path
```

最后一个命令返回目录；使用其中的 `CoveMCP` 作为下面 `command` 的绝对路径：

```json
{
  "mcpServers": {
    "cove": {
      "command": "/absolute/build/directory/CoveMCP",
      "env": { "COVE_MCP_PORT": "9898" }
    }
  }
}
```

Editor 默认监听 `127.0.0.1:9898`，支持多个连接和异步脚本编译。需要更换端口时，为 Editor 和 MCP 同时设置 `COVE_MCP_PORT`。TCP 桥接已迁到 CoveUI 的 `AgentLocalServer`，使用 SwiftNIO；MCP 协议分发复用 `MCPServer`。实现支持 macOS/Linux/Windows，本次构建与连通验证平台是 macOS。

AI 与 MCP 共用诊断工具：`get_diagnostics`、`query_ui_nodes`、`query_ui_recomposition`、`query_ui_state`、`capture_ui_trace`、`get_ui_trace`、`compare_ui_traces`。`list_skills` / `read_skill` 提供任务指引，MCP 也通过 `prompts/list` / `prompts/get` 暴露同一份 skill。图形 Editor 自动接入 UI 查询；headless Editor 可读领域诊断和 skills，UI 查询明确返回 unavailable。详见 [通用 AI 底层](../docs/architecture/agent-framework.md)。

协议协商支持 `2024-11-05`、`2025-03-26`、`2025-06-18`、`2025-11-25`；不是对后续 MCP 版本全部特性的声明。能力搜索后会更新工具列表，客户端应处理 `notifications/tools/list_changed`。

推荐操作顺序：查询项目与脚本 API → 读取源文件哈希 → 写脚本 → 编译并检查诊断 → 搜索场景能力 → 创建和提交草稿 → 用户在编辑器确认 → 保存 → 播放并查询运行状态 → 停止 → 导出。已有源文件必须提交最新 `expected_sha256`，未保存的编辑器文档不会被覆盖。模型与 MCP 不能自行信任项目；用户需在 Scripts 面板授权编译执行。

验证入口：

```bash
swift run --package-path Tools/Developer cove-dev validate mcp-protocol
swift run --package-path Tools/Developer cove-dev validate crystal-rush
```

`EditorApp --mcp-headless --project-dir <project>` 为本地自动化提供无 GPU 的宿主。只有显式传入 `--trust-project-scripts` 才信任项目；`--approve-scene-edits` 自动确认可撤销的场景预览，不确认破坏性修改。这些参数由启动编辑器的人选择，不是 MCP 工具。
