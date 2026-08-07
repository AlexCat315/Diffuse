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

## Panel interaction conventions

Core panels share the same toolbar, search, count badge, and empty-state language. Search fields are clearable and show “visible / total” feedback while filtering.

- **Hierarchy** supports multi-selection, drag reordering, expand/collapse all, creation at the root or under the primary entity, and wrapping previous/next search navigation. The `Actions` menu exposes rename, duplicate, frame, select descendants, visibility, lock, move-to-root, and delete commands. Keyboard equivalents are `F2`, `Cmd/Ctrl+D`, `F`, `V`, `L`, and `Delete`; `Cmd/Ctrl+A` selects the current filtered results. Batch delete, duplicate, and move operations are single undoable transactions, and locked entities or playback never produce partial edits.
- **Inspector** searches component names, property names, and current values. Queries survive selection changes; results expand automatically, and clearing a query restores the user's saved collapse state. The component picker is searchable and grouped into rendering, physics, animation, audio, and scripting. Add, reset, and remove operations apply safely to the complete multi-selection as one atomic, undoable transaction. Multi-selection, locked entities, and playback expose an explicit read-only reason and never produce partial edits.
- **Asset Browser** offers grid/list views, mesh/texture filters, and name-ascending, name-descending, or type sorting. View, filter, and sort preferences persist across launches.
- **Console** combines full-text search with Info, Warning, and Error severity filters. Clearing history and hiding filtered results are separate operations.

## Playback

Entering play mode snapshots the scene. Pause freezes simulation without discarding state, while stop restores the pre-play scene. The MCP `set_playback_state` tool uses the same `playing`, `paused`, and `stopped` states.
