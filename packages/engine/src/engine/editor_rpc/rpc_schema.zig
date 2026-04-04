///! RPC contract schema — THE single source of truth.
///!
///! This file defines every RPC method, shared data type, and subscription
///! event in a fully declarative way. It has ZERO project imports, making
///! it usable by both the engine (runtime dispatch) and the codegen tool
///! (comptime → TypeScript).
///!
///! Workflow:
///!   1. Edit this file to add/change methods or types.
///!   2. Run:  zig run tools/gen_rpc_types.zig > ../editor/src/shared/rpc-types.generated.ts
///!   3. Both Zig and TypeScript are now in sync.

// ═══════════════════════════════════════════════════════════════════
//  Shared data types
// ═══════════════════════════════════════════════════════════════════

pub const SharedTypes = struct {
    pub const Vec3 = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    pub const Quat = struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32,
    };

    pub const Transform = struct {
        position: Vec3,
        rotation: Quat,
        scale: Vec3,
    };

    pub const TransformPartial = struct {
        position: ?Vec3 = null,
        rotation: ?Quat = null,
        scale: ?Vec3 = null,
    };

    pub const EntityNode = struct {
        id: u64,
        name: []const u8,
        visible: bool,
        children: []const EntityNode,
    };

    pub const ComponentInfo = struct {
        type: []const u8,
        fields: []const ComponentField,
    };

    pub const ComponentField = struct {
        name: []const u8,
        fieldType: []const u8,
        value: JsonValue,
        options: ?[]const []const u8 = null,
    };

    /// Opaque JSON value — codegen emits this as `unknown`.
    pub const JsonValue = struct { _opaque: u8 = 0 };

    pub const LogEntry = struct {
        level: []const u8,
        message: []const u8,
        timestamp: f64,
        source: ?[]const u8 = null,
    };

    pub const AssetEntry = struct {
        name: []const u8,
        path: []const u8,
        isDirectory: bool,
        assetType: ?[]const u8 = null,
        size: ?u64 = null,
    };

    pub const SequencerTrack = struct {
        index: u64,
        kind: []const u8,
        target: []const u8,
    };

    pub const AnimGraphState = struct {
        index: u64,
        name: []const u8,
        clipName: ?[]const u8 = null,
        speed: f64,
        loop: bool,
        duration: f64,
        isDefault: bool,
        isCurrent: bool,
        isNext: bool,
    };

    pub const AnimGraphTransition = struct {
        index: u64,
        fromState: u64,
        toState: u64,
        fromStateName: []const u8,
        toStateName: []const u8,
        duration: f64,
        conditions: []const AnimTransitionCondition,
    };

    pub const AnimTransitionCondition = struct {
        index: u64,
        conditionType: []const u8,
        threshold: f64,
        parameterName: ?[]const u8 = null,
        comparison: ?[]const u8 = null,
    };

    pub const AnimGraphParameter = struct {
        index: u64,
        name: []const u8,
        paramType: []const u8,
        floatValue: ?f64 = null,
        boolValue: ?bool = null,
        intValue: ?i64 = null,
    };

    pub const AnimClipTrack = struct {
        index: u64,
        name: []const u8,
        trackType: []const u8,
        keyframeCount: u64,
    };

    // ── Material graph shared types ────────────────────────────

    pub const MaterialGraphNodeInfo = struct {
        id: u32,
        kind: []const u8,
        outputType: []const u8,
        channel: ?[]const u8 = null,
        valueKind: []const u8,
        scalar: f64,
        vec2: [2]f64,
        vec3: [3]f64,
        vec4: [4]f64,
        textureHandle: ?u32 = null,
        posX: f64,
        posY: f64,
    };

    pub const MaterialGraphConnectionInfo = struct {
        fromNodeId: u32,
        fromSlot: u8,
        toNodeId: u32,
        toSlot: u8,
    };

    pub const MaterialGraphOutputInfo = struct {
        channel: []const u8,
        sourceNodeId: u32,
        sourceSlot: u8,
    };
};

// ═══════════════════════════════════════════════════════════════════
//  RPC method contracts — { Params, Result } per method
// ═══════════════════════════════════════════════════════════════════

