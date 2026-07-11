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
