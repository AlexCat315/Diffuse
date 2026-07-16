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

  inspect-scene: func(input: inspect-scene-input) -> string;
}

world plugin {
  import guava:scene/query;
  export capabilities;
}
```

The host derives a strict JSON Schema from the record and rejects unknown fields. Every `<name>-input` must have a same-name `name: func(input: ...) -> string`; the standard Component exports the package-qualified `example:scene-reader/capabilities` interface. Missing functions, extra functions, or parameter-type drift reject the package. Supported types include nested records, enums, aliases, `option`, `list`, booleans, strings, characters, 8/16/32-bit integers, and floating-point values. Empty records, open dictionaries, resource handles, recursive types, and 64-bit JSON integers fail closed during package loading.

The capability set is derived entirely from validated WIT; PluginHost no longer calls a plugin-defined `discover()`. On invocation, it validates the strict schema, encodes JSON as the declared Component value, and calls the same-name typed function. A Component cannot supply its own schema, access level, version, capability ID, or schema hash. Write plugins must still return authorized `HostCapabilityCall` values and can never return raw mutations.

When the editor enables a plugin, it fingerprints the component hash, WIT hash, imports, composable host capabilities, and every schema hash. That authorization digest and the current PluginHost `generation` are bound into the `ExposureSnapshot`, write Draft, and `CapabilityInvocationRecord`. Upgrading, disabling, or reauthorizing a plugin—or restarting PluginHost—clears old sessions. The same binding is checked again immediately before an already-confirmed transaction is applied.

Plugin reads execute immediately through `PluginCapabilityExecutor.executeRead` and can return only bounded JSON model context. At `submit_plan`, plugin writes expand to authorized built-in primitives and prepare in Draft order against one Shadow Scene. The transaction records both the outer plugin call and every built-in call before entering the normal Diff, confirmation, verification, and rollback path. Empty write plans and read, unexposed, or open-schema primitives fail closed.

Editor integration follows one fixed sequence: `EditorApplication.inspectPlugin` → the UI displays the inspection and requested permissions → after explicit user approval, `makePluginAuthorization` → `enablePlugin`. After a successful enable, project-level `plugin_authorizations.json` records only the exact authorization fingerprint. That file never auto-loads or enables a plugin, and any code, WIT, permission, or schema change prevents reuse. Enabling atomically rebuilds the Registry, exposure policy, and authority map shared by Editor AI and MCP; it destroys old sessions and Drafts and installs the plugin-aware pre-execution planner. When `Session` submits a plugin write, it places only authority-bound Drafts in the `Proposal`; Editor expands them only after it has the current `SceneRuntime`. Scene, selection, and asset queries come solely from revision-bound `PluginQuerySnapshot` values built by Editor. Runtime objects and absolute asset paths never enter the plugin process.

Disabling a plugin or restarting PluginHost immediately revokes dynamic exposure, cancels the active AI run, and clears MCP sessions. A confirmation already visible in the UI still fails the planner's generation and authorization check before application. The trusted Editor host must supply the PluginHost executable path; it must never come from a plugin package or model input.
