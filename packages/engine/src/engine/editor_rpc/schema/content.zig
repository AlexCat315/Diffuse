///! Content management RPC methods: assets, script, utilities, plugin, prefab, particle.
const types = @import("types.zig");

// ── assets namespace ─────────────────────────────────────────────

pub const @"assets.list" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "List files and folders in a project directory.", .category = .asset };
    pub const Params = struct { path: ?[]const u8 = null };
    pub const Result = struct {
        path: []const u8,
        entries: []const types.AssetEntry,
    };
};

// ── script namespace ─────────────────────────────────────────────

pub const @"script.listScripts" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "List all script files in the project.", .category = .script };
    pub const Params = struct {};
    pub const Result = struct {
        scripts: []const types.ScriptFileInfo,
    };
};

pub const @"script.getContent" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Read the source code of a script file.", .category = .script };
    pub const Params = struct {
        path: []const u8,
    };
    pub const Result = struct {
        content: []const u8,
        language: []const u8,
        readOnly: bool,
    };
};

pub const @"script.saveContent" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Write source code to a script file. Creates the file if it doesn't exist.", .category = .script };
    pub const Params = struct {
        path: []const u8,
        content: []const u8,
    };
    pub const Result = struct {
        success: bool,
    };
};

// ── utilities namespace ──────────────────────────────────────────

pub const @"utilities.list" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        utilities: []const UtilityInfo,

        pub const UtilityInfo = struct {
            handle: u64,
            name: []const u8,
            description: []const u8,
            sourcePath: []const u8,
            status: []const u8,
            open: bool,
            lastError: []const u8,
        };
    };
};

pub const @"utilities.setOpen" = struct {
    pub const Params = struct { handle: u64, open: bool };
    pub const Result = struct {};
};

pub const @"utilities.remove" = struct {
    pub const Params = struct { handle: u64 };
    pub const Result = struct {};
};

// ── plugin namespace ─────────────────────────────────────────────

pub const @"plugin.list" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        plugins: []const PluginInfo,
    };

    pub const PluginInfo = struct {
        name: []const u8,
        pluginType: []const u8,
        source: []const u8,
        lifecycle: []const u8,
        lastError: ?[]const u8 = null,
    };
};

pub const @"plugin.enable" = struct {
    pub const Params = struct { name: []const u8 };
    pub const Result = struct {};
};

pub const @"plugin.disable" = struct {
    pub const Params = struct { name: []const u8 };
    pub const Result = struct {};
};

pub const @"plugin.unload" = struct {
    pub const Params = struct { name: []const u8 };
    pub const Result = struct {};
};

pub const @"plugin.rescan" = struct {
    pub const Params = struct { path: ?[]const u8 = null };
    pub const Result = struct {};
};

// ── prefab namespace ─────────────────────────────────────────────

pub const @"prefab.list" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "List all prefabs in the project.", .category = .prefab };
    pub const Params = struct {};
    pub const Result = struct {
        prefabs: []const types.PrefabInfo,
    };
};

pub const @"prefab.getEntities" = struct {
    pub const Params = struct { prefabId: []const u8 };
    pub const Result = struct {
        found: bool,
        entities: []const types.PrefabEntityNode,
    };
};

pub const @"prefab.getEntityDetail" = struct {
    pub const Params = struct {
        prefabId: []const u8,
        prefabEntityId: u32,
    };
    pub const Result = struct {
        found: bool,
        entity: ?types.PrefabEntityDetail = null,
    };
};

pub const @"prefab.setEntityTransform" = struct {
    pub const Params = struct {
        prefabId: []const u8,
        prefabEntityId: u32,
        posX: ?f64 = null,
        posY: ?f64 = null,
        posZ: ?f64 = null,
        rotX: ?f64 = null,
        rotY: ?f64 = null,
        rotZ: ?f64 = null,
        rotW: ?f64 = null,
        scaleX: ?f64 = null,
        scaleY: ?f64 = null,
        scaleZ: ?f64 = null,
    };
    pub const Result = struct { success: bool };
};

pub const @"prefab.setEntityField" = struct {
    pub const Params = struct {
        prefabId: []const u8,
        prefabEntityId: u32,
        field: []const u8,
        value: []const u8,
    };
    pub const Result = struct { success: bool };
};

pub const @"prefab.create" = struct {
    pub const Params = struct {
        entityId: u64,
        name: []const u8,
    };
    pub const Result = struct {
        success: bool,
        prefabId: ?[]const u8 = null,
    };
};

pub const @"prefab.instantiate" = struct {
    pub const ai_tool: types.AiTool = .{ .description = "Instantiate a prefab at a position in the scene.", .category = .prefab };
    pub const Params = struct {
        prefabId: []const u8,
        posX: ?f64 = null,
        posY: ?f64 = null,
        posZ: ?f64 = null,
    };
    pub const Result = struct {
        success: bool,
        entityId: ?u64 = null,
    };
};

pub const @"prefab.save" = struct {
    pub const Params = struct { prefabId: []const u8 };
    pub const Result = struct { success: bool };
};

pub const @"prefab.delete" = struct {
    pub const Params = struct { prefabId: []const u8 };
    pub const Result = struct { success: bool };
};

// ── particle namespace ───────────────────────────────────────────

pub const @"particle.listVfxEntities" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        entities: []const types.VfxEntityInfo,
    };
};

pub const @"particle.getConfig" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {
        found: bool,
        config: ?types.VfxConfig = null,
    };
};

pub const @"particle.setConfig" = struct {
    pub const Params = struct {
        entityId: u64,
        kind: ?[]const u8 = null,
        looping: ?bool = null,
        emissionRate: ?f64 = null,
        particleLifetime: ?f64 = null,
        speed: ?f64 = null,
        maxParticles: ?u32 = null,
        radius: ?f64 = null,
        spread: ?f64 = null,
        size: ?f64 = null,
        colorR: ?f64 = null,
        colorG: ?f64 = null,
        colorB: ?f64 = null,
    };
    pub const Result = struct { success: bool };
};

pub const @"particle.applyPreset" = struct {
    pub const Params = struct {
        entityId: u64,
        preset: []const u8,
    };
    pub const Result = struct { success: bool };
};
