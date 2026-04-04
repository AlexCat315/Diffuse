///! Animation, sequencer, and timeline RPC methods.
const types = @import("types.zig");

// ── animation namespace ──────────────────────────────────────────

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
        states: ?[]const types.AnimGraphState = null,
        transitions: ?[]const types.AnimGraphTransition = null,
        parameters: ?[]const types.AnimGraphParameter = null,
        clipTracks: ?[]const types.AnimClipTrack = null,
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

// ── sequencer namespace ──────────────────────────────────────────

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
        tracks: ?[]const types.SequencerTrack = null,
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
