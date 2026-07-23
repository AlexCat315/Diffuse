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

## How AI capabilities are exposed

Editor AI uses a dynamic capability protocol for scene writes. The model initially receives only `search_capabilities`, `submit_plan`, and a small set of currently allowed read capabilities. After a search, the host injects at most 16 exact tools from the shared `CapabilityRegistry`. A generated name includes the capability version and a short schema-hash suffix, such as `cap_scene_set_transform_v1_a91c`; its mapping to the real capability ID exists only in the current `ExposureSnapshot`.

Every built-in scene write derives its input decoder, strict JSON Schema, Provider/MCP tool, access metadata, and stable schema hash from a typed `GuavaCapability` declaration. `SceneEditOp` remains only as a legacy wire and diagnostic representation and can no longer fall back to producing AI mutations. If a write contract exists in the Registry without a typed registration carrying the same hash, submission fails closed with `capabilityUnavailable`.

Calling a write tool creates a Draft bound to the Snapshot, scene revision, capability version, and schema hash; it does not modify the scene. `submit_plan` prepares Drafts in order against a Shadow Scene and requires every write capability to produce controlled operations, a non-empty preview, and deterministic verification assertions. The registration layer also derives exact field-level postconditions from host operations. When several steps write the same field, only the final expected value is checked, and a component-kind replacement supersedes details for the old kind. Any mismatch rolls back the whole transaction. Only the complete Diff accepted by the user reaches the transaction executor, and destructive writes require a second confirmation. Read capabilities execute immediately after strict input validation.

A Draft expires after five minutes or when the scene revision, plugin authorization, PluginHost generation, schema, or session changes. Authority and bindings are checked again at tool invocation, submission, prepare, immediately before confirmed execution, and during post-execution verification, so a model cannot bypass the Registry with a forged ID, tool name, or stale Snapshot.

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

The “AI Plugins” section in Editor Settings follows one fixed sequence: choose a `.guavaplugin` directory → `EditorApplication.inspectPlugin` validates without loading → the UI displays access, imports, composable host capabilities, Component/WIT hashes, and every schema hash → the user clicks “Authorize & Enable” → `makePluginAuthorization` → `enablePlugin`. The pending package path remains only in `EditorApplication` private memory, and plugin-management UI state is omitted from encoded `EditorState`. After a successful enable, project-level `plugin_authorizations.json` records only the exact authorization fingerprint. That file never auto-loads or enables a plugin, and any code, WIT, permission, or schema change prevents reuse. Enabling atomically rebuilds the Registry, exposure policy, and authority map shared by Editor AI and MCP; it destroys old sessions and Drafts and installs the plugin-aware pre-execution planner. When `Session` submits a plugin write, it places only authority-bound Drafts in the `Proposal`; Editor expands them only after it has the current `SceneRuntime`. Scene, selection, and asset queries come solely from revision-bound `PluginQuerySnapshot` values built by Editor. Runtime objects and absolute asset paths never enter the plugin process.

Disabling a plugin or restarting PluginHost immediately revokes dynamic exposure, cancels the active AI run, and clears MCP sessions. A confirmation already visible in the UI still fails the planner's generation and authorization check before application. The PluginHost path is no longer a plugin-management API parameter: Editor resolves only a regular executable in the installed `Contents/Helpers`, release archive `Tools`, the Editor executable directory, or the Debug build output, and rejects non-executables, directories, and symbolic links. Release jobs build and package that fixed host. Plugin packages, project settings, environment variables, and model input cannot select it.
