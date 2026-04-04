///! Rendering infrastructure RPC methods: renderqueue, debug, audio, physicsviz.

// ── renderqueue namespace ────────────────────────────────────────

pub const @"renderqueue.listJobs" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        jobs: []const RenderJobInfo,
        isRunning: bool,
    };

    pub const RenderJobInfo = struct {
        index: u64,
        sequencePath: []const u8,
        outputDir: []const u8,
        width: u32,
        height: u32,
        format: []const u8,
        samples: u32,
        bounces: u32,
        usePathTrace: bool,
        encodeVideo: bool,
        videoCodec: []const u8,
        status: []const u8,
        totalFrames: u32,
        currentFrame: u32,
        statusMessage: []const u8,
    };
};

pub const @"renderqueue.addJob" = struct {
    pub const Params = struct {
        sequencePath: []const u8,
        outputDir: ?[]const u8 = null,
        width: ?u64 = null,
        height: ?u64 = null,
        format: ?[]const u8 = null,
        samples: ?u64 = null,
        bounces: ?u64 = null,
        usePathTrace: ?bool = null,
        encodeVideo: ?bool = null,
        videoCodec: ?[]const u8 = null,
    };
    pub const Result = struct { index: u64 };
};

pub const @"renderqueue.removeJob" = struct {
    pub const Params = struct { index: u64 };
    pub const Result = struct {};
};

pub const @"renderqueue.startQueue" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"renderqueue.cancelQueue" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"renderqueue.clearCompleted" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

// ── debug namespace ──────────────────────────────────────────────

pub const @"debug.getRhiStats" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        bindingCache: BindingCacheStats,
        passes: []const PassInfo,
    };

    pub const BindingCacheStats = struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        entries: u32,
        maxEntries: u32,
        hitRate: f64,
        frameHits: u64,
        frameMisses: u64,
        frameEvictions: u64,
    };

    pub const PassInfo = struct {
        name: []const u8,
        status: []const u8,
    };
};

pub const @"debug.resetRhiStats" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

// ── audio namespace ──────────────────────────────────────────────

pub const @"audio.getMixerStatus" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        available: bool,
        activeVoices: u32,
        buses: []const BusInfo,
    };

    pub const BusInfo = struct {
        id: []const u8,
        label: []const u8,
        volume: f32,
        playing: u32,
    };
};

pub const @"audio.setBusVolume" = struct {
    pub const Params = struct {
        busId: []const u8,
        volume: f32,
    };
    pub const Result = struct {};
};

// ── physicsviz namespace ─────────────────────────────────────────

pub const @"physicsviz.getSettings" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        drawMode: []const u8,
        opacity: f32,
        velocityScale: f32,
        wireframeOnly: bool,
        showCollisionShapes: bool,
        showRigidbodies: bool,
        showTriggers: bool,
        showConstraints: bool,
        showVelocityVectors: bool,
        showSleepState: bool,
        showAabbs: bool,
        colorStatic: [4]f32,
        colorDynamic: [4]f32,
        colorKinematic: [4]f32,
        colorTrigger: [4]f32,
        colorSleeping: [4]f32,
        colorConstraint: [4]f32,
    };
};

pub const @"physicsviz.setDrawMode" = struct {
    pub const Params = struct { mode: []const u8 };
    pub const Result = struct {};
};

pub const @"physicsviz.setToggle" = struct {
    pub const Params = struct { key: []const u8, value: bool };
    pub const Result = struct {};
};

pub const @"physicsviz.setFloat" = struct {
    pub const Params = struct { key: []const u8, value: f32 };
    pub const Result = struct {};
};

pub const @"physicsviz.setColor" = struct {
    pub const Params = struct { key: []const u8, r: f32, g: f32, b: f32, a: f32 };
    pub const Result = struct {};
};
