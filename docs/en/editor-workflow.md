---
path: /en/docs/editor-workflow
title: Editor workflow
description: Project entry, core panels, scene editing, and playback in Guava Editor.
locale: en
translationKey: docs.editor-workflow
category: Start
order: 30
kind: doc
---

# Editor workflow

Guava Editor is built with GuavaUI, while EditorCore manages selection, panels, scene adaptation, and edit history.

## Opening a project

Without `--project-dir`, the app shows a welcome surface and maintains recent projects. Passing a directory enters that project workspace directly.

## Core panels

- **Hierarchy** browses entities and changes selection.
- **Inspector** edits transforms and supported scene components.
- **Viewport** renders the scene and handles camera and gizmo input.
- **Asset Browser** browses and imports project resources.
- **Console** reports editor and runtime messages.
- **Render Pipeline / Profiler** expose offline render tasks and developer diagnostics.

## Playback

Entering play mode snapshots the scene. Pause freezes simulation without discarding state, while stop restores the pre-play scene. The MCP `set_playback_state` tool uses the same `playing`, `paused`, and `stopped` states.
