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
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"editor.redo" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"editor.getHistory" = struct {
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
    pub const Params = struct {};
    pub const Result = struct { roots: []const types.EntityNode };
};

pub const @"scene.createEntity" = struct {
    pub const Params = struct {
        name: ?[]const u8 = null,
        parentId: ?u64 = null,
    };
    pub const Result = struct { entityId: u64 };
};

pub const @"scene.deleteEntity" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {};
};

pub const @"scene.duplicateEntity" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct { entityId: u64 };
};

pub const @"scene.save" = struct {
    pub const Params = struct { path: ?[]const u8 = null };
    pub const Result = struct { path: []const u8 };
};

pub const @"scene.load" = struct {
    pub const Params = struct { path: []const u8 };
    pub const Result = struct { path: []const u8 };
};

pub const @"scene.listScenes" = struct {
    pub const Params = struct {};
    pub const Result = struct { scenes: []const []const u8 };
};

pub const @"scene.spawnActor" = struct {
    pub const Params = struct { kind: []const u8 };
    pub const Result = struct { entityId: u64 };
};

// ── entity namespace ─────────────────────────────────────────────

pub const @"entity.getTransform" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = types.Transform;
};

pub const @"entity.setTransform" = struct {
    pub const Params = struct {
        entityId: u64,
        transform: types.TransformPartial,
    };
    pub const Result = struct {};
};

pub const @"entity.setName" = struct {
    pub const Params = struct {
        entityId: u64,
        name: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.getComponents" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct { components: []const types.ComponentInfo };
};

pub const @"entity.setComponentField" = struct {
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
        fieldName: []const u8,
        value: types.JsonValue,
    };
    pub const Result = struct {};
};

pub const @"entity.addComponent" = struct {
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.removeComponent" = struct {
    pub const Params = struct {
        entityId: u64,
        componentType: []const u8,
    };
    pub const Result = struct {};
};

pub const @"entity.setAssetField" = struct {
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
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"playback.pause" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"playback.stop" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

// ── console namespace ────────────────────────────────────────────

pub const @"console.clear" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};
