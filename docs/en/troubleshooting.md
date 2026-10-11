---
path: /en/docs/troubleshooting
title: Troubleshooting
description: Native dependencies, NativeRHI backends, project directories, and MCP connectivity.
locale: en
translationKey: docs.troubleshooting
category: Community
order: 90
kind: doc
---

# Troubleshooting

## Missing native artifacts

If SwiftPM cannot find an artifact bundle under `vendor`, initialize submodules and force bootstrap:

```bash
git submodule update --init --recursive
python bootstrap.py --force
```

## NativeRHI backend selection

Use `--rhi-backends` to select candidates such as `metal`, `dx12`, or `vulkan`:

```bash
swift run --package-path Editor EditorApp --rhi-backends metal
```

`GUAVA_RHI_BACKENDS` and a JSON file passed with `--rhi-config` are also supported.

```json
{"rhi":{"preferredBackends":["metal"],"validationEnabled":true,"framesInFlight":3}}
```

macOS defaults to Metal, Windows to DX12, and Linux to Vulkan. Windows tries Vulkan if DX12 device creation fails. DX12 requires offline DXIL artifacts generated with a Windows toolchain that provides DXC; Vulkan needs a native loader and driver.

## Shader toolchain

On macOS arm64, install the pinned compiler with `python3 scripts/bootstrap-rhi-slang.py`; on other hosts supply Slang 2026.19 via `SLANGC`.

Use `python3 scripts/compile-native-renderer-shaders.py --check` to check bundled artifacts against source. Omit `--check` to regenerate them. Compilation failures preserve existing artifacts.


## MCP connection errors

If the server reports that it cannot connect to `localhost:9898`, confirm that Guava Editor is running and local security software allows loopback connections. The MCP process does not launch the editor itself.

## AI credential is unavailable

On macOS, Settings → AI Assistant can store a key in the system Keychain. On Linux, Windows, and automated hosts, set a standard provider variable before starting the Editor:

```bash
export ANTHROPIC_API_KEY="..."
export OPENAI_API_KEY="..."
export DEEPSEEK_API_KEY="..."
```

`GUAVA_ANTHROPIC_API_KEY`, `GUAVA_OPENAI_API_KEY`, and `GUAVA_DEEPSEEK_API_KEY` take precedence and can isolate Guava from credentials used by other tools. Credentials are never written to projects or Editor settings JSON.

## Validate a release installation

Packaged Editor and Player binaries provide a headless validation mode. It checks companion executables and resource bundles and exposes missing dynamic libraries before the UI starts:

```bash
./EditorApp --validate-install
./GuavaPlayer --validate-install
```

Inside the macOS release, these commands live under `GuavaEditor.app/Contents/MacOS/`.
