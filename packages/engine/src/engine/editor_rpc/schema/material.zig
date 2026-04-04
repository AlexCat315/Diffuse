///! Material and render style RPC methods.
const types = @import("types.zig");

// ── material namespace ───────────────────────────────────────────

pub const @"material.getState" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {
        hasMaterial: bool,
        name: ?[]const u8 = null,
        shading: ?[]const u8 = null,
        baseColor: ?[4]f32 = null,
        emissive: ?[3]f32 = null,
        metallic: ?f32 = null,
        roughness: ?f32 = null,
        alphaCutoff: ?f32 = null,
        doubleSided: ?bool = null,
        useIBL: ?bool = null,
        iblIntensity: ?f32 = null,
        texBaseColor: ?u32 = null,
        texMetallicRoughness: ?u32 = null,
        texNormal: ?u32 = null,
        texOcclusion: ?u32 = null,
        texEmissive: ?u32 = null,
        isShared: ?bool = null,
        materialHandle: ?u32 = null,
        parentHandle: ?u32 = null,
        generation: ?u32 = null,
        previewPrimitive: ?[]const u8 = null,
    };
};

pub const @"material.setShading" = struct {
    pub const Params = struct { entityId: u64, mode: []const u8 };
    pub const Result = struct {};
};

pub const @"material.setColor" = struct {
    pub const Params = struct { entityId: u64, property: []const u8, value: [4]f32 };
    pub const Result = struct {};
};

pub const @"material.setScalar" = struct {
    pub const Params = struct { entityId: u64, property: []const u8, value: f32 };
    pub const Result = struct {};
};

pub const @"material.setFlag" = struct {
    pub const Params = struct { entityId: u64, property: []const u8, value: bool };
    pub const Result = struct {};
};

pub const @"material.assignTexture" = struct {
    pub const Params = struct { entityId: u64, slot: []const u8, textureHandle: u32 };
    pub const Result = struct {};
};

pub const @"material.clearTexture" = struct {
    pub const Params = struct { entityId: u64, slot: []const u8 };
    pub const Result = struct {};
};

pub const @"material.makeUnique" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {
        newHandle: u32,
        wasShared: bool,
        generation: ?u32 = null,
    };
};

pub const @"material.getTextureInfo" = struct {
    pub const Params = struct { textureHandle: u32 };
    pub const Result = struct {
        found: bool,
        name: ?[]const u8 = null,
        width: ?u32 = null,
        height: ?u32 = null,
        format: ?[]const u8 = null,
    };
};

pub const @"material.listTextures" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        textures: []const TextureEntry,

        pub const TextureEntry = struct {
            handle: u32,
            name: []const u8,
            width: u32,
            height: u32,
        };
    };
};

pub const @"material.setPreviewPrimitive" = struct {
    pub const Params = struct { primitive: []const u8 };
    pub const Result = struct {};
};

// ── material graph editing ─────────────────────────────────────

pub const @"material.getGraph" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct {
        hasGraph: bool,
        nodes: ?[]const types.MaterialGraphNodeInfo = null,
        connections: ?[]const types.MaterialGraphConnectionInfo = null,
        outputs: ?[]const types.MaterialGraphOutputInfo = null,
    };
};

pub const @"material.addGraphNode" = struct {
    pub const Params = struct {
        entityId: u64,
        kind: []const u8,
        posX: f64 = 0,
        posY: f64 = 0,
    };
    pub const Result = struct { nodeId: u32 };
};

pub const @"material.removeGraphNode" = struct {
    pub const Params = struct { entityId: u64, nodeId: u32 };
    pub const Result = struct {};
};

pub const @"material.updateGraphNode" = struct {
    pub const Params = struct {
        entityId: u64,
        nodeId: u32,
        channel: ?[]const u8 = null,
        outputType: ?[]const u8 = null,
        valueKind: ?[]const u8 = null,
        scalar: ?f64 = null,
        vec2: ?[2]f64 = null,
        vec3: ?[3]f64 = null,
        vec4: ?[4]f64 = null,
        textureHandle: ?u32 = null,
    };
    pub const Result = struct {};
};

pub const @"material.addGraphConnection" = struct {
    pub const Params = struct {
        entityId: u64,
        fromNodeId: u32,
        fromSlot: u8 = 0,
        toNodeId: u32,
        toSlot: u8 = 0,
    };
    pub const Result = struct {};
};

pub const @"material.removeGraphConnection" = struct {
    pub const Params = struct {
        entityId: u64,
        fromNodeId: u32,
        fromSlot: u8 = 0,
        toNodeId: u32,
        toSlot: u8 = 0,
    };
    pub const Result = struct {};
};

pub const @"material.setGraphOutput" = struct {
    pub const Params = struct {
        entityId: u64,
        channel: []const u8,
        sourceNodeId: u32,
        sourceSlot: u8 = 0,
    };
    pub const Result = struct {};
};

pub const @"material.removeGraphOutput" = struct {
    pub const Params = struct { entityId: u64, channel: []const u8 };
    pub const Result = struct {};
};

pub const @"material.setNodePosition" = struct {
    pub const Params = struct {
        entityId: u64,
        nodeId: u32,
        posX: f64,
        posY: f64,
    };
    pub const Result = struct {};
};

// ── style namespace ──────────────────────────────────────────────

pub const @"style.getActiveStyle" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        name: []const u8,
        displayName: []const u8,
        meshProgram: []const u8,
        shadowProgram: ?[]const u8 = null,
        source: []const u8,
        path: ?[]const u8 = null,
        disabledPasses: []const []const u8,
        configSchema: []const StyleParamSchema,
        paramValues: []const StyleParamValue,
    };

    pub const StyleParamSchema = struct {
        name: []const u8,
        displayName: []const u8,
        paramType: []const u8,
        defaultValue: f32,
        minValue: f32,
        maxValue: f32,
    };

    pub const StyleParamValue = struct {
        name: []const u8,
        value: f32,
    };
};

pub const @"style.listStyles" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        styles: []const StyleListItem,
    };

    pub const StyleListItem = struct {
        name: []const u8,
        displayName: []const u8,
        source: []const u8,
        isActive: bool,
    };
};

pub const @"style.setActiveStyle" = struct {
    pub const Params = struct { name: []const u8 };
    pub const Result = struct {};
};

pub const @"style.setParam" = struct {
    pub const Params = struct {
        styleName: []const u8,
        paramName: []const u8,
        value: f32,
    };
    pub const Result = struct {};
};
