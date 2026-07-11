---
path: /en/docs/mcp-tools
title: MCP and AI tools
description: How the Guava MCP server connects and which tools it currently exposes.
locale: en
translationKey: docs.mcp-tools
category: Reference
order: 70
kind: doc
---

# MCP and AI tools

`guava-mcp` is an MCP stdio server. It forwards tool requests to Guava Editor on `127.0.0.1:9898`, so the editor must be running before tools can act on a scene.

## Start the server

```bash
swift run --package-path guava-mcp GuavaMCP
```

## Current tools

| Tool | Purpose |
| --- | --- |
| `get_scene_entities` / `find_entities` | Inspect and find scene entities |
| `get_selection` / `select_entity` | Read or update editor selection |
| `get_ai_entity` | Read the AI-visible semantic record |
| `execute_edit_plan` | Apply a structured scene edit plan |
| `set_playback_state` | Play, pause, or stop simulation |
| `undo` / `redo` | Navigate edit history |
| `analyze_image` | Analyze a reference image |
| `get_context_memory` | Read context memory |

Entity references use the `scene:<number>` form. Read the current scene before constructing edits against real IDs.