pub const Methods = struct {
    // ── editor namespace ─────────────────────────────────────────

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

    // ── scene namespace ──────────────────────────────────────────

    pub const @"scene.getHierarchy" = struct {
        pub const Params = struct {};
        pub const Result = struct { roots: []const SharedTypes.EntityNode };
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

    // ── entity namespace ─────────────────────────────────────────

    pub const @"entity.getTransform" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = SharedTypes.Transform;
    };

    pub const @"entity.setTransform" = struct {
        pub const Params = struct {
            entityId: u64,
            transform: SharedTypes.TransformPartial,
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
        pub const Result = struct { components: []const SharedTypes.ComponentInfo };
    };

    pub const @"entity.setComponentField" = struct {
        pub const Params = struct {
            entityId: u64,
            componentType: []const u8,
            fieldName: []const u8,
            value: SharedTypes.JsonValue,
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

    // ── playback namespace ───────────────────────────────────────

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

    // ── viewport namespace ───────────────────────────────────────

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

    // ── console namespace ────────────────────────────────────────

    pub const @"console.clear" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    // ── assets namespace ─────────────────────────────────────────

    pub const @"assets.list" = struct {
        pub const Params = struct { path: ?[]const u8 = null };
        pub const Result = struct {
            path: []const u8,
            entries: []const SharedTypes.AssetEntry,
        };
    };

    // ── camera namespace ─────────────────────────────────────────

    pub const @"camera.listBookmarks" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            bookmarks: []const CameraBookmarkInfo,
        };

        pub const CameraBookmarkInfo = struct {
            index: u64,
            name: []const u8,
            position: SharedTypes.Vec3,
            rotation: SharedTypes.Quat,
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
            position: SharedTypes.Vec3,
            rotation: SharedTypes.Quat,
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

    // ── debug namespace ──────────────────────────────────────────

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

    // ── audio namespace ──────────────────────────────────────────

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

    // ── plugin namespace ─────────────────────────────────────────

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

    // ── style namespace ──────────────────────────────────────────

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

    // ── scene.spawnActor ─────────────────────────────────────────

    pub const @"scene.spawnActor" = struct {
        pub const Params = struct { kind: []const u8 };
        pub const Result = struct { entityId: u64 };
    };

    // ── renderqueue namespace ────────────────────────────────────

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

    // ── physicsviz namespace ─────────────────────────────────────

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

    // ── utilities namespace ──────────────────────────────────────

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

    // ── rendersettings namespace ─────────────────────────────────

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

    // ── material namespace ───────────────────────────────────────

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

    // ── material graph editing ─────────────────────────────────

    pub const @"material.getGraph" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = struct {
            hasGraph: bool,
            nodes: ?[]const SharedTypes.MaterialGraphNodeInfo = null,
            connections: ?[]const SharedTypes.MaterialGraphConnectionInfo = null,
            outputs: ?[]const SharedTypes.MaterialGraphOutputInfo = null,
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

    // ── animation ──────────────────────────────────────────────

    pub const @"animation.getState" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = struct {
            hasAnimator: bool,
            hasGraph: bool,
            graphName: ?[]const u8 = null,
            currentState: ?u32 = null,
            nextState: ?u32 = null,
            blendFactor: ?f64 = null,
            transitionTime: ?f64 = null,
            transitionDuration: ?f64 = null,
            defaultState: ?u32 = null,
            states: ?[]const AnimGraphState = null,
            transitions: ?[]const AnimGraphTransition = null,
            parameters: ?[]const AnimGraphParameter = null,
            clipTracks: ?[]const AnimClipTrack = null,
            clipDuration: ?f64 = null,
            sampleTime: ?f64 = null,
        };
    };

    pub const @"animation.addState" = struct {
        pub const Params = struct { entityId: u64, name: ?[]const u8 = null };
        pub const Result = struct { index: u64 };
    };

    pub const @"animation.updateState" = struct {
        pub const Params = struct {
            entityId: u64,
            stateIndex: u64,
            name: ?[]const u8 = null,
            clip: ?[]const u8 = null,
            speed: ?f64 = null,
            loop: ?bool = null,
            duration: ?f64 = null,
        };
        pub const Result = struct {};
    };

    pub const @"animation.removeState" = struct {
        pub const Params = struct { entityId: u64, stateIndex: u64 };
        pub const Result = struct {};
    };

    pub const @"animation.setDefaultState" = struct {
        pub const Params = struct { entityId: u64, stateIndex: u64 };
        pub const Result = struct {};
    };

    pub const @"animation.activateState" = struct {
        pub const Params = struct { entityId: u64, stateIndex: u64 };
        pub const Result = struct {};
    };

    pub const @"animation.addTransition" = struct {
        pub const Params = struct {
            entityId: u64,
            fromState: u64,
            toState: u64,
            duration: ?f64 = null,
            triggerTime: ?f64 = null,
        };
        pub const Result = struct { index: u64 };
    };

    pub const @"animation.updateTransition" = struct {
        pub const Params = struct {
            entityId: u64,
            transitionIndex: u64,
            fromState: ?u64 = null,
            toState: ?u64 = null,
            duration: ?f64 = null,
        };
        pub const Result = struct {};
    };

    pub const @"animation.removeTransition" = struct {
        pub const Params = struct { entityId: u64, transitionIndex: u64 };
        pub const Result = struct {};
    };

    pub const @"animation.addCondition" = struct {
        pub const Params = struct {
            entityId: u64,
            transitionIndex: u64,
            conditionType: []const u8,
            threshold: ?f64 = null,
            parameterName: ?[]const u8 = null,
            comparison: ?[]const u8 = null,
        };
        pub const Result = struct { index: u64 };
    };

    pub const @"animation.updateCondition" = struct {
        pub const Params = struct {
            entityId: u64,
            transitionIndex: u64,
            conditionIndex: u64,
            conditionType: ?[]const u8 = null,
            threshold: ?f64 = null,
            parameterName: ?[]const u8 = null,
            comparison: ?[]const u8 = null,
        };
        pub const Result = struct {};
    };

    pub const @"animation.removeCondition" = struct {
        pub const Params = struct { entityId: u64, transitionIndex: u64, conditionIndex: u64 };
        pub const Result = struct {};
    };

    pub const @"animation.setParameter" = struct {
        pub const Params = struct {
            entityId: u64,
            parameterIndex: u64,
            floatValue: ?f64 = null,
            boolValue: ?bool = null,
            intValue: ?i64 = null,
        };
        pub const Result = struct {};
    };

    // ── sequencer ───────────────────────────────────────────────

    pub const @"sequencer.getState" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            loaded: bool,
            name: ?[]const u8 = null,
            fps: ?f64 = null,
            duration: ?f64 = null,
            currentTime: f64,
            isPlaying: bool,
            speed: f64,
            filePath: ?[]const u8 = null,
            tracks: ?[]const SharedTypes.SequencerTrack = null,
        };
    };

    pub const @"sequencer.create" = struct {
        pub const Params = struct { name: ?[]const u8 = null, fps: ?f64 = null };
        pub const Result = struct { ok: bool };
    };

    pub const @"sequencer.load" = struct {
        pub const Params = struct { path: []const u8 };
        pub const Result = struct { ok: bool, @"error": ?[]const u8 = null };
    };

    pub const @"sequencer.save" = struct {
        pub const Params = struct { path: ?[]const u8 = null };
        pub const Result = struct { ok: bool, @"error": ?[]const u8 = null };
    };

    pub const @"sequencer.setProperties" = struct {
        pub const Params = struct { name: ?[]const u8 = null, fps: ?f64 = null, duration: ?f64 = null };
        pub const Result = struct {};
    };

    pub const @"sequencer.addTrack" = struct {
        pub const Params = struct { kind: []const u8, target: []const u8 };
        pub const Result = struct { index: u64 };
    };

    pub const @"sequencer.removeTrack" = struct {
        pub const Params = struct { index: u64 };
        pub const Result = struct {};
    };

    pub const @"sequencer.updateTrack" = struct {
        pub const Params = struct {
            index: u64,
            clipPath: ?[]const u8 = null,
            startTime: ?f64 = null,
            endTime: ?f64 = null,
            blendIn: ?f64 = null,
            blendOut: ?f64 = null,
            speed: ?f64 = null,
            volume: ?f64 = null,
            fadeIn: ?f64 = null,
            fadeOut: ?f64 = null,
            property: ?[]const u8 = null,
        };
        pub const Result = struct {};
    };

    pub const @"sequencer.addKeyframe" = struct {
        pub const Params = struct {
            trackIndex: u64,
            time: f64,
            position: ?[3]f64 = null,
            rotation: ?[4]f64 = null,
            fov: ?f64 = null,
            easing: ?[]const u8 = null,
            value: ?f64 = null,
            name: ?[]const u8 = null,
        };
        pub const Result = struct { count: ?u64 = null, @"error": ?[]const u8 = null };
    };

    pub const @"sequencer.removeKeyframe" = struct {
        pub const Params = struct { trackIndex: u64, keyframeIndex: u64 };
        pub const Result = struct { @"error": ?[]const u8 = null };
    };

    pub const @"sequencer.updateKeyframe" = struct {
        pub const Params = struct {
            trackIndex: u64,
            keyframeIndex: u64,
            time: ?f64 = null,
            position: ?[3]f64 = null,
            rotation: ?[4]f64 = null,
            fov: ?f64 = null,
            easing: ?[]const u8 = null,
            value: ?f64 = null,
            name: ?[]const u8 = null,
        };
        pub const Result = struct {};
    };

    pub const @"sequencer.play" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"sequencer.pause" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"sequencer.stop" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"sequencer.seek" = struct {
        pub const Params = struct { time: f64 };
        pub const Result = struct {};
    };

    pub const @"sequencer.setSpeed" = struct {
        pub const Params = struct { speed: f64 };
        pub const Result = struct {};
    };

    pub const @"sequencer.recomputeDuration" = struct {
        pub const Params = struct {};
        pub const Result = struct { duration: f64 };
    };
};

// ═══════════════════════════════════════════════════════════════════
//  Subscription event payloads
// ═══════════════════════════════════════════════════════════════════

pub const Subscriptions = struct {
    pub const @"on:scene.changed" = struct {
        revision: u64,
        entityIds: []const u64,
    };

    pub const @"on:selection.changed" = struct {
        entityIds: []const u64,
    };

    pub const @"on:console.log" = SharedTypes.LogEntry;

    pub const @"on:viewport.metrics" = struct {
        fps: f64,
        drawCalls: u64,
        triangles: u64,
    };

    pub const @"on:playback.stateChanged" = struct {
        state: []const u8,
    };

    pub const @"on:asset.changed" = struct {
        assetId: []const u8,
        changeType: []const u8,
    };

    pub const @"on:editor.historyChanged" = struct {
        cursor: u64,
        totalEntries: u64,
    };
};
