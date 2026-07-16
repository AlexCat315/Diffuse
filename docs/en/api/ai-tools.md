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

## Local plugin capability contracts

`capabilities.wit` is the only source of plugin input types in a `.guavaplugin` package. Each `record` ending in `-input` inside `interface capabilities` generates one AI capability. The host constructs its ID as `<plugin-id>.<record-name>` and obtains version, access, and source authority from `plugin.json` and host policy.

```wit
package example:scene-reader;

interface capabilities {
  enum detail-level { summary, full }

  /// Finds matching entities in the current scene.
  record inspect-scene-input {
    /// Optional query text.
    query: option<string>,
    detail: detail-level,
    tags: list<string>,
  }
}

world plugin {
  import guava:scene/query;
  export discover: func() -> string;
  export prepare: func(capability-id: string, input: string) -> string;
}
```

The host derives a strict JSON Schema from the record and rejects unknown fields. Supported types include nested records, enums, aliases, `option`, `list`, booleans, strings, characters, 8/16/32-bit integers, and floating-point values. Open dictionaries, resource handles, recursive types, and 64-bit JSON integers fail closed during package loading.

`discover()` may return implementation IDs only:

```json
{"capability_ids":["example.scene-reader.inspect-scene"]}
```

That set must exactly match WIT. A Component cannot supply its own schema, access level, version, or schema hash. PluginHost revalidates authorization, capability identity, and the derived input schema before calling `prepare()`.
