# Guava MCP

本地 stdio MCP 服务，连接正在运行的 Guava Editor。项目脚本工具与内置 AI 助手共用实现，详见 [工具文档](../docs/api/ai-tools.md)。

先构建并启动编辑器，再将 MCP 可执行文件配置到支持 stdio 的客户端：

```bash
swift build --package-path Editor
swift build --package-path guava-mcp
swift run --package-path Editor EditorApp --project-dir "$PWD/examples/CrystalRush"
swift build --package-path guava-mcp --show-bin-path
```

最后一个命令返回目录；使用其中的 `GuavaMCP` 作为下面 `command` 的绝对路径：

```json
{
  "mcpServers": {
    "guava": {
      "command": "/absolute/build/directory/GuavaMCP",
      "env": { "GUAVA_MCP_PORT": "9898" }
    }
  }
}
```

Editor 默认监听 `127.0.0.1:9898`，支持多个连接和异步脚本编译。需要更换端口时，为 Editor 和 MCP 同时设置 `GUAVA_MCP_PORT`。当前 TCP 桥接使用 Apple Network.framework；本次连通与游戏验证平台是 macOS，Windows/Linux 的桥接尚未实现。

协议协商支持 `2024-11-05`、`2025-03-26`、`2025-06-18`、`2025-11-25`；不是对后续 MCP 版本全部特性的声明。能力搜索后会更新工具列表，客户端应处理 `notifications/tools/list_changed`。

推荐操作顺序：查询项目与脚本 API → 读取源文件哈希 → 写脚本 → 编译并检查诊断 → 搜索场景能力 → 创建和提交草稿 → 用户在编辑器确认 → 保存 → 播放并查询运行状态 → 停止 → 导出。已有源文件必须提交最新 `expected_sha256`，未保存的编辑器文档不会被覆盖。模型与 MCP 不能自行信任项目；用户需在 Scripts 面板授权编译执行。

验证入口：

```bash
python3 scripts/check-guava-mcp-protocol.py
python3 scripts/validate-crystal-rush-mcp.py
```

`EditorApp --mcp-headless --project-dir <project>` 为本地自动化提供无 GPU 的宿主。只有显式传入 `--trust-project-scripts` 才信任项目；`--approve-scene-edits` 自动确认可撤销的场景预览，不确认破坏性修改。这些参数由启动编辑器的人选择，不是 MCP 工具。
