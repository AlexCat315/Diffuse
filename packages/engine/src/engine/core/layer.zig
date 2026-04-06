const std = @import("std");
const scene_mod = @import("../scene/scene.zig");
const renderer_mod = @import("../render/renderer.zig");
const rhi_mod = @import("../rhi/device.zig");
const input_mod = @import("input.zig");
const input_action_mod = @import("input_action.zig");
const command_queue_mod = @import("command_queue.zig");
const editor_utility_runtime_mod = @import("../script/editor_utility_runtime.zig");
const scene_manager_mod = @import("scene_manager.zig");
const script_runtime_mod = @import("../script/runtime.zig");
const debug_session_mod = @import("../script/debug_session.zig");
const window_mod = @import("../platform/window.zig");
const physics_mod = @import("../physics/system.zig");
const nav_mod = @import("../navigation/nav_system.zig");

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
};

/// 游戏运行时状态机
pub const GameState = enum(u32) {
    /// 初始化/加载中
    game_start = 0,
    /// 正常运行
    playing = 1,
    /// 暂停（UI 叠加）
    paused = 2,
    /// 游戏结束
    game_over = 3,
    /// 退出
    quit = 4,
};

pub const PlaybackController = struct {
    state: PlaybackState = .stopped,
    pending_steps: usize = 0,
    fixed_delta_seconds: ?f32 = null,
    /// Scene snapshot taken when entering play mode, used to rollback on stop.
    snapshot: ?[]u8 = null,
    snapshot_allocator: ?std.mem.Allocator = null,

    pub fn setState(self: *PlaybackController, next: PlaybackState) void {
        self.state = next;
        self.pending_steps = 0;
        self.fixed_delta_seconds = null;
    }

    pub fn storeSnapshot(self: *PlaybackController, allocator: std.mem.Allocator, data: []u8) void {
        self.clearSnapshot();
        self.snapshot = data;
        self.snapshot_allocator = allocator;
    }

    pub fn takeSnapshot(self: *PlaybackController) ?[]u8 {
        const data = self.snapshot;
        self.snapshot = null;
        self.snapshot_allocator = null;
        return data;
    }

    pub fn clearSnapshot(self: *PlaybackController) void {
        if (self.snapshot) |s| {
            if (self.snapshot_allocator) |a| a.free(s);
        }
        self.snapshot = null;
        self.snapshot_allocator = null;
    }

    pub fn requestStep(self: *PlaybackController) void {
        self.state = .paused;
        self.pending_steps += 1;
        self.fixed_delta_seconds = null;
    }

    pub fn setFixedDelta(self: *PlaybackController, delta_seconds: ?f32) void {
        self.fixed_delta_seconds = if (delta_seconds) |delta|
            if (std.math.isFinite(delta) and delta > 0.0) delta else null
        else
            null;
    }

    pub fn shouldAdvance(self: *const PlaybackController) bool {
        return self.state == .playing or self.pending_steps > 0;
    }

    pub fn consumeAdvance(self: *PlaybackController) void {
        if (self.state == .playing or self.pending_steps == 0) {
            return;
        }
        self.pending_steps -= 1;
    }
};

pub const LayerContext = struct {
    world: *scene_mod.World,
    scene: *scene_mod.Scene,
    renderer: *renderer_mod.Renderer,
    scene_manager: ?*scene_manager_mod.SceneManager = null,
    command_queue: ?*command_queue_mod.CommandQueue = null,
    script_runtime: ?*script_runtime_mod.ScriptRuntime = null,
    script_debug_session: ?*debug_session_mod.DebugSession = null,
    editor_utility_runtime: ?*editor_utility_runtime_mod.EditorUtilityRuntime = null,
    input: *input_mod.InputState,
    action_map: ?*input_action_mod.ActionMap = null,
    window: *window_mod.Window,
    playback_controller: *PlaybackController,
    game_state: *GameState,
    global_time: *f32,
    time_scale: *f32,
    physics_accumulator_seconds: *f32,
    physics_state: *physics_mod.PhysicsState,
    nav_system: ?*nav_mod.NavSystem = null,
    pending_file_drop: ?*?[:0]const u8 = null,
    frame_index: usize,
    delta_seconds: f32,

    pub fn rhi(self: *LayerContext) *rhi_mod.RhiDevice {
        return self.renderer.device();
    }
};

pub const Hooks = struct {
    on_attach: ?*const fn (context: *anyopaque, layer_context: *LayerContext) anyerror!void = null,
    on_detach: ?*const fn (context: *anyopaque) void = null,
    on_update: ?*const fn (context: *anyopaque, layer_context: *LayerContext) anyerror!void = null,
};

pub const Layer = struct {
    name: []const u8,
    context: *anyopaque,
    hooks: Hooks = .{},

    pub fn attach(self: *const Layer, layer_context: *LayerContext) !void {
        if (self.hooks.on_attach) |hook| {
            try hook(self.context, layer_context);
        }
    }

    pub fn detach(self: *const Layer) void {
        if (self.hooks.on_detach) |hook| {
            hook(self.context);
        }
    }

    pub fn update(self: *const Layer, layer_context: *LayerContext) !void {
        if (self.hooks.on_update) |hook| {
            try hook(self.context, layer_context);
        }
    }
};

test "PlaybackController advances only while playing or stepping" {
    var controller = PlaybackController{};
    try std.testing.expect(!controller.shouldAdvance());

    controller.requestStep();
    try std.testing.expect(controller.shouldAdvance());
    try std.testing.expectEqual(@as(PlaybackState, .paused), controller.state);
    controller.consumeAdvance();
    try std.testing.expect(!controller.shouldAdvance());

    controller.setState(.playing);
    try std.testing.expect(controller.shouldAdvance());
    controller.consumeAdvance();
    try std.testing.expect(controller.shouldAdvance());

    controller.setState(.stopped);
    try std.testing.expect(!controller.shouldAdvance());

    controller.requestStep();
    controller.setState(.paused);
    try std.testing.expect(!controller.shouldAdvance());
}

test "PlaybackController fixed delta override resets with state changes" {
    var controller = PlaybackController{};
    controller.setFixedDelta(1.0 / 24.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 24.0), controller.fixed_delta_seconds.?, 0.0001);

    controller.requestStep();
    try std.testing.expectEqual(@as(?f32, null), controller.fixed_delta_seconds);

    controller.setFixedDelta(1.0 / 30.0);
    controller.setState(.playing);
    try std.testing.expectEqual(@as(?f32, null), controller.fixed_delta_seconds);

    controller.setFixedDelta(-1.0);
    try std.testing.expectEqual(@as(?f32, null), controller.fixed_delta_seconds);
}
