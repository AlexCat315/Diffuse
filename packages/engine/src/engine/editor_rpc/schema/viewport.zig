///! Viewport, render settings, and camera RPC methods.
const types = @import("types.zig");

// ── viewport namespace ───────────────────────────────────────────

pub const @"viewport.setGizmoMode" = struct {
    pub const Params = struct { mode: []const u8 };
    pub const Result = struct {};
};

pub const @"viewport.setRect" = struct {
    pub const Params = struct {
        x: i64,
        y: i64,
        width: i64,
        height: i64,
    };
    pub const Result = struct {};
};

pub const @"viewport.getWindowInfo" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        drawableWidth: u32,
        drawableHeight: u32,
        nativeHandle: u64,
        platform: []const u8,
    };
};

pub const @"viewport.attachToParent" = struct {
    pub const Params = struct { parentHandle: u64 };
    pub const Result = struct {};
};

pub const @"viewport.detachFromParent" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"viewport.getSurfaceId" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        surfaceId: u32,
        width: u32,
        height: u32,
        shmName: ?[]const u8 = null,
    };
};

pub const @"viewport.getRenderSettings" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        shadingMode: []const u8,
        showGrid: bool,
        showBones: bool,
        showCollision: bool,
        bloomEnabled: bool,
        bloomThreshold: f32,
        bloomIntensity: f32,
        exposureEnabled: bool,
        exposure: f32,
        ssaoEnabled: bool,
        ssaoRadius: f32,
        ssaoIntensity: f32,
        ssaoBias: f32,
        ssaoPower: f32,
        fxaaEnabled: bool,
        taaEnabled: bool,
        taaBlendFactor: f32,
        taaMotionBlurScale: f32,
        taaFeedbackMin: f32,
        taaFeedbackMax: f32,
        contactShadowsEnabled: bool,
        contactShadowsDistance: f32,
        contactShadowsThickness: f32,
        contactShadowsIntensity: f32,
        contactShadowsBias: f32,
        contactShadowsSteps: u32,
        ssrEnabled: bool,
        ssrIntensity: f32,
        ssrRayStep: f32,
        ssrMaxDistance: f32,
        ssrThickness: f32,
        ssrFadeDistance: f32,
        ssrEdgeFade: f32,
        ssrRoughnessBlur: f32,
        ssgiEnabled: bool,
        ssgiRadius: f32,
        ssgiIntensity: f32,
        ssgiBias: f32,
        ssgiRayCount: u32,
        ssgiStepCount: u32,
        colorGradingEnabled: bool,
        colorGradingSaturation: f32,
        colorGradingContrast: f32,
        colorGradingGamma: f32,
        dofEnabled: bool,
        dofFocusDistance: f32,
        dofFocusRange: f32,
        dofBlurRadius: f32,
        dofBokehRadius: f32,
        dofNearBlur: f32,
        dofFarBlur: f32,
        dofQuality: u32,
        lutEnabled: bool,
        lutIntensity: f32,
        lutPreset: []const u8,
        volumetricFogEnabled: bool,
        volumetricFogDensity: f32,
        volumetricFogHeightFalloff: f32,
        volumetricFogMaxDistance: f32,
        rtShadowsEnabled: bool,
        rtShadowSamples: u32,
        rtShadowStrength: f32,
        rtShadowSoftness: f32,
        rtShadowResolutionScale: f32,
    };
};

pub const @"viewport.setRenderSettings" = struct {
    pub const Params = struct {
        shadingMode: ?[]const u8 = null,
        showGrid: ?bool = null,
        showBones: ?bool = null,
        showCollision: ?bool = null,
        bloomEnabled: ?bool = null,
        bloomThreshold: ?f32 = null,
        bloomIntensity: ?f32 = null,
        exposureEnabled: ?bool = null,
        exposure: ?f32 = null,
        ssaoEnabled: ?bool = null,
        ssaoRadius: ?f32 = null,
        ssaoIntensity: ?f32 = null,
        ssaoBias: ?f32 = null,
        ssaoPower: ?f32 = null,
        fxaaEnabled: ?bool = null,
        taaEnabled: ?bool = null,
        taaBlendFactor: ?f32 = null,
        taaMotionBlurScale: ?f32 = null,
        taaFeedbackMin: ?f32 = null,
        taaFeedbackMax: ?f32 = null,
        contactShadowsEnabled: ?bool = null,
        contactShadowsDistance: ?f32 = null,
        contactShadowsThickness: ?f32 = null,
        contactShadowsIntensity: ?f32 = null,
        contactShadowsBias: ?f32 = null,
        contactShadowsSteps: ?u32 = null,
        ssrEnabled: ?bool = null,
        ssrIntensity: ?f32 = null,
        ssrRayStep: ?f32 = null,
        ssrMaxDistance: ?f32 = null,
        ssrThickness: ?f32 = null,
        ssrFadeDistance: ?f32 = null,
        ssrEdgeFade: ?f32 = null,
        ssrRoughnessBlur: ?f32 = null,
        ssgiEnabled: ?bool = null,
        ssgiRadius: ?f32 = null,
        ssgiIntensity: ?f32 = null,
        ssgiBias: ?f32 = null,
        ssgiRayCount: ?u32 = null,
        ssgiStepCount: ?u32 = null,
        colorGradingEnabled: ?bool = null,
        colorGradingSaturation: ?f32 = null,
        colorGradingContrast: ?f32 = null,
        colorGradingGamma: ?f32 = null,
        dofEnabled: ?bool = null,
        dofFocusDistance: ?f32 = null,
        dofFocusRange: ?f32 = null,
        dofBlurRadius: ?f32 = null,
        dofBokehRadius: ?f32 = null,
        dofNearBlur: ?f32 = null,
        dofFarBlur: ?f32 = null,
        dofQuality: ?u32 = null,
        lutEnabled: ?bool = null,
        lutIntensity: ?f32 = null,
        lutPreset: ?[]const u8 = null,
        volumetricFogEnabled: ?bool = null,
        volumetricFogDensity: ?f32 = null,
        volumetricFogHeightFalloff: ?f32 = null,
        volumetricFogMaxDistance: ?f32 = null,
        rtShadowsEnabled: ?bool = null,
        rtShadowSamples: ?u32 = null,
        rtShadowStrength: ?f32 = null,
        rtShadowSoftness: ?f32 = null,
        rtShadowResolutionScale: ?f32 = null,
    };
    pub const Result = struct {};
};

