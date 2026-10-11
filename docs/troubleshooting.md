---
path: /zh/docs/troubleshooting
title: 故障排查
description: 原生依赖、NativeRHI 后端、项目目录与 MCP 连接的常见问题。
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

## NativeRHI 后端

编辑器支持通过 `--rhi-backends` 指定候选后端，例如 macOS 的 `metal` 或 Windows 的 `dx12`：

```bash
swift run --package-path Editor EditorApp --rhi-backends metal
```

也可使用 `GUAVA_RHI_BACKENDS` 环境变量或 `--rhi-config` JSON 配置文件。

```json
{"rhi":{"preferredBackends":["metal"],"validationEnabled":true,"framesInFlight":3}}
```

macOS 默认使用 Metal，Windows 优先使用 DX12，Linux 默认使用 Vulkan。Windows 在 DX12 设备创建失败时尝试 Vulkan。DX12 需先使用具备 DXC 的 Windows 工具链生成 DXIL 着色器产物；Vulkan 需要原生 loader 和驱动。

## 着色器工具链

macOS arm64 可运行 `python3 scripts/bootstrap-rhi-slang.py` 安装固定版本编译器；其他平台通过 `SLANGC` 指定 Slang 2026.19。

运行 `python3 scripts/compile-native-renderer-shaders.py --check` 检查打包产物是否与源码一致；去掉 `--check` 可重新生成。编译失败会保留现有产物。


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
