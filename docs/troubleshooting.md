---
path: /zh/docs/troubleshooting
title: 故障排查
description: 原生依赖、WebGPU 后端、项目目录与 MCP 连接的常见问题。
locale: zh
translationKey: docs.troubleshooting
category: 社区
order: 90
kind: doc
---

# 故障排查

## 原生依赖缺失

如果 SwiftPM 提示 `vendor` 中的 artifact bundle 不存在，先初始化子模块，再强制运行 bootstrap：

```bash
git submodule update --init --recursive
python bootstrap.py --force
```

## WebGPU 后端

编辑器支持通过 `--wgpu-backends` 指定候选后端，例如 macOS 的 `metal` 或 Windows 的 `d3d12`：

```bash
swift run --package-path Editor EditorApp --wgpu-backends metal
```

也可使用 `GUAVA_WGPU_BACKENDS` 环境变量或 `--wgpu-config` JSON 配置文件。

## MCP 无法连接

出现 `could not connect to localhost:9898` 时，确认 Guava Editor 正在运行，并且本机安全软件没有阻止回环连接。MCP 服务本身不会启动编辑器。

## AI 凭据不可用

macOS 可在 Editor 的 Settings → AI Assistant 中把密钥保存到系统钥匙串。Linux、Windows 和自动化环境可在启动 Editor 前设置标准环境变量：

```bash
export ANTHROPIC_API_KEY="..."
export OPENAI_API_KEY="..."
export DEEPSEEK_API_KEY="..."
```

对应的 `GUAVA_ANTHROPIC_API_KEY`、`GUAVA_OPENAI_API_KEY`、`GUAVA_DEEPSEEK_API_KEY` 优先级更高，适合与其他工具使用的全局密钥隔离。密钥不会写入项目或 Editor 设置 JSON。

## 验证 Release 安装

发布包中的 Editor 和 Player 支持无窗口自检。它会检查配套可执行文件和资源包，也能尽早暴露缺失的动态库：

```bash
./EditorApp --validate-install
./GuavaPlayer --validate-install
```

macOS 发布包中的命令位于 `GuavaEditor.app/Contents/MacOS/`。

## 完全重新构建

优先删除对应包的 `.build` 缓存，而不是改动 `vendor` 内产物；随后重新执行 bootstrap 和目标包构建。
