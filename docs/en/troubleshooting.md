---
path: /en/docs/troubleshooting
title: Troubleshooting
description: Native dependencies, WebGPU backends, project directories, and MCP connectivity.
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

## WebGPU backend selection

Use `--wgpu-backends` to select candidates such as `metal` or `d3d12`:

```bash
swift run --package-path Editor EditorApp --wgpu-backends metal
```

`GUAVA_WGPU_BACKENDS` and a JSON file passed with `--wgpu-config` are also supported.

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
