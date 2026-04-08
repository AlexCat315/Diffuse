///! Core editor RPC methods: editor, scene, entity, playback, console.
const types = @import("types.zig");

// ── editor namespace ─────────────────────────────────────────────

pub const @"editor.ping" = struct {
    pub const Params = struct {};
    pub const Result = struct { pong: bool };
};

pub const @"editor.getCapabilities" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        version: []const u8,
        methods: []const []const u8,
        subscriptions: []const []const u8,
    };
};

pub const @"editor.setSelection" = struct {
    pub const Params = struct { entityIds: []const u64 };
    pub const Result = struct {};
};

pub const @"editor.undo" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Undo the last action.", .category = .scene };
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"editor.redo" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Redo the last undone action.", .category = .scene };
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"editor.getHistory" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Get the undo/redo history list.", .category = .scene };
    pub const Params = struct {};
    pub const Result = struct {
        cursor: u64,
        entries: []const HistoryEntry,
    };

    pub const HistoryEntry = struct {
        sequence: u64,
        label: []const u8,
        source: []const u8,
        detail: ?[]const u8 = null,
        timestampMs: i64,
    };
};

pub const @"editor.timeTravel" = struct {
    pub const Params = struct { targetSequence: u64 };
    pub const Result = struct {};
};

// ── scene namespace ──────────────────────────────────────────────

pub const @"scene.getHierarchy" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Get the full entity hierarchy of the current scene as a tree.", .category = .scene };
    pub const Params = struct {};
    pub const Result = struct { roots: []const types.EntityNode };
};

pub const @"scene.createEntity" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Create a new entity in the scene. Optionally specify a name and parent.", .category = .scene };
    pub const Params = struct {
        name: ?[]const u8 = null,
        parentId: ?u64 = null,
    };
    pub const Result = struct { entityId: u64 };
};

pub const @"scene.deleteEntity" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Delete an entity from the scene.", .category = .scene, .requires_confirmation = true };
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {};
};

pub const @"scene.duplicateEntity" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Duplicate an entity (with all components and children).", .category = .scene };
    pub const Params = struct { entityId: u64 };
    pub const Result = struct { entityId: u64 };
};

pub const @"scene.save" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Save the current scene to disk.", .category = .scene };
    pub const Params = struct { path: ?[]const u8 = null };
    pub const Result = struct { path: []const u8 };
};

pub const @"scene.load" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Load a scene file.", .category = .scene, .requires_confirmation = true };
    pub const Params = struct { path: []const u8 };
    pub const Result = struct { path: []const u8 };
};

pub const @"scene.listScenes" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "List all available scene files in the project.", .category = .scene };
    pub const Params = struct {};
    pub const Result = struct { scenes: []const []const u8 };
};

pub const @"scene.spawnActor" = struct {
    pub const Params = struct { kind: []const u8 };
    pub const Result = struct { entityId: u64 };
};

// ── entity namespace ─────────────────────────────────────────────

pub const @"entity.getTransform" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Get an entity's position, rotation and scale.", .category = .entity };
    pub const Params = struct { entityId: u64 };
    pub const Result = types.Transform;
};

pub const @"entity.setTransform" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Set an entity's position, rotation and/or scale. Only specified fields are changed.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        transform: types.TransformPartial,
    };
    pub const Result = struct {};
};

pub const @"entity.setName" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Rename an entity.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        name: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.getComponents" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Get all components attached to an entity, with their field names and values. Use field names from the result when calling entity.setComponentField.", .category = .entity };
    pub const Params = struct { entityId: u64 };
    pub const Result = struct { components: []const types.ComponentInfo };
};

pub const @"entity.setComponentField" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Set a field value on a component. Use exact field names from entity.getComponents. Works for scalars, arrays, and enums. For Mesh.primitive valid values: \"cube\", \"sphere\", \"plane\". For material colors prefer material.setColor.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
        fieldName: []const u8,
        value: types.JsonValue,
    };
    pub const Result = struct {};
};

pub const @"entity.addComponent" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Add a component to an entity. Valid types: Camera, Mesh, SkinnedMesh, Animator, Rigidbody, BoxCollider, SphereCollider, MeshCollider, CapsuleCollider, CharacterController, Tag, Sky, Constraint, Material, Light, Vfx, Script, AudioSource, AudioListener, NavAgent. Components are added with default values. After adding Mesh, you MUST call entity.setComponentField to set primitive to \"cube\", \"sphere\", or \"plane\" — otherwise it defaults to \"custom\" (no geometry).", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.removeComponent" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Remove a component from an entity.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.setVisible" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Show or hide an entity.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        visible: bool,
    };
    pub const Result = struct {};
};

pub const @"entity.setSelectable" = struct {
    pub const Params = struct {
        entityId: u64,
        selectable: bool,
    };
    pub const Result = struct {};
};

pub const @"entity.setAssetField" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Assign an asset to a component field. Params: entityId, componentType, fieldName, assetPath (string|null to clear). For Sky.environment_asset_id pass the asset path. For Script, use optional scriptIndex.", .category = .entity };
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
        fieldName: []const u8,
        assetPath: ?[]const u8,
    };
    pub const Result = struct {};
};

// ── playback namespace ───────────────────────────────────────────

pub const @"playback.play" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Start playing the scene (enter Play mode).", .category = .playback };
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"playback.pause" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Pause playback.", .category = .playback };
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"playback.stop" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Stop playback and return to edit mode.", .category = .playback };
    pub const Params = struct {};
    pub const Result = struct {};
};

// ── console namespace ────────────────────────────────────────────

pub const @"console.clear" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};
