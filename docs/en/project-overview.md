---
path: /en/docs/overview
title: Project overview
description: Guava Engine's goals, technology stack, and four primary packages.
locale: en
translationKey: docs.overview
category: Start
order: 10
kind: doc
---

# Project overview

Guava's core thesis is that creative intent, world state, runtime execution, and AI understanding are four views of one world rather than four systems connected by translation layers.

## Technology

| Area | Current implementation |
| --- | --- |
| Primary language | Swift 6.1+ |
| Graphics | WebGPU through wgpu-native |
| Physics | Jolt Physics |
| Platform | SDL3 and native adapters |
| UI layout and text | Yoga, HarfBuzz, FreeType |
| Build | SwiftPM, CMake, Python bootstrap |

## Repository surfaces

- **Engine** owns scene, physics, rendering, assets, scripts, audio, AI, and film runtimes.
- **GuavaUI** owns declarative composition, layout, text, themes, input, and WebGPU UI rendering.
- **Editor** owns the desktop workspace, panels, selection, transforms, playback, and the AI host.
- **guava-mcp** exposes MCP tools over stdio and connects to the local editor on port `9898`.

The current release is best suited to prototypes, technical exploration, and contribution work rather than production projects that require a stable turnkey editor.