pub const @"viewport.sendInput" = struct {
    pub const Params = struct {
        type: []const u8,
        x: ?f64 = null,
        y: ?f64 = null,
        deltaX: ?f64 = null,
        deltaY: ?f64 = null,
        button: ?[]const u8 = null,
        clicks: ?u64 = null,
        key: ?[]const u8 = null,
        shift: ?bool = null,
        ctrl: ?bool = null,
        alt: ?bool = null,
    };
    pub const Result = struct {};
};

pub const @"viewport.pick" = struct {
    pub const Params = struct {
        x: u64,
        y: u64,
        mode: ?[]const u8 = null,
    };
    pub const Result = struct {};
};

pub const @"viewport.boxSelect" = struct {
    pub const Params = struct {
        x1: u32,
        y1: u32,
        x2: u32,
        y2: u32,
        mode: ?[]const u8 = null,
    };
    pub const Result = struct {
        selectedIds: []const u64,
    };
};

// ── rendersettings namespace ─────────────────────────────────────

pub const @"rendersettings.getSettings" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        shadingMode: []const u8,
        transformSpace: []const u8,
        showGrid: bool,
        showBones: bool,
        showCollision: bool,
        pathTrace: PathTraceSettings,
        viewportSize: ViewportDimensions,
        renderOutput: RenderOutputSettings,

        pub const PathTraceSettings = struct {
            samples: u32,
            bounces: u32,
            resolutionScale: f32,
        };

        pub const ViewportDimensions = struct {
            width: u32,
            height: u32,
        };

        pub const RenderOutputSettings = struct {
            preset: []const u8,
            width: u32,
            height: u32,
            format: []const u8,
            path: []const u8,
        };
    };
};

pub const @"rendersettings.setShadingMode" = struct {
    pub const Params = struct { mode: []const u8 };
    pub const Result = struct {};
};

pub const @"rendersettings.setTransformSpace" = struct {
    pub const Params = struct { space: []const u8 };
    pub const Result = struct {};
};

pub const @"rendersettings.setOverlay" = struct {
    pub const Params = struct { key: []const u8, value: bool };
    pub const Result = struct {};
};

pub const @"rendersettings.setPathTrace" = struct {
    pub const Params = struct { samples: ?u32 = null, bounces: ?u32 = null, resolutionScale: ?f32 = null };
    pub const Result = struct {};
};

pub const @"rendersettings.applyPtPreset" = struct {
    pub const Params = struct { preset: []const u8 };
    pub const Result = struct {};
};

pub const @"rendersettings.setRenderOutput" = struct {
    pub const Params = struct { preset: ?[]const u8 = null, width: ?u32 = null, height: ?u32 = null, format: ?[]const u8 = null, path: ?[]const u8 = null };
    pub const Result = struct {};
};

// ── camera namespace ─────────────────────────────────────────────

pub const @"camera.listBookmarks" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        bookmarks: []const CameraBookmarkInfo,
    };

    pub const CameraBookmarkInfo = struct {
        index: u64,
        name: []const u8,
        position: types.Vec3,
        rotation: types.Quat,
        fov: f32,
    };
};

pub const @"camera.addBookmark" = struct {
    pub const Params = struct { name: ?[]const u8 = null };
    pub const Result = struct { index: u64 };
};

pub const @"camera.removeBookmark" = struct {
    pub const Params = struct { index: u64 };
    pub const Result = struct {};
};

pub const @"camera.applyBookmark" = struct {
    pub const Params = struct { index: u64 };
    pub const Result = struct {};
};

pub const @"camera.renameBookmark" = struct {
    pub const Params = struct { index: u64, name: []const u8 };
    pub const Result = struct {};
};

pub const @"camera.getState" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        position: types.Vec3,
        rotation: types.Quat,
    };
};

pub const @"camera.lookAlongAxis" = struct {
    pub const Params = struct {
        axisX: f64,
        axisY: f64,
        axisZ: f64,
        distance: ?f64 = null,
        targetX: ?f64 = null,
        targetY: ?f64 = null,
        targetZ: ?f64 = null,
    };
    pub const Result = struct {};
};

pub const @"camera.orbit" = struct {
    pub const Params = struct {
        deltaYaw: f64,
        deltaPitch: f64,
    };
    pub const Result = struct {};
};
