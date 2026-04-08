///! AI tool metadata — declares which RPC methods are exposed as LLM tools.
///!
///! This is the **single source of truth** for tool names, descriptions,
///! categories, and confirmation flags.  gen_types.zig reads this at comptime
///! to emit `ai-tools.generated.ts`; the MCP server will also read this in
///! a future refactor.
///!
///! To expose a new RPC method as an AI tool, add an entry to `tools`.
///! The `rpc_method` string MUST match a declaration in one of the
///! schema method_modules (core.zig, content.zig, etc.).
pub const Category = enum {
    scene,
    entity,
    playback,
    script,
    asset,
    animation,
    material,
    camera,
    render,
    prefab,
    audio,
    query,
};

pub const ToolMeta = struct {
    /// The RPC method name (must match a schema declaration exactly).
    rpc_method: []const u8,
    /// Human-readable description shown to the LLM.
    description: []const u8,
    /// UI category for grouping.
    category: Category,
    /// If true, the AiChat UI asks for user confirmation before executing.
    requires_confirmation: bool = false,
};

/// All AI-exposed tools.  Order determines display order in the system prompt.
pub const tools: []const ToolMeta = &.{
    // ───── Scene ──────────────────────────
    .{
        .rpc_method = "scene.getHierarchy",
        .description = "Get the full entity hierarchy of the current scene as a tree.",
        .category = .scene,
    },
    .{
        .rpc_method = "scene.createEntity",
        .description = "Create a new entity in the scene. Optionally specify a name and parent.",
        .category = .scene,
    },
    .{
        .rpc_method = "scene.deleteEntity",
        .description = "Delete an entity from the scene.",
        .category = .scene,
        .requires_confirmation = true,
    },
    .{
        .rpc_method = "scene.duplicateEntity",
        .description = "Duplicate an entity (with all components and children).",
        .category = .scene,
    },
    .{
        .rpc_method = "scene.save",
        .description = "Save the current scene to disk.",
        .category = .scene,
    },
    .{
        .rpc_method = "scene.load",
        .description = "Load a scene file.",
        .category = .scene,
        .requires_confirmation = true,
    },
    .{
        .rpc_method = "scene.listScenes",
        .description = "List all available scene files in the project.",
        .category = .scene,
    },

    // ───── Entity ─────────────────────────
    .{
        .rpc_method = "entity.getTransform",
        .description = "Get an entity's position, rotation and scale.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.setTransform",
        .description = "Set an entity's position, rotation and/or scale. Only specified fields are changed.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.setName",
        .description = "Rename an entity.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.getComponents",
        .description = "Get all components attached to an entity, with their field values.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.setComponentField",
        .description = "Set a field value on a component of an entity.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.addComponent",
        .description = "Add a component to an entity (e.g. Rigidbody, Light, Script, BoxCollider).",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.removeComponent",
        .description = "Remove a component from an entity.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.setVisible",
        .description = "Show or hide an entity.",
        .category = .entity,
    },
    .{
        .rpc_method = "entity.setAssetField",
        .description = "Assign an asset (model, texture, script) to a component field on an entity.",
        .category = .entity,
    },

    // ───── Playback ───────────────────────
    .{
        .rpc_method = "playback.play",
        .description = "Start playing the scene (enter Play mode).",
        .category = .playback,
    },
    .{
        .rpc_method = "playback.pause",
        .description = "Pause playback.",
        .category = .playback,
    },
    .{
        .rpc_method = "playback.stop",
        .description = "Stop playback and return to edit mode.",
        .category = .playback,
    },

    // ───── Script ─────────────────────────
    .{
        .rpc_method = "script.listScripts",
        .description = "List all script files in the project.",
        .category = .script,
    },
    .{
        .rpc_method = "script.getContent",
        .description = "Read the source code of a script file.",
        .category = .script,
    },
    .{
        .rpc_method = "script.saveContent",
        .description = "Write source code to a script file. Creates the file if it doesn't exist.",
        .category = .script,
    },

    // ───── Asset ──────────────────────────
    .{
        .rpc_method = "assets.list",
        .description = "List files and folders in a project directory.",
        .category = .asset,
    },

    // ───── Animation ──────────────────────
    .{
        .rpc_method = "animation.getState",
        .description = "Get the animation graph state of an entity.",
        .category = .animation,
    },
    .{
        .rpc_method = "animation.addState",
        .description = "Add a new animation state to an entity's animation graph.",
        .category = .animation,
    },
    .{
        .rpc_method = "animation.addTransition",
        .description = "Add a transition between two animation states.",
        .category = .animation,
    },

    // ───── Material ───────────────────────
    .{
        .rpc_method = "material.getState",
        .description = "Get the material properties of an entity.",
        .category = .material,
    },
    .{
        .rpc_method = "material.setColor",
        .description = "Set a color property on an entity's material (e.g. baseColor, emissive).",
        .category = .material,
    },
    .{
        .rpc_method = "material.setScalar",
        .description = "Set a scalar material property (metallic, roughness, etc.).",
        .category = .material,
    },

    // ───── Camera ─────────────────────────
    .{
        .rpc_method = "camera.getState",
        .description = "Get the current editor camera position and rotation.",
        .category = .camera,
    },
    .{
        .rpc_method = "camera.lookAlongAxis",
        .description = "Point the editor camera along an axis (top-down, front, side view).",
        .category = .camera,
    },

    // ───── Prefab ─────────────────────────
    .{
        .rpc_method = "prefab.list",
        .description = "List all prefabs in the project.",
        .category = .prefab,
    },
    .{
        .rpc_method = "prefab.instantiate",
        .description = "Instantiate a prefab at a position in the scene.",
        .category = .prefab,
    },

    // ───── Audio ──────────────────────────
    .{
        .rpc_method = "audio.getMixerStatus",
        .description = "Get the audio mixer status (buses, volumes, active voices).",
        .category = .audio,
    },

    // ───── Editor ─────────────────────────
    .{
        .rpc_method = "editor.undo",
        .description = "Undo the last action.",
        .category = .scene,
    },
    .{
        .rpc_method = "editor.redo",
        .description = "Redo the last undone action.",
        .category = .scene,
    },
    .{
        .rpc_method = "editor.getHistory",
        .description = "Get the undo/redo history list.",
        .category = .scene,
    },
};
