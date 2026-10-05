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

## Projects and the playable example

New Project takes a name and an existing parent folder, then creates a separate child directory with `.guava/project.json`, a saved empty scene, `Assets/`, and `Scripts/`. It never overwrites an existing directory or adds preview entities or default scripts. Empty scenes use a separate editor navigation camera without adding authored entities. Open Project validates the selected root before starting its editor services; legacy `.guava` projects remain supported.

Recent entries show their full paths. Remove Entry keeps the files. Delete asks for confirmation and moves a managed project to Trash; legacy folders can only be removed from Recents. Platforms without native Foundation trash support retain deleted projects in `Application Support/Guava/DeletedProjects`. File → Close Project / Welcome protects unsaved scene and script buffers before returning to the launcher. New Scene starts empty.

Crystal Rush → Create Example Project creates an independent editable copy. The launcher grants execution only to the newly copied bundled script and compiles it. When compilation finishes, click Play, focus the viewport, and press Space. WASD moves, Shift sprints, and R restarts. Collect eight crystals within 50 seconds while avoiding sentinels. The authored scene contains Game Controller; `Scripts/CrystalRush.swift` creates the world and HUD on Play. Stop restores the authored scene, and Build and Run exports the standalone game.

## Core panels

- **Hierarchy** browses entities and changes selection.
- **Inspector** edits transforms and supported scene components.
- **Viewport** renders the scene and handles camera and gizmo input.
- **Asset Browser** browses and imports project resources.
- **Console** reports editor and runtime messages.
- **Render Pipeline / Developer Tools** expose offline renders, frame analysis, performance monitors, render/particle diagnostics, and runtime state.

## Panel interaction conventions

Core panels share the same toolbar, search, count badge, and empty-state language. Search fields are clearable and show “visible / total” feedback while filtering.

- **Hierarchy** supports multi-selection, drag reordering, expand/collapse all, creation at the root or under the primary entity, and wrapping previous/next search navigation. The `Actions` menu exposes rename, duplicate, frame, select descendants, visibility, lock, move-to-root, and delete commands. Keyboard equivalents are `F2`, `Cmd/Ctrl+D`, `F`, `V`, `L`, and `Delete`; `Cmd/Ctrl+A` selects the current filtered results. Batch delete, duplicate, and move operations are single undoable transactions, and locked entities or playback never produce partial edits.
- **Inspector** searches component names, property names, and current values. Queries survive selection changes; results expand automatically, and clearing a query restores the user's saved collapse state. The component picker is searchable and grouped into rendering, physics, animation, audio, and scripting. Add, reset, and remove operations apply safely to the complete multi-selection as one atomic, undoable transaction. Multi-selection, locked entities, and playback expose an explicit read-only reason and never produce partial edits.
- **Viewport** supports click selection, drag-box selection, and modifier-based multi-selection. `Q/B/W/E/R` switch between select, box select, move, rotate, and scale; `F` frames the complete selection, including rendered descendants. Click the view cube to snap to an axis. Use `Alt+left-drag` to orbit, middle-drag to pan, the wheel to zoom, right-drag for free-look (hold `W/A/S/D/Q/E` to move and `Shift` to accelerate), and `Alt+right-drag` to dolly. The toolbar groups local/world space, lit/wireframe shading, shadows, render scale, realtime preview, physics debugging, and play/pause/stop. Multi-selection transforms are atomic: a selection containing a locked entity hides the gizmo and cannot be partially modified; editing is disabled during playback. `Escape` cancels the active drag and rolls back an uncommitted transform.
- **Asset Browser** offers grid/list views, mesh/texture filters, and name-ascending, name-descending, or type sorting. Search spans folders and matches names or relative paths; counts reflect the active folder or filter scope. Use `Shift` for range selection, `Cmd/Ctrl` to toggle items, arrow keys to navigate, `Cmd/Ctrl+A` to select visible results, `Return` to add a mesh, and `Escape` to clear selection. Multiple selected meshes can be added in one arranged, undoable operation. Imports go to the current folder, and view, category filter, and sort preferences persist across launches.
- **Console** combines full-text search with Info, Warning, and Error severity filters. Click a message to expand its complete diagnostic detail; copy the selected message or all visible results; pause or resume following the newest output. Clearing history and hiding filtered results are separate operations.
- **Render Pipeline** offers Preview, 720p, and 1080p presets and reports path-sample and image-buffer estimates. Resolution/SPP combinations are capped at a 64-million path-sample budget to avoid accidental unbounded offline renders. Renders can be cancelled, and completed EXR output can be revealed under the project's `.guava/renders` folder.
- **Developer Tools** brings Profiler, Monitors, Render, Particles, Debugger, and Trace into one workbench. Debugger summarizes editor, frame/render, viewport, and selection state; its console supports search, severity filters, newest-first ordering, and expandable details. Trace aligns frame-budget, CPU/GPU-present, render-pass, particle, and console signals across frames. Pause or capture a window, filter and sort by track/severity/text, inspect event evidence and recommendations alongside neighboring-frame context, then jump to the owning diagnostic tab.
- **Settings** switches the model default with the AI provider and clears any unsubmitted API-key draft when providers change, preventing credentials from being saved to the wrong service. Removing a system-stored credential requires a second confirmation, and validation failures are visibly marked as errors.

## Orthographic views and snapping

The viewport's **Perspective / Orthographic** menu switches projection and offers Front, Back, Left, Right, Top, and Bottom orthographic views. Clicking an axis endpoint on the view cube also enters the corresponding orthographic view. Switching projection preserves the apparent scale at the focus plane. In orthographic mode, wheel zoom and dolly adjust the visible extent, middle-drag pans by screen distance, and `F` fits the complete selection.

The reference grid uses the XZ ground plane in perspective. Orthographic views use a dark background and the facing XY, YZ, or XZ plane, with red X, green Y, and blue Z axes.

The **Snapping** menu offers independent switches and steps for movement, rotation, and scaling. Default steps are `0.5` world units, `5°`, and `0.05`; all three switches start off. Press Return or leave a number field to commit a new value. When movement snapping is enabled, grid spacing follows its step, showing integer multiples when zoomed out to remain readable. Snap settings are saved per project and restored on reopening.

## Playback

Entering play mode snapshots the scene. Pause freezes simulation without discarding state, while stop restores the pre-play scene. The MCP `set_playback_state` tool uses the same `playing`, `paused`, and `stopped` states.

Edit mode uses an independent editor camera. Orbit, pan, zoom, free-look, and selection framing preserve authored game cameras and do not create document changes or undo entries. Play and Pause use the scene's active game camera; Stop restores the previous editor view and the document's pre-play save state.

Gameplay scripts run only during Play. Edit-mode refreshes and realtime preview do not execute gameplay logic. Pause preserves script instances and suspends callbacks; resuming continues those instances. Stop and project shutdown invoke `onDestroy` with the live scene still available, then release instances. The next Play invokes `onStart` again. Realtime animation preview remains available in Edit mode.

## Native window regression

On macOS development builds, run `python3 scripts/validate-editor-native-loop.py`. It starts real isolated Editor windows and exercises MCP connections, compilation, source replacement and recompilation, Play/Pause/Stop, and standalone export. The exported game is validated without a Swift toolchain. Both event-driven and continuous frame loops are covered by default.

Projects, script trust, logs, and MCP transcripts stay in a new temporary directory, and each test app uses its own preferences domain. `GUAVA_EDITOR_STATE_DIRECTORY` isolates layouts and script trust. Project files and MCP tools cannot grant themselves script execution permission.
