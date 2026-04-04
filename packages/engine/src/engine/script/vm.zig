const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const types = @import("./types.zig");
const context = @import("./context.zig");
const vm_interface = @import("./vm_interface.zig");
const csharp_toolchain = @import("./csharp_toolchain.zig");
const components = @import("../scene/components.zig");
const quat = @import("../math/quat.zig");
const vec3 = @import("../math/vec3.zig");
const world_mod = @import("../scene/world.zig");
const input_mod = @import("../core/input.zig");
const audio_mod = @import("../audio/mod.zig");
const animator_system = @import("../animation/animator_system.zig");

const log = std.log.scoped(.vm);

const BuiltinKind = enum(u8) {
    none,
    rotate,
    patrol,
    fly_camera,
    fps_controller,
};

const ScriptDefinition = struct {
    kind: BuiltinKind = .none,

    rotate_axis: components.Vec3 = .{ 0.0, 1.0, 0.0 },
    rotate_speed_radians: f32 = std.math.pi * 0.25,
    rotate_local_space: bool = true,

    patrol_speed: f32 = 2.0,
    patrol_waypoints: [8]components.Vec3 = [_]components.Vec3{.{ 0.0, 0.0, 0.0 }} ** 8,
    patrol_waypoint_count: u8 = 0,
    patrol_arrival_threshold: f32 = 0.1,
    patrol_loop: bool = true,
    patrol_wait_at_waypoint: bool = false,
    patrol_wait_time: f32 = 1.0,

    fly_move_speed: f32 = 5.0,
    fly_mouse_sensitivity: f32 = 0.002,

    fps_move_speed: f32 = 5.0,
    fps_mouse_sensitivity: f32 = 0.002,
    fps_gravity: f32 = -9.8,
    fps_jump_velocity: f32 = 5.0,
};

const RotateState = struct {
    axis: components.Vec3,
    speed_radians: f32,
    local_space: bool,
};

const PatrolState = struct {
    speed: f32,
    waypoints: [8]components.Vec3,
    waypoint_count: u8,
    arrival_threshold: f32,
    loop: bool,
    wait_at_waypoint: bool,
    wait_time: f32,
    wait_timer: f32 = 0.0,
    current_waypoint: u8 = 0,
};

const FlyCameraState = struct {
    move_speed: f32,
    mouse_sensitivity: f32,
    first_mouse: bool = true,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    pitch: f32 = 0.0,
    yaw: f32 = -std.math.pi * 0.5,
};

const FpsControllerState = struct {
    move_speed: f32,
    mouse_sensitivity: f32,
    gravity: f32,
    jump_velocity: f32,
    is_grounded: bool = false,
    vertical_velocity: f32 = 0.0,
    first_mouse: bool = true,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    pitch: f32 = 0.0,
    yaw: f32 = -std.math.pi * 0.5,
};

pub const ScriptVM = vm_interface.ScriptVM;

fn GameplayBuiltinVM(comptime accepted_language: types.ScriptLanguage, comptime frontend_label: []const u8) type {
    return struct {
        source: []const u8 = &.{},
        definition: ScriptDefinition = .{},
        error_msg: []u8 = &.{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn load(vm: *Self, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
            if (resource.language != accepted_language) {
                setOwnedMessage(vm.allocator, &vm.error_msg, std.fmt.comptimePrint("script language does not match {s}", .{frontend_label}));
                return types.ScriptError.InvalidLanguage;
            }

            vm.source = resource.source;
            vm.definition = parseScriptDefinition(resource.source) catch |err| {
                const message = switch (err) {
                    error.InvalidDirective => std.fmt.comptimePrint("invalid //!guava directive in {s} gameplay script", .{frontend_label}),
                    error.UnsupportedBuiltinScript => std.fmt.comptimePrint(
                        "dynamic {s} gameplay compilation is unavailable; add //!guava builtin=rotate|patrol|fly_camera|fps_controller",
                        .{frontend_label},
                    ),
                };
                setOwnedMessage(vm.allocator, &vm.error_msg, message);
                return types.ScriptError.CompileError;
            };

            clearOwnedMessage(vm.allocator, &vm.error_msg);
            log.info("{s} gameplay script loaded kind={s}", .{ frontend_label, @tagName(vm.definition.kind) });
        }

        pub fn unload(vm: *Self) void {
            vm.source = &.{};
            vm.definition = .{};
            clearOwnedMessage(vm.allocator, &vm.error_msg);
        }

        pub fn createInstance(vm: *Self, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
            if (vm.definition.kind == .none) {
                setOwnedMessage(vm.allocator, &vm.error_msg, std.fmt.comptimePrint("no {s} gameplay script is loaded", .{frontend_label}));
                return types.ScriptError.NotFound;
            }

            const instance = try vm.allocator.create(types.ScriptInstance);
            errdefer vm.allocator.destroy(instance);

            instance.* = .{
                .id = 0,
                .entity_id = ctx.entity,
                .script_handle = undefined,
                .vtable = vtableForKind(vm.definition.kind),
                .user_data_tag = @intFromEnum(vm.definition.kind),
                .state = .ready,
            };

            switch (vm.definition.kind) {
                .rotate => {
                    const state = try vm.allocator.create(RotateState);
                    state.* = .{
                        .axis = vec3.normalize(vm.definition.rotate_axis),
                        .speed_radians = vm.definition.rotate_speed_radians,
                        .local_space = vm.definition.rotate_local_space,
                    };
                    instance.user_data = state;
                    instance.user_data_size = @sizeOf(RotateState);
                },
                .patrol => {
                    const state = try vm.allocator.create(PatrolState);
                    state.* = .{
                        .speed = vm.definition.patrol_speed,
                        .waypoints = vm.definition.patrol_waypoints,
                        .waypoint_count = vm.definition.patrol_waypoint_count,
                        .arrival_threshold = vm.definition.patrol_arrival_threshold,
                        .loop = vm.definition.patrol_loop,
                        .wait_at_waypoint = vm.definition.patrol_wait_at_waypoint,
                        .wait_time = vm.definition.patrol_wait_time,
                    };
                    instance.user_data = state;
                    instance.user_data_size = @sizeOf(PatrolState);
                },
                .fly_camera => {
                    const state = try vm.allocator.create(FlyCameraState);
                    state.* = .{
                        .move_speed = vm.definition.fly_move_speed,
                        .mouse_sensitivity = vm.definition.fly_mouse_sensitivity,
                    };
                    initializeLookAnglesFromTransform(&state.pitch, &state.yaw, ctx);
                    instance.user_data = state;
                    instance.user_data_size = @sizeOf(FlyCameraState);
                },
                .fps_controller => {
                    const state = try vm.allocator.create(FpsControllerState);
                    state.* = .{
                        .move_speed = vm.definition.fps_move_speed,
                        .mouse_sensitivity = vm.definition.fps_mouse_sensitivity,
                        .gravity = vm.definition.fps_gravity,
                        .jump_velocity = vm.definition.fps_jump_velocity,
                    };
                    initializeLookAnglesFromTransform(&state.pitch, &state.yaw, ctx);
                    instance.user_data = state;
                    instance.user_data_size = @sizeOf(FpsControllerState);
                },
                .none => unreachable,
            }

            return instance;
        }

        pub fn destroyInstance(vm: *Self, instance: *types.ScriptInstance) void {
            if (instance.user_data) |data| {
                switch (builtinKindFromTag(instance.user_data_tag)) {
                    .rotate => vm.allocator.destroy(castUserData(RotateState, data)),
                    .patrol => vm.allocator.destroy(castUserData(PatrolState, data)),
                    .fly_camera => vm.allocator.destroy(castUserData(FlyCameraState, data)),
                    .fps_controller => vm.allocator.destroy(castUserData(FpsControllerState, data)),
                    .none => {},
                }
                instance.user_data = null;
                instance.user_data_size = 0;
            }
            vm.allocator.destroy(instance);
        }

        pub fn callInit(_: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
            ctx.instance = instance;
            if (instance.vtable.onInit) |fn_ptr| {
                fn_ptr(ctx);
            }
        }

        pub fn callUpdate(_: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
            ctx.instance = instance;
            if (instance.vtable.onUpdate) |fn_ptr| {
                fn_ptr(ctx, dt);
            }
        }

        pub fn callDestroy(_: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
            ctx.instance = instance;
            if (instance.vtable.onDestroy) |fn_ptr| {
                fn_ptr(ctx);
            }
        }

        pub fn getError(vm: *Self) []const u8 {
            return vm.error_msg;
        }

        fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const vm = castContext(Self, context_ptr);
            clearOwnedMessage(vm.allocator, &vm.error_msg);
            allocator.destroy(vm);
        }

        pub const script_vm_vtable: ScriptVM.VTable = .{
            .load = loadBridge,
            .unload = unloadBridge,
            .createInstance = createInstanceBridge,
            .destroyInstance = destroyInstanceBridge,
            .callInit = callInitBridge,
            .callUpdate = callUpdateBridge,
            .callDestroy = callDestroyBridge,
            .callTriggerEnter = callTriggerEnterBridge,
            .callTriggerExit = callTriggerExitBridge,
            .callCollisionEnter = callCollisionEnterBridge,
            .callCollisionExit = callCollisionExitBridge,
            .getError = getErrorBridge,
            .destroy = destroyContext,
        };

        fn callTriggerEnterBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
            _ = castContext(Self, context_ptr);
            ctx.instance = instance;
            if (instance.vtable.onTriggerEnter) |fn_ptr| fn_ptr(ctx, other);
        }

        fn callTriggerExitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
            _ = castContext(Self, context_ptr);
            ctx.instance = instance;
            if (instance.vtable.onTriggerExit) |fn_ptr| fn_ptr(ctx, other);
        }

        fn callCollisionEnterBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
            _ = castContext(Self, context_ptr);
            ctx.instance = instance;
            if (instance.vtable.onCollisionEnter) |fn_ptr| fn_ptr(ctx, other);
        }

        fn callCollisionExitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
            _ = castContext(Self, context_ptr);
            ctx.instance = instance;
            if (instance.vtable.onCollisionExit) |fn_ptr| fn_ptr(ctx, other);
        }

        fn loadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
            return Self.load(castContext(Self, context_ptr), resource);
        }

        fn unloadBridge(context_ptr: *anyopaque) void {
            Self.unload(castContext(Self, context_ptr));
        }

        fn createInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
            return Self.createInstance(castContext(Self, context_ptr), ctx);
        }

        fn destroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
            Self.destroyInstance(castContext(Self, context_ptr), instance);
        }

        fn callInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
            return Self.callInit(castContext(Self, context_ptr), instance, ctx);
        }

        fn callUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
            return Self.callUpdate(castContext(Self, context_ptr), instance, ctx, dt);
        }

        fn callDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
            return Self.callDestroy(castContext(Self, context_ptr), instance, ctx);
        }

        fn getErrorBridge(context_ptr: *anyopaque) []const u8 {
            return Self.getError(castContext(Self, context_ptr));
        }
    };
}

const ZigBuiltinVM = GameplayBuiltinVM(.zig, "ZigVM");
const CSharpBuiltinVM = GameplayBuiltinVM(.csharp, "CSharpVM");

// ---------------------------------------------------------------------------
// Zig Dylib Host API — 布局必须与 src/engine/script/script_api.zig HostApi 完全一致
// ---------------------------------------------------------------------------

const zig_dylib_api_version: u32 = 1;
const zig_dylib_user_data_tag: u32 = 0x5A444C42; // "ZDLB"

const ZigDylibHostContext = struct {
    active_context: ?*context.ScriptContext = null,
};

const ZigDylibHostApi = extern struct {
    // Logging
    log_fn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    // Entity
    get_entity_id: *const fn (?*anyopaque) callconv(.c) u64,
    find_entity_by_name: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u64,
    spawn_entity: *const fn (?*anyopaque) callconv(.c) u64,
    destroy_entity: *const fn (?*anyopaque, u64) callconv(.c) void,
    // Transform
    get_position: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_position: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,
    get_rotation: *const fn (?*anyopaque, *f32, *f32, *f32, *f32) callconv(.c) void,
    set_rotation: *const fn (?*anyopaque, f32, f32, f32, f32) callconv(.c) void,
    get_scale: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_scale: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,
    // Input
    is_key_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_released: *const fn (?*anyopaque, u32) callconv(.c) u32,
    is_mouse_button_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_mouse_position: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    get_mouse_delta: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    get_mouse_wheel: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    // Time
    get_delta_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_time: *const fn (?*anyopaque) callconv(.c) f32,
    // Physics
    raycast: *const fn (?*anyopaque, f32, f32, f32, f32, f32, f32, f32, *f32, *f32, *f32, *f32, *u64) callconv(.c) u32,
    set_linear_velocity: *const fn (?*anyopaque, u64, f32, f32, f32) callconv(.c) void,
    get_linear_velocity: *const fn (?*anyopaque, u64, *f32, *f32, *f32) callconv(.c) void,
    add_impulse: *const fn (?*anyopaque, u64, f32, f32, f32) callconv(.c) void,
    // Scene
    load_scene: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    // Gamepad
    is_gamepad_connected: *const fn (?*anyopaque) callconv(.c) u32,
    is_gamepad_button_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_gamepad_button_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_gamepad_axis: *const fn (?*anyopaque, u32) callconv(.c) f32,
    // Audio
    audio_load_clip: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u32,
    audio_play_2d: *const fn (?*anyopaque, u32, f32, u32) callconv(.c) u32,
    audio_play_3d: *const fn (?*anyopaque, u32, f32, f32, f32, f32, u32) callconv(.c) u32,
    audio_stop: *const fn (?*anyopaque, u32) callconv(.c) void,
    audio_set_volume: *const fn (?*anyopaque, u32, f32) callconv(.c) void,
    audio_pause: *const fn (?*anyopaque, u32, u32) callconv(.c) void,
    audio_is_playing: *const fn (?*anyopaque, u32) callconv(.c) u32,
    // Animation
    anim_play: *const fn (?*anyopaque, u64, [*]const u8, usize, f32) callconv(.c) void,
    anim_stop: *const fn (?*anyopaque, u64) callconv(.c) void,
    anim_set_speed: *const fn (?*anyopaque, u64, f32) callconv(.c) void,
    anim_is_playing: *const fn (?*anyopaque, u64) callconv(.c) u32,
    // Canvas / UI
    canvas_clear: *const fn (?*anyopaque) callconv(.c) void,
    canvas_add_text: *const fn (?*anyopaque, f32, f32, f32, f32, [*]const u8, usize, u8, u8, u8, u8) callconv(.c) u32,
    canvas_add_panel: *const fn (?*anyopaque, f32, f32, f32, f32, u8, u8, u8, u8) callconv(.c) u32,
    canvas_add_button: *const fn (?*anyopaque, f32, f32, f32, f32, [*]const u8, usize) callconv(.c) u32,
    canvas_add_progress_bar: *const fn (?*anyopaque, f32, f32, f32, f32, f32) callconv(.c) u32,
    canvas_set_text: *const fn (?*anyopaque, u32, [*]const u8, usize) callconv(.c) void,
    canvas_set_progress: *const fn (?*anyopaque, u32, f32) callconv(.c) void,
    canvas_set_visible: *const fn (?*anyopaque, u32, u32) callconv(.c) void,
    canvas_remove_widget: *const fn (?*anyopaque, u32) callconv(.c) void,
    canvas_was_button_clicked: *const fn (?*anyopaque, u32) callconv(.c) u32,
};

const zig_dylib_host_api: ZigDylibHostApi = .{
    .log_fn = zigDylibHostLog,
    .get_entity_id = zigDylibHostGetEntityId,
    .find_entity_by_name = zigDylibHostFindEntityByName,
    .spawn_entity = zigDylibHostSpawnEntity,
    .destroy_entity = zigDylibHostDestroyEntity,
    .get_position = zigDylibHostGetPosition,
    .set_position = zigDylibHostSetPosition,
    .get_rotation = zigDylibHostGetRotation,
    .set_rotation = zigDylibHostSetRotation,
    .get_scale = zigDylibHostGetScale,
    .set_scale = zigDylibHostSetScale,
    .is_key_down = zigDylibHostIsKeyDown,
    .was_key_pressed = zigDylibHostWasKeyPressed,
    .was_key_released = zigDylibHostWasKeyReleased,
    .is_mouse_button_down = zigDylibHostIsMouseButtonDown,
    .get_mouse_position = zigDylibHostGetMousePosition,
    .get_mouse_delta = zigDylibHostGetMouseDelta,
    .get_mouse_wheel = zigDylibHostGetMouseWheel,
    .get_delta_time = zigDylibHostGetDeltaTime,
    .get_time = zigDylibHostGetTime,
    .raycast = zigDylibHostRaycast,
    .set_linear_velocity = zigDylibHostSetLinearVelocity,
    .get_linear_velocity = zigDylibHostGetLinearVelocity,
    .add_impulse = zigDylibHostAddImpulse,
    .load_scene = zigDylibHostLoadScene,
    .is_gamepad_connected = zigDylibHostIsGamepadConnected,
    .is_gamepad_button_down = zigDylibHostIsGamepadButtonDown,
    .was_gamepad_button_pressed = zigDylibHostWasGamepadButtonPressed,
    .get_gamepad_axis = zigDylibHostGetGamepadAxis,
    // Audio
    .audio_load_clip = zigDylibHostAudioLoadClip,
    .audio_play_2d = zigDylibHostAudioPlay2d,
    .audio_play_3d = zigDylibHostAudioPlay3d,
    .audio_stop = zigDylibHostAudioStop,
    .audio_set_volume = zigDylibHostAudioSetVolume,
    .audio_pause = zigDylibHostAudioPause,
    .audio_is_playing = zigDylibHostAudioIsPlaying,
    // Animation
    .anim_play = zigDylibHostAnimPlay,
    .anim_stop = zigDylibHostAnimStop,
    .anim_set_speed = zigDylibHostAnimSetSpeed,
    .anim_is_playing = zigDylibHostAnimIsPlaying,
    // Canvas / UI
    .canvas_clear = zigDylibHostCanvasClear,
    .canvas_add_text = zigDylibHostCanvasAddText,
    .canvas_add_panel = zigDylibHostCanvasAddPanel,
    .canvas_add_button = zigDylibHostCanvasAddButton,
    .canvas_add_progress_bar = zigDylibHostCanvasAddProgressBar,
    .canvas_set_text = zigDylibHostCanvasSetText,
    .canvas_set_progress = zigDylibHostCanvasSetProgress,
    .canvas_set_visible = zigDylibHostCanvasSetVisible,
    .canvas_remove_widget = zigDylibHostCanvasRemoveWidget,
    .canvas_was_button_clicked = zigDylibHostCanvasWasButtonClicked,
};

const ZigDylibLibrary = struct {
    path: []u8,
    lib: std.DynLib,
    bind: *const fn (*const ZigDylibHostApi, ?*anyopaque, u64) callconv(.c) void,
    on_init: ?*const fn () callconv(.c) void,
    on_update: ?*const fn (f32) callconv(.c) void,
    on_destroy: ?*const fn () callconv(.c) void,
    on_collision_enter: ?*const fn (u64) callconv(.c) void,
    on_collision_exit: ?*const fn (u64) callconv(.c) void,
    on_trigger_enter: ?*const fn (u64) callconv(.c) void,
    on_trigger_exit: ?*const fn (u64) callconv(.c) void,
};

const ZigDylibInstanceState = struct {
    library: *ZigDylibLibrary,
    host_context: ZigDylibHostContext = .{},
};

// ---------------------------------------------------------------------------
// ZigVM — 复合 VM：内建行为 + Zig Dylib 动态脚本
// ---------------------------------------------------------------------------

pub const ZigVM = struct {
    allocator: std.mem.Allocator,
    builtin: ZigBuiltinVM,
    loaded_dylibs: std.ArrayList(*ZigDylibLibrary) = .empty,
    current_dylib: ?*ZigDylibLibrary = null,
    error_msg: []u8 = &.{},
    mode: enum { none, builtin, dylib } = .none,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .builtin = ZigBuiltinVM.init(allocator),
        };
    }

    pub fn load(vm: *Self, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        if (resource.language != .zig) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "script language does not match ZigVM");
            return types.ScriptError.InvalidLanguage;
        }

        vm.current_dylib = null;
        vm.mode = .none;
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        vm.builtin.unload();

        // 1) 如果 source_path 或 artifact_path 直接指向 .dylib/.so/.dll，直接加载
        if (resolveZigDylibPath(resource)) |dylib_path| {
            vm.current_dylib = vm.ensureDylibLoaded(dylib_path) catch {
                return types.ScriptError.LoadError;
            };
            vm.mode = .dylib;
            log.info("Zig dylib gameplay script loaded path={s}", .{dylib_path});
            return;
        }

        // 2) 尝试 builtin 指令解析
        vm.builtin.load(resource) catch |err| switch (err) {
            types.ScriptError.CompileError => {
                // 检查是否是 "不支持的内建" → 尝试编译为 dylib
                if (vm.builtin.definition.kind == .none) {
                    vm.current_dylib = vm.compileToDylib(resource) catch {
                        return types.ScriptError.CompileError;
                    };
                    vm.mode = .dylib;
                    return;
                }
                setOwnedMessage(vm.allocator, &vm.error_msg, vm.builtin.getError());
                return err;
            },
            else => {
                setOwnedMessage(vm.allocator, &vm.error_msg, vm.builtin.getError());
                return err;
            },
        };
        vm.mode = .builtin;
    }

    pub fn unload(vm: *Self) void {
        vm.current_dylib = null;
        vm.mode = .none;
        vm.builtin.unload();
        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }

    pub fn deinit(vm: *Self) void {
        vm.unload();
        vm.freeCachedDylibs();
    }

    pub fn createInstance(vm: *Self, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        if (vm.mode == .dylib) {
            if (vm.current_dylib) |library| {
                const instance = vm.allocator.create(types.ScriptInstance) catch return types.ScriptError.LoadError;
                errdefer vm.allocator.destroy(instance);

                const state = vm.allocator.create(ZigDylibInstanceState) catch return types.ScriptError.LoadError;
                errdefer vm.allocator.destroy(state);
                state.* = .{ .library = library };

                instance.* = .{
                    .id = 0,
                    .entity_id = ctx.entity,
                    .script_handle = undefined,
                    .language = .zig,
                    .vtable = .{},
                    .user_data = state,
                    .user_data_size = @sizeOf(ZigDylibInstanceState),
                    .user_data_tag = zig_dylib_user_data_tag,
                    .state = .ready,
                };
                return instance;
            }
            setOwnedMessage(vm.allocator, &vm.error_msg, "no zig dylib loaded");
            return types.ScriptError.NotFound;
        }
        return vm.builtin.createInstance(ctx);
    }

    pub fn destroyInstance(vm: *Self, instance: *types.ScriptInstance) void {
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            if (instance.user_data) |data| {
                vm.allocator.destroy(castUserData(ZigDylibInstanceState, data));
            }
            vm.allocator.destroy(instance);
            return;
        }
        vm.builtin.destroyInstance(instance);
    }

    pub fn callInit(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            return vm.callDylibLifecycle(instance, ctx, .init, 0.0);
        }
        return vm.builtin.callInit(instance, ctx);
    }

    pub fn callUpdate(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            return vm.callDylibLifecycle(instance, ctx, .update, dt);
        }
        return vm.builtin.callUpdate(instance, ctx, dt);
    }

    pub fn callDestroy(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            return vm.callDylibLifecycle(instance, ctx, .destroy, 0.0);
        }
        return vm.builtin.callDestroy(instance, ctx);
    }

    pub fn getError(vm: *Self) []const u8 {
        if (vm.error_msg.len != 0) return vm.error_msg;
        return vm.builtin.getError();
    }

    fn callDylibLifecycle(
        _: *Self,
        instance: *types.ScriptInstance,
        ctx: *context.ScriptContext,
        comptime phase: enum { init, update, destroy },
        dt: f32,
    ) types.ScriptError!void {
        const state = castUserData(ZigDylibInstanceState, instance.user_data orelse return types.ScriptError.NotFound);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;

        // bind API + context into dylib
        state.library.bind(&zig_dylib_host_api, &state.host_context, ctx.entity);

        switch (phase) {
            .init => if (state.library.on_init) |cb| cb(),
            .update => if (state.library.on_update) |cb| cb(dt),
            .destroy => if (state.library.on_destroy) |cb| cb(),
        }
    }

    fn callDylibCollisionEnter(instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        const state = castUserData(ZigDylibInstanceState, instance.user_data orelse return);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;
        state.library.bind(&zig_dylib_host_api, &state.host_context, ctx.entity);
        if (state.library.on_collision_enter) |cb| cb(other);
    }

    fn callDylibCollisionExit(instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        const state = castUserData(ZigDylibInstanceState, instance.user_data orelse return);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;
        state.library.bind(&zig_dylib_host_api, &state.host_context, ctx.entity);
        if (state.library.on_collision_exit) |cb| cb(other);
    }

    fn callDylibTriggerEnter(instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        const state = castUserData(ZigDylibInstanceState, instance.user_data orelse return);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;
        state.library.bind(&zig_dylib_host_api, &state.host_context, ctx.entity);
        if (state.library.on_trigger_enter) |cb| cb(other);
    }

    fn callDylibTriggerExit(instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        const state = castUserData(ZigDylibInstanceState, instance.user_data orelse return);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;
        state.library.bind(&zig_dylib_host_api, &state.host_context, ctx.entity);
        if (state.library.on_trigger_exit) |cb| cb(other);
    }

    fn compileToDylib(vm: *Self, resource: *const script_resource_mod.ScriptResource) !*ZigDylibLibrary {
        const source_path = if (resource.source_path.len != 0) resource.source_path else {
            setOwnedMessage(vm.allocator, &vm.error_msg, "no source path for zig dylib compilation");
            return error.CompileError;
        };

        // 确定输出路径: zig-cache/guava/scripts/<basename>.dylib
        const basename = std.fs.path.stem(source_path);
        const cache_dir = "zig-cache/guava/scripts";

        // 创建缓存目录
        std.fs.cwd().makePath(cache_dir) catch |err| {
            log.err("failed to create script cache directory: {s}", .{@errorName(err)});
        };

        const dylib_ext = switch (@import("builtin").os.tag) {
            .macos => ".dylib",
            .windows => ".dll",
            else => ".so",
        };

        const output_path = std.fmt.allocPrint(vm.allocator, "{s}/{s}{s}", .{ cache_dir, basename, dylib_ext }) catch return error.CompileError;
        defer vm.allocator.free(output_path);

        // 构建参数字符串
        const emit_arg = std.fmt.allocPrint(vm.allocator, "-femit-bin={s}", .{output_path}) catch return error.CompileError;
        defer vm.allocator.free(emit_arg);

        const root_mod_arg = std.fmt.allocPrint(vm.allocator, "-Mroot={s}", .{source_path}) catch return error.CompileError;
        defer vm.allocator.free(root_mod_arg);

        log.info("compiling zig dylib: {s} -> {s}", .{ source_path, output_path });

        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{
                "zig",
                "build-lib",
                "-dynamic",
                "-OReleaseFast",
                "--dep",
                "guava",
                root_mod_arg,
                "-Mguava=src/engine/script/script_api.zig",
                emit_arg,
            },
            .max_output_bytes = 1024 * 1024,
        }) catch {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to execute zig build-lib");
            return error.CompileError;
        };
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .Exited => |code| code,
            else => 1,
        };
        if (exit_code != 0) {
            const output = if (result.stderr.len > 0) result.stderr else result.stdout;
            setOwnedMessage(vm.allocator, &vm.error_msg, output);
            log.err("zig dylib compilation failed:\n{s}", .{output});
            return error.CompileError;
        }

        log.info("zig dylib compiled successfully: {s}", .{output_path});
        return vm.ensureDylibLoaded(output_path);
    }

    fn ensureDylibLoaded(vm: *Self, path: []const u8) !*ZigDylibLibrary {
        // 检查已加载
        for (vm.loaded_dylibs.items) |existing| {
            if (std.mem.eql(u8, existing.path, path)) {
                return existing;
            }
        }

        const path_z = vm.allocator.dupeZ(u8, path) catch return error.CompileError;
        defer vm.allocator.free(path_z);

        var lib = std.DynLib.open(path_z) catch {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to open zig dylib");
            return error.CompileError;
        };

        const bind_fn = lib.lookup(*const fn (*const ZigDylibHostApi, ?*anyopaque, u64) callconv(.c) void, "guava_bind") orelse {
            setOwnedMessage(vm.allocator, &vm.error_msg, "missing guava_bind export in dylib");
            lib.close();
            return error.CompileError;
        };

        const library = vm.allocator.create(ZigDylibLibrary) catch return error.CompileError;
        errdefer vm.allocator.destroy(library);

        const owned_path = vm.allocator.dupe(u8, path) catch return error.CompileError;
        errdefer vm.allocator.free(owned_path);

        library.* = .{
            .path = owned_path,
            .lib = lib,
            .bind = bind_fn,
            .on_init = lib.lookup(*const fn () callconv(.c) void, "guava_on_init"),
            .on_update = lib.lookup(*const fn (f32) callconv(.c) void, "guava_on_update"),
            .on_destroy = lib.lookup(*const fn () callconv(.c) void, "guava_on_destroy"),
            .on_collision_enter = lib.lookup(*const fn (u64) callconv(.c) void, "guava_on_collision_enter"),
            .on_collision_exit = lib.lookup(*const fn (u64) callconv(.c) void, "guava_on_collision_exit"),
            .on_trigger_enter = lib.lookup(*const fn (u64) callconv(.c) void, "guava_on_trigger_enter"),
            .on_trigger_exit = lib.lookup(*const fn (u64) callconv(.c) void, "guava_on_trigger_exit"),
        };

        vm.loaded_dylibs.append(vm.allocator, library) catch return error.CompileError;
        return library;
    }

    fn freeCachedDylibs(vm: *Self) void {
        for (vm.loaded_dylibs.items) |library| {
            library.lib.close();
            vm.allocator.free(library.path);
            vm.allocator.destroy(library);
        }
        vm.loaded_dylibs.deinit(vm.allocator);
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(Self, context_ptr);
        vm.deinit();
        allocator.destroy(vm);
    }

    pub const script_vm_vtable: ScriptVM.VTable = .{
        .load = loadBridge,
        .unload = unloadBridge,
        .createInstance = createInstanceBridge,
        .destroyInstance = destroyInstanceBridge,
        .callInit = callInitBridge,
        .callUpdate = callUpdateBridge,
        .callDestroy = callDestroyBridge,
        .callTriggerEnter = callTriggerEnterBridge,
        .callTriggerExit = callTriggerExitBridge,
        .callCollisionEnter = callCollisionEnterBridge,
        .callCollisionExit = callCollisionExitBridge,
        .getError = getErrorBridge,
        .destroy = destroyContext,
    };

    fn loadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        return Self.load(castContext(Self, context_ptr), resource);
    }
    fn unloadBridge(context_ptr: *anyopaque) void {
        Self.unload(castContext(Self, context_ptr));
    }
    fn createInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return Self.createInstance(castContext(Self, context_ptr), ctx);
    }
    fn destroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
        Self.destroyInstance(castContext(Self, context_ptr), instance);
    }
    fn callInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return Self.callInit(castContext(Self, context_ptr), instance, ctx);
    }
    fn callUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return Self.callUpdate(castContext(Self, context_ptr), instance, ctx, dt);
    }
    fn callDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return Self.callDestroy(castContext(Self, context_ptr), instance, ctx);
    }
    fn callTriggerEnterBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        _ = castContext(Self, context_ptr);
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            callDylibTriggerEnter(instance, ctx, other);
            return;
        }
        if (instance.vtable.onTriggerEnter) |fn_ptr| fn_ptr(ctx, other);
    }
    fn callTriggerExitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        _ = castContext(Self, context_ptr);
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            callDylibTriggerExit(instance, ctx, other);
            return;
        }
        if (instance.vtable.onTriggerExit) |fn_ptr| fn_ptr(ctx, other);
    }
    fn callCollisionEnterBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        _ = castContext(Self, context_ptr);
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            callDylibCollisionEnter(instance, ctx, other);
            return;
        }
        if (instance.vtable.onCollisionEnter) |fn_ptr| fn_ptr(ctx, other);
    }
    fn callCollisionExitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        _ = castContext(Self, context_ptr);
        if (instance.user_data_tag == zig_dylib_user_data_tag) {
            callDylibCollisionExit(instance, ctx, other);
            return;
        }
        if (instance.vtable.onCollisionExit) |fn_ptr| fn_ptr(ctx, other);
    }
    fn getErrorBridge(context_ptr: *anyopaque) []const u8 {
        return Self.getError(castContext(Self, context_ptr));
    }
};

fn resolveZigDylibPath(resource: *const script_resource_mod.ScriptResource) ?[]const u8 {
    if (resource.artifact_path.len != 0 and isSharedLibraryPath(resource.artifact_path)) {
        return resource.artifact_path;
    }
    if (isSharedLibraryPath(resource.source_path)) {
        return resource.source_path;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Zig Dylib Host API 实现
// ---------------------------------------------------------------------------

fn zigDylibActiveContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const host_context: *ZigDylibHostContext = @ptrCast(@alignCast(userdata orelse return null));
    return host_context.active_context;
}

fn zigDylibHostLog(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    std.log.info("[ZigScript:{d}] {s}", .{ ctx_ptr.entity, ptr[0..len] });
}

fn zigDylibHostGetEntityId(userdata: ?*anyopaque) callconv(.c) u64 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    return ctx_ptr.entity;
}

fn zigDylibHostFindEntityByName(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u64 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    return ctx_ptr.findEntityByName(ptr[0..len]) orelse 0;
}

fn zigDylibHostSpawnEntity(userdata: ?*anyopaque) callconv(.c) u64 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const child_id = ctx_ptr.createChild("spawned") catch return 0;
    return child_id;
}

fn zigDylibHostDestroyEntity(userdata: ?*anyopaque, target: u64) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    ctx_ptr.destroyEntity(target);
}

fn zigDylibHostGetPosition(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const pos = ctx_ptr.getPosition() orelse return;
    x.* = pos[0];
    y.* = pos[1];
    z.* = pos[2];
}

fn zigDylibHostSetPosition(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    ctx_ptr.setPosition(.{ x, y, z });
}

fn zigDylibHostGetRotation(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32, w: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const rot = ctx_ptr.getRotation() orelse return;
    x.* = rot[0];
    y.* = rot[1];
    z.* = rot[2];
    w.* = rot[3];
}

fn zigDylibHostSetRotation(userdata: ?*anyopaque, x: f32, y: f32, z: f32, w: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    ctx_ptr.setRotation(.{ x, y, z, w });
}

fn zigDylibHostGetScale(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const s = ctx_ptr.getScale() orelse return;
    x.* = s[0];
    y.* = s[1];
    z.* = s[2];
}

fn zigDylibHostSetScale(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    ctx_ptr.setScale(.{ x, y, z });
}

fn zigDylibHostIsKeyDown(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx_ptr.isKeyDown(key)) 1 else 0;
}

fn zigDylibHostWasKeyPressed(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx_ptr.wasKeyPressed(key)) 1 else 0;
}

fn zigDylibHostWasKeyReleased(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx_ptr.wasKeyReleased(key)) 1 else 0;
}

fn zigDylibHostIsMouseButtonDown(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const input_state = ctx_ptr.input orelse return 0;
    const btn = std.meta.intToEnum(input_mod.MouseButton, @as(u8, @intCast(btn_raw))) catch return 0;
    return if (input_state.isMouseDown(btn)) 1 else 0;
}

fn zigDylibHostGetMousePosition(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const mouse = ctx_ptr.getMousePosition() orelse return;
    x.* = mouse[0];
    y.* = mouse[1];
}

fn zigDylibHostGetMouseDelta(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const delta = ctx_ptr.getMouseDelta() orelse return;
    x.* = delta[0];
    y.* = delta[1];
}

fn zigDylibHostGetMouseWheel(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const wheel = ctx_ptr.getMouseWheel() orelse return;
    x.* = wheel[0];
    y.* = wheel[1];
}

fn zigDylibHostGetDeltaTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0.0;
    return ctx_ptr.delta_time;
}

fn zigDylibHostGetTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0.0;
    return ctx_ptr.time;
}

fn zigDylibHostRaycast(
    userdata: ?*anyopaque,
    ox: f32,
    oy: f32,
    oz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
    max_dist: f32,
    hit_x: *f32,
    hit_y: *f32,
    hit_z: *f32,
    hit_dist: *f32,
    hit_entity: *u64,
) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const hit = ctx_ptr.physicsRaycast(.{ ox, oy, oz }, .{ dx, dy, dz }, max_dist) orelse return 0;
    hit_x.* = hit.position[0];
    hit_y.* = hit.position[1];
    hit_z.* = hit.position[2];
    hit_dist.* = hit.distance;
    hit_entity.* = hit.entity_id;
    return 1;
}

fn zigDylibHostSetLinearVelocity(userdata: ?*anyopaque, target: u64, vx: f32, vy: f32, vz: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const ps = ctx_ptr.physics_state orelse return;
    ps.setBodyLinearVelocity(ctx_ptr.world, target, .{ vx, vy, vz });
}

fn zigDylibHostGetLinearVelocity(userdata: ?*anyopaque, target: u64, vx: *f32, vy: *f32, vz: *f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const ps = ctx_ptr.physics_state orelse return;
    const vel = ps.getBodyLinearVelocity(ctx_ptr.world, target) orelse return;
    vx.* = vel[0];
    vy.* = vel[1];
    vz.* = vel[2];
}

fn zigDylibHostAddImpulse(userdata: ?*anyopaque, target: u64, ix: f32, iy: f32, iz: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const ps = ctx_ptr.physics_state orelse return;
    ps.addBodyImpulse(ctx_ptr.world, target, .{ ix, iy, iz });
}

fn zigDylibHostLoadScene(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    if (ctx_ptr.scene_manager_api) |scene_api| {
        scene_api.load_scene(scene_api.context, ptr[0..len]);
    }
}

fn zigDylibHostIsGamepadConnected(userdata: ?*anyopaque) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const input_state = ctx_ptr.input orelse return 0;
    return if (input_state.gamepad_connected) @as(u32, 1) else @as(u32, 0);
}

fn zigDylibHostIsGamepadButtonDown(userdata: ?*anyopaque, button: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const input_state = ctx_ptr.input orelse return 0;
    const btn = std.meta.intToEnum(input_mod.GamepadButton, @as(u8, @intCast(button))) catch return 0;
    return if (input_state.isGamepadButtonDown(btn)) @as(u32, 1) else @as(u32, 0);
}

fn zigDylibHostWasGamepadButtonPressed(userdata: ?*anyopaque, button: u32) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    const input_state = ctx_ptr.input orelse return 0;
    const btn = std.meta.intToEnum(input_mod.GamepadButton, @as(u8, @intCast(button))) catch return 0;
    return if (input_state.wasGamepadButtonPressed(btn)) @as(u32, 1) else @as(u32, 0);
}

fn zigDylibHostGetGamepadAxis(userdata: ?*anyopaque, axis: u32) callconv(.c) f32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0.0;
    const input_state = ctx_ptr.input orelse return 0.0;
    const ax = std.meta.intToEnum(input_mod.GamepadAxis, @as(u8, @intCast(axis))) catch return 0.0;
    return input_state.getGamepadAxis(ax);
}

// ---------------------------------------------------------------------------
// Audio host functions
// ---------------------------------------------------------------------------

fn zigDylibHostAudioLoadClip(_: ?*anyopaque, path_ptr: [*]const u8, path_len: usize) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    const path = path_ptr[0..path_len];
    const handle = runtime.loadClipBySlice(path) catch return 0;
    return handle;
}

fn zigDylibHostAudioPlay2d(_: ?*anyopaque, clip_id: u32, volume: f32, loop_flag: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return runtime.playClip2d(clip_id, volume, loop_flag != 0) catch return 0;
}

fn zigDylibHostAudioPlay3d(_: ?*anyopaque, clip_id: u32, x: f32, y: f32, z: f32, volume: f32, loop_flag: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return runtime.playClip3d(clip_id, .{ x, y, z }, volume, loop_flag != 0) catch return 0;
}

fn zigDylibHostAudioStop(_: ?*anyopaque, voice_handle: u32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.stopVoice(voice_handle);
}

fn zigDylibHostAudioSetVolume(_: ?*anyopaque, voice_handle: u32, volume: f32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.setVoiceVolume(voice_handle, volume);
}

fn zigDylibHostAudioPause(_: ?*anyopaque, voice_handle: u32, paused: u32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.pauseVoice(voice_handle, paused != 0);
}

fn zigDylibHostAudioIsPlaying(_: ?*anyopaque, voice_handle: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return if (runtime.isVoiceHandleActive(voice_handle)) @as(u32, 1) else @as(u32, 0);
}

// ---------------------------------------------------------------------------
// Animation host functions
// ---------------------------------------------------------------------------

fn zigDylibHostAnimPlay(userdata: ?*anyopaque, entity_id: u64, clip_ptr: [*]const u8, clip_len: usize, blend_duration: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    const clip_asset_id = clip_ptr[0..clip_len];
    const clip_handle = ctx_ptr.world.resources.animationClipHandleByAssetId(clip_asset_id) orelse return;
    animator_system.playClip(ctx_ptr.world, entity_id, clip_handle, .{ .blend_duration_seconds = blend_duration }) catch return;
}

fn zigDylibHostAnimStop(userdata: ?*anyopaque, entity_id: u64) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    if (ctx_ptr.world.id_to_index.get(entity_id)) |idx| {
        var entity = &ctx_ptr.world.entities.items[idx];
        if (entity.animator) |*anim| {
            anim.playing = false;
        }
    }
}

fn zigDylibHostAnimSetSpeed(userdata: ?*anyopaque, entity_id: u64, speed: f32) callconv(.c) void {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return;
    if (ctx_ptr.world.id_to_index.get(entity_id)) |idx| {
        var entity = &ctx_ptr.world.entities.items[idx];
        if (entity.animator) |*anim| {
            anim.speed = speed;
        }
    }
}

fn zigDylibHostAnimIsPlaying(userdata: ?*anyopaque, entity_id: u64) callconv(.c) u32 {
    const ctx_ptr = zigDylibActiveContext(userdata) orelse return 0;
    if (ctx_ptr.world.id_to_index.get(entity_id)) |idx| {
        const entity = ctx_ptr.world.entities.items[idx];
        if (entity.animator) |anim| {
            return if (anim.playing) @as(u32, 1) else @as(u32, 0);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Canvas / UI host functions (no-op stubs — runtime_ui removed)
// Kept for ZigDylibHostApi ABI compatibility with pre-compiled plugins.
// ---------------------------------------------------------------------------

fn zigDylibHostCanvasClear(_: ?*anyopaque) callconv(.c) void {}
fn zigDylibHostCanvasAddText(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: [*]const u8, _: usize, _: u8, _: u8, _: u8, _: u8) callconv(.c) u32 { return 0; }
fn zigDylibHostCanvasAddPanel(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: u8, _: u8, _: u8, _: u8) callconv(.c) u32 { return 0; }
fn zigDylibHostCanvasAddButton(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: [*]const u8, _: usize) callconv(.c) u32 { return 0; }
fn zigDylibHostCanvasAddProgressBar(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: f32) callconv(.c) u32 { return 0; }
fn zigDylibHostCanvasSetText(_: ?*anyopaque, _: u32, _: [*]const u8, _: usize) callconv(.c) void {}
fn zigDylibHostCanvasSetProgress(_: ?*anyopaque, _: u32, _: f32) callconv(.c) void {}
fn zigDylibHostCanvasSetVisible(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {}
fn zigDylibHostCanvasRemoveWidget(_: ?*anyopaque, _: u32) callconv(.c) void {}
fn zigDylibHostCanvasWasButtonClicked(_: ?*anyopaque, _: u32) callconv(.c) u32 { return 0; }

const csharp_native_aot_api_version: u32 = 1;
const csharp_native_aot_user_data_tag: u32 = 0x43534E41;

const CSharpNativeAotHostContext = struct {
    active_context: ?*context.ScriptContext = null,
};

const CSharpNativeAotHostApi = extern struct {
    log: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    find_entity_by_name: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u64,
    get_position: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) u32,
    set_position: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) u32,
    get_rotation: *const fn (?*anyopaque, *f32, *f32, *f32, *f32) callconv(.c) u32,
    set_rotation: *const fn (?*anyopaque, f32, f32, f32, f32) callconv(.c) u32,
    get_scale: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) u32,
    set_scale: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) u32,
    is_key_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_mouse_position: *const fn (?*anyopaque, *f32, *f32) callconv(.c) u32,
    get_delta_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_time_scale: *const fn (?*anyopaque) callconv(.c) f32,
    get_game_state: *const fn (?*anyopaque) callconv(.c) u32,
};

const csharp_native_aot_host_api: CSharpNativeAotHostApi = .{
    .log = csharpNativeAotHostLog,
    .find_entity_by_name = csharpNativeAotHostFindEntityByName,
    .get_position = csharpNativeAotHostGetPosition,
    .set_position = csharpNativeAotHostSetPosition,
    .get_rotation = csharpNativeAotHostGetRotation,
    .set_rotation = csharpNativeAotHostSetRotation,
    .get_scale = csharpNativeAotHostGetScale,
    .set_scale = csharpNativeAotHostSetScale,
    .is_key_down = csharpNativeAotHostIsKeyDown,
    .was_key_pressed = csharpNativeAotHostWasKeyPressed,
    .get_mouse_position = csharpNativeAotHostGetMousePosition,
    .get_delta_time = csharpNativeAotHostGetDeltaTime,
    .get_time_scale = csharpNativeAotHostGetTimeScale,
    .get_game_state = csharpNativeAotHostGetGameState,
};

const CSharpNativeAotLibrary = struct {
    path: []u8,
    lib: std.DynLib,
    api_version: *const fn () callconv(.c) u32,
    create_instance: *const fn (*const CSharpNativeAotHostApi, ?*anyopaque, u64) callconv(.c) ?*anyopaque,
    destroy_instance: *const fn (?*anyopaque) callconv(.c) void,
    on_init: ?*const fn (?*anyopaque) callconv(.c) void,
    on_update: ?*const fn (?*anyopaque, f32) callconv(.c) void,
    on_destroy: ?*const fn (?*anyopaque) callconv(.c) void,
};

const CSharpNativeAotInstanceState = struct {
    library: *const CSharpNativeAotLibrary,
    host_context: CSharpNativeAotHostContext = .{},
    guest_instance: ?*anyopaque = null,
};

pub const CSharpVM = struct {
    allocator: std.mem.Allocator,
    builtin: CSharpBuiltinVM,
    loaded_native_libraries: std.ArrayList(*CSharpNativeAotLibrary) = .empty,
    current_native_library: ?*CSharpNativeAotLibrary = null,
    error_msg: []u8 = &.{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .builtin = CSharpBuiltinVM.init(allocator),
        };
    }

    pub fn load(vm: *Self, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        if (resource.language != .csharp) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "script language does not match CSharpVM");
            return types.ScriptError.InvalidLanguage;
        }

        vm.current_native_library = null;
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        vm.builtin.unload();

        if (resolveCSharpNativeAotPath(resource)) |library_path| {
            vm.current_native_library = try vm.ensureNativeLibrary(library_path);
            log.info("C# NativeAOT gameplay library loaded path={s}", .{library_path});
            return;
        }

        vm.builtin.load(resource) catch |err| {
            setOwnedMessage(vm.allocator, &vm.error_msg, vm.builtin.getError());
            return err;
        };
    }

    pub fn unload(vm: *Self) void {
        vm.current_native_library = null;
        vm.builtin.unload();
        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }

    pub fn deinit(vm: *Self) void {
        vm.unload();
        vm.freeCachedLibraries();
    }

    pub fn createInstance(vm: *Self, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        if (vm.current_native_library) |library| {
            const instance = try vm.allocator.create(types.ScriptInstance);
            errdefer vm.allocator.destroy(instance);

            const state = try vm.allocator.create(CSharpNativeAotInstanceState);
            errdefer vm.allocator.destroy(state);
            state.* = .{ .library = library };
            state.host_context.active_context = ctx;
            defer state.host_context.active_context = null;

            state.guest_instance = library.create_instance(&csharp_native_aot_host_api, &state.host_context, ctx.entity);
            if (state.guest_instance == null) {
                setOwnedMessage(vm.allocator, &vm.error_msg, "C# NativeAOT create_instance returned null");
                return types.ScriptError.LoadError;
            }

            instance.* = .{
                .id = 0,
                .entity_id = ctx.entity,
                .script_handle = undefined,
                .language = .csharp,
                .vtable = .{},
                .user_data = state,
                .user_data_size = @sizeOf(CSharpNativeAotInstanceState),
                .user_data_tag = csharp_native_aot_user_data_tag,
                .state = .ready,
            };
            return instance;
        }

        return vm.builtin.createInstance(ctx);
    }

    pub fn destroyInstance(vm: *Self, instance: *types.ScriptInstance) void {
        if (instance.user_data_tag == csharp_native_aot_user_data_tag) {
            const state = castUserData(CSharpNativeAotInstanceState, instance.user_data.?);
            state.library.destroy_instance(state.guest_instance);
            vm.allocator.destroy(state);
            vm.allocator.destroy(instance);
            return;
        }
        vm.builtin.destroyInstance(instance);
    }

    pub fn callInit(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        if (instance.user_data_tag == csharp_native_aot_user_data_tag) {
            return vm.callNativeLifecycle(instance, ctx, .init, null);
        }
        return vm.builtin.callInit(instance, ctx);
    }

    pub fn callUpdate(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        if (instance.user_data_tag == csharp_native_aot_user_data_tag) {
            return vm.callNativeLifecycle(instance, ctx, .update, dt);
        }
        return vm.builtin.callUpdate(instance, ctx, dt);
    }

    pub fn callDestroy(vm: *Self, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        if (instance.user_data_tag == csharp_native_aot_user_data_tag) {
            return vm.callNativeLifecycle(instance, ctx, .destroy, null);
        }
        return vm.builtin.callDestroy(instance, ctx);
    }

    pub fn getError(vm: *Self) []const u8 {
        if (vm.error_msg.len != 0) {
            return vm.error_msg;
        }
        return vm.builtin.getError();
    }

    fn callNativeLifecycle(
        vm: *Self,
        instance: *types.ScriptInstance,
        ctx: *context.ScriptContext,
        comptime phase: enum { init, update, destroy },
        dt: ?f32,
    ) types.ScriptError!void {
        const state = castUserData(CSharpNativeAotInstanceState, instance.user_data orelse return types.ScriptError.NotFound);
        state.host_context.active_context = ctx;
        defer state.host_context.active_context = null;

        switch (phase) {
            .init => if (state.library.on_init) |callback| callback(state.guest_instance),
            .update => if (state.library.on_update) |callback| callback(state.guest_instance, dt orelse 0.0),
            .destroy => if (state.library.on_destroy) |callback| callback(state.guest_instance),
        }
        _ = vm;
    }

    fn ensureNativeLibrary(vm: *Self, path: []const u8) types.ScriptError!*CSharpNativeAotLibrary {
        if (vm.findNativeLibrary(path)) |library| {
            return library;
        }

        var lib = std.DynLib.open(path) catch {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to open C# NativeAOT shared library");
            return types.ScriptError.LoadError;
        };

        const library = try vm.allocator.create(CSharpNativeAotLibrary);
        errdefer vm.allocator.destroy(library);

        const owned_path = try vm.allocator.dupe(u8, path);
        errdefer vm.allocator.free(owned_path);

        library.* = .{
            .path = owned_path,
            .lib = lib,
            .api_version = lookupRequired(&lib, *const fn () callconv(.c) u32, "guava_csharp_api_version") orelse {
                setOwnedMessage(vm.allocator, &vm.error_msg, "missing guava_csharp_api_version export");
                return types.ScriptError.LoadError;
            },
            .create_instance = lookupRequired(&lib, *const fn (*const CSharpNativeAotHostApi, ?*anyopaque, u64) callconv(.c) ?*anyopaque, "guava_csharp_create_instance") orelse {
                setOwnedMessage(vm.allocator, &vm.error_msg, "missing guava_csharp_create_instance export");
                return types.ScriptError.LoadError;
            },
            .destroy_instance = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "guava_csharp_destroy_instance") orelse {
                setOwnedMessage(vm.allocator, &vm.error_msg, "missing guava_csharp_destroy_instance export");
                return types.ScriptError.LoadError;
            },
            .on_init = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "guava_csharp_on_init"),
            .on_update = lib.lookup(*const fn (?*anyopaque, f32) callconv(.c) void, "guava_csharp_on_update"),
            .on_destroy = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "guava_csharp_on_destroy"),
        };

        if (library.api_version() != csharp_native_aot_api_version) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "unsupported C# NativeAOT API version");
            return types.ScriptError.LoadError;
        }

        try vm.loaded_native_libraries.append(vm.allocator, library);
        return library;
    }

    fn findNativeLibrary(vm: *Self, path: []const u8) ?*CSharpNativeAotLibrary {
        for (vm.loaded_native_libraries.items) |library| {
            if (std.mem.eql(u8, library.path, path)) {
                return library;
            }
        }
        return null;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(Self, context_ptr);
        vm.deinit();
        allocator.destroy(vm);
    }

    fn freeCachedLibraries(vm: *Self) void {
        for (vm.loaded_native_libraries.items) |library| {
            vm.allocator.free(library.path);
            vm.allocator.destroy(library);
        }
        vm.loaded_native_libraries.deinit(vm.allocator);
    }

    pub const script_vm_vtable: ScriptVM.VTable = .{
        .load = loadBridge,
        .unload = unloadBridge,
        .createInstance = createInstanceBridge,
        .destroyInstance = destroyInstanceBridge,
        .callInit = callInitBridge,
        .callUpdate = callUpdateBridge,
        .callDestroy = callDestroyBridge,
        .getError = getErrorBridge,
        .destroy = destroyContext,
    };

    fn loadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        return Self.load(castContext(Self, context_ptr), resource);
    }

    fn unloadBridge(context_ptr: *anyopaque) void {
        Self.unload(castContext(Self, context_ptr));
    }

    fn createInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return Self.createInstance(castContext(Self, context_ptr), ctx);
    }

    fn destroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
        Self.destroyInstance(castContext(Self, context_ptr), instance);
    }

    fn callInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return Self.callInit(castContext(Self, context_ptr), instance, ctx);
    }

    fn callUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return Self.callUpdate(castContext(Self, context_ptr), instance, ctx, dt);
    }

    fn callDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return Self.callDestroy(castContext(Self, context_ptr), instance, ctx);
    }

    fn getErrorBridge(context_ptr: *anyopaque) []const u8 {
        return Self.getError(castContext(Self, context_ptr));
    }
};

fn createWrappedVM(comptime T: type, allocator: std.mem.Allocator, instance_value: T) !*ScriptVM {
    const script_vm = try allocator.create(ScriptVM);
    errdefer allocator.destroy(script_vm);

    const vm = try allocator.create(T);
    errdefer allocator.destroy(vm);
    vm.* = instance_value;

    script_vm.* = .{
        .context = vm,
        .vtable = &T.script_vm_vtable,
    };
    return script_vm;
}

pub fn createGameplayVM(language: types.ScriptLanguage, allocator: std.mem.Allocator) types.ScriptError!*ScriptVM {
    return switch (language) {
        .zig => createWrappedVM(ZigVM, allocator, ZigVM.init(allocator)),
        .csharp => createWrappedVM(CSharpVM, allocator, CSharpVM.init(allocator)),
    };
}

/// 获取指定语言的虚拟机
pub fn createVM(language: types.ScriptLanguage, allocator: std.mem.Allocator) types.ScriptError!*ScriptVM {
    return createGameplayVM(language, allocator);
}

fn resolveCSharpNativeAotPath(resource: *const script_resource_mod.ScriptResource) ?[]const u8 {
    if (resource.artifact_path.len != 0 and isSharedLibraryPath(resource.artifact_path)) {
        return resource.artifact_path;
    }
    if (isSharedLibraryPath(resource.source_path)) {
        return resource.source_path;
    }
    return null;
}

fn isSharedLibraryPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".dll") or
        std.mem.endsWith(u8, path, ".so") or
        std.mem.endsWith(u8, path, ".dylib");
}

fn lookupRequired(lib: *std.DynLib, comptime T: type, name: [:0]const u8) ?T {
    return lib.lookup(T, name);
}

fn csharpNativeAotActiveContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const host_context: *CSharpNativeAotHostContext = @ptrCast(@alignCast(userdata orelse return null));
    return host_context.active_context;
}

fn csharpNativeAotHostLog(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return;
    std.log.info("[CSharpScript:{d}] {s}", .{ ctx.entity, ptr[0..len] });
}

fn csharpNativeAotHostFindEntityByName(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u64 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    return ctx.findEntityByName(ptr[0..len]) orelse 0;
}

fn csharpNativeAotHostGetPosition(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const position = ctx.getPosition() orelse return 0;
    x.* = position[0];
    y.* = position[1];
    z.* = position[2];
    return 1;
}

fn csharpNativeAotHostSetPosition(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    ctx.setPosition(.{ x, y, z });
    return 1;
}

fn csharpNativeAotHostGetRotation(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32, w: *f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const rotation = ctx.getRotation() orelse return 0;
    x.* = rotation[0];
    y.* = rotation[1];
    z.* = rotation[2];
    w.* = rotation[3];
    return 1;
}

fn csharpNativeAotHostSetRotation(userdata: ?*anyopaque, x: f32, y: f32, z: f32, w: f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    ctx.setRotation(.{ x, y, z, w });
    return 1;
}

fn csharpNativeAotHostGetScale(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const scale = ctx.getScale() orelse return 0;
    x.* = scale[0];
    y.* = scale[1];
    z.* = scale[2];
    return 1;
}

fn csharpNativeAotHostSetScale(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    ctx.setScale(.{ x, y, z });
    return 1;
}

fn csharpNativeAotHostIsKeyDown(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx.isKeyDown(key)) 1 else 0;
}

fn csharpNativeAotHostWasKeyPressed(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx.wasKeyPressed(key)) 1 else 0;
}

fn csharpNativeAotHostGetMousePosition(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    const mouse = ctx.getMousePosition() orelse return 0;
    x.* = mouse[0];
    y.* = mouse[1];
    return 1;
}

fn csharpNativeAotHostGetDeltaTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0.0;
    return ctx.delta_time;
}

fn csharpNativeAotHostGetTimeScale(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 1.0;
    return ctx.time_scale;
}

fn csharpNativeAotHostGetGameState(userdata: ?*anyopaque) callconv(.c) u32 {
    const ctx = csharpNativeAotActiveContext(userdata) orelse return 0;
    return ctx.game_state;
}

fn clearOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8) void {
    if (slot.*.len != 0) {
        allocator.free(slot.*);
        slot.* = &.{};
    }
}

fn setOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8, message: []const u8) void {
    clearOwnedMessage(allocator, slot);
    slot.* = allocator.dupe(u8, message) catch &.{};
}

fn parseScriptDefinition(source: []const u8) !ScriptDefinition {
    var definition = ScriptDefinition{};
    var found_directive = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const payload = directivePayload(line) orelse continue;
        found_directive = true;

        var tokens = std.mem.tokenizeScalar(u8, payload, ' ');
        while (tokens.next()) |token| {
            try applyDirectiveToken(&definition, token);
        }
    }

    if (!found_directive) {
        if (inferLegacyDefinition(source)) |legacy| {
            return legacy;
        }
        return error.UnsupportedBuiltinScript;
    }

    if (definition.kind == .none) {
        return error.InvalidDirective;
    }
    return definition;
}

fn directivePayload(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "//!guava")) {
        return std.mem.trimLeft(u8, line["//!guava".len..], " \t");
    }
    if (std.mem.startsWith(u8, line, "// guava:")) {
        return std.mem.trimLeft(u8, line["// guava:".len..], " \t");
    }
    return null;
}

fn applyDirectiveToken(definition: *ScriptDefinition, token: []const u8) !void {
    if (token.len == 0) {
        return;
    }

    const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidDirective;
    const key = token[0..eq_index];
    const value = token[eq_index + 1 ..];

    if (std.mem.eql(u8, key, "builtin")) {
        definition.kind = try parseBuiltinKind(value);
        return;
    }

    switch (definition.kind) {
        .rotate => try applyRotateDirective(definition, key, value),
        .patrol => try applyPatrolDirective(definition, key, value),
        .fly_camera => try applyFlyDirective(definition, key, value),
        .fps_controller => try applyFpsDirective(definition, key, value),
        .none => return error.InvalidDirective,
    }
}

fn applyRotateDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "axis")) {
        definition.rotate_axis = try parseVec3Value(value);
    } else if (std.mem.eql(u8, key, "speed_deg")) {
        definition.rotate_speed_radians = try parseFloatValue(value) * (std.math.pi / 180.0);
    } else if (std.mem.eql(u8, key, "speed_rad")) {
        definition.rotate_speed_radians = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "local")) {
        definition.rotate_local_space = try parseBoolValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn applyPatrolDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "speed")) {
        definition.patrol_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "arrival")) {
        definition.patrol_arrival_threshold = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "loop")) {
        definition.patrol_loop = try parseBoolValue(value);
    } else if (std.mem.eql(u8, key, "wait")) {
        definition.patrol_wait_at_waypoint = try parseBoolValue(value);
    } else if (std.mem.eql(u8, key, "wait_time")) {
        definition.patrol_wait_time = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "waypoints")) {
        var count: usize = 0;
        var waypoint_it = std.mem.splitScalar(u8, value, ';');
        while (waypoint_it.next()) |waypoint| {
            if (waypoint.len == 0) {
                continue;
            }
            if (count >= definition.patrol_waypoints.len) {
                return error.InvalidDirective;
            }
            definition.patrol_waypoints[count] = try parseVec3Value(waypoint);
            count += 1;
        }
        definition.patrol_waypoint_count = @intCast(count);
    } else {
        return error.InvalidDirective;
    }
}

fn applyFlyDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "move_speed")) {
        definition.fly_move_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "mouse_sensitivity")) {
        definition.fly_mouse_sensitivity = try parseFloatValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn applyFpsDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "move_speed")) {
        definition.fps_move_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "mouse_sensitivity")) {
        definition.fps_mouse_sensitivity = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "gravity")) {
        definition.fps_gravity = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "jump_velocity")) {
        definition.fps_jump_velocity = try parseFloatValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn parseBuiltinKind(value: []const u8) !BuiltinKind {
    if (std.mem.eql(u8, value, "rotate")) return .rotate;
    if (std.mem.eql(u8, value, "patrol")) return .patrol;
    if (std.mem.eql(u8, value, "fly_camera")) return .fly_camera;
    if (std.mem.eql(u8, value, "fps_controller")) return .fps_controller;
    return error.InvalidDirective;
}

fn parseBoolValue(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidDirective;
}

fn parseFloatValue(value: []const u8) !f32 {
    return std.fmt.parseFloat(f32, value) catch error.InvalidDirective;
}

fn parseVec3Value(value: []const u8) !components.Vec3 {
    if (std.mem.eql(u8, value, "x")) return .{ 1.0, 0.0, 0.0 };
    if (std.mem.eql(u8, value, "y")) return .{ 0.0, 1.0, 0.0 };
    if (std.mem.eql(u8, value, "z")) return .{ 0.0, 0.0, 1.0 };

    var parts = std.mem.splitScalar(u8, value, ',');
    const x = parts.next() orelse return error.InvalidDirective;
    const y = parts.next() orelse return error.InvalidDirective;
    const z = parts.next() orelse return error.InvalidDirective;
    if (parts.next() != null) return error.InvalidDirective;

    return .{
        try parseFloatValue(x),
        try parseFloatValue(y),
        try parseFloatValue(z),
    };
}

fn inferLegacyDefinition(source: []const u8) ?ScriptDefinition {
    if (std.mem.indexOf(u8, source, "RotatorData") != null or std.mem.indexOf(u8, source, "RotateScript") != null) {
        return .{
            .kind = .rotate,
            .rotate_axis = .{ 0.0, 1.0, 0.0 },
            .rotate_speed_radians = std.math.pi * 0.25,
        };
    }
    if (std.mem.indexOf(u8, source, "PatrolScript") != null) {
        return .{
            .kind = .patrol,
        };
    }
    if (std.mem.indexOf(u8, source, "CameraData") != null) {
        return .{
            .kind = .fly_camera,
        };
    }
    if (std.mem.indexOf(u8, source, "FpsControllerScript") != null) {
        return .{
            .kind = .fps_controller,
        };
    }
    return null;
}

fn vtableForKind(kind: BuiltinKind) types.ScriptVTable {
    return switch (kind) {
        .rotate => .{
            .onInit = rotateOnInit,
            .onUpdate = rotateOnUpdate,
            .onDestroy = rotateOnDestroy,
        },
        .patrol => .{
            .onInit = patrolOnInit,
            .onUpdate = patrolOnUpdate,
            .onDestroy = patrolOnDestroy,
        },
        .fly_camera => .{
            .onInit = flyCameraOnInit,
            .onUpdate = flyCameraOnUpdate,
            .onDestroy = flyCameraOnDestroy,
        },
        .fps_controller => .{
            .onInit = fpsControllerOnInit,
            .onUpdate = fpsControllerOnUpdate,
            .onDestroy = fpsControllerOnDestroy,
        },
        .none => .{},
    };
}

fn rotateOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Rotate script initialized");
}

fn rotateOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(RotateState, ctx.instance) orelse return;
    const current = ctx.getRotation() orelse quat.identity();
    const delta = quat.fromAxisAngle(state.axis, state.speed_radians * dt);
    const next = if (state.local_space)
        quat.normalize(quat.mul(current, delta))
    else
        quat.normalize(quat.mul(delta, current));
    ctx.setRotation(next);
}

fn rotateOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Rotate script destroyed");
}

fn patrolOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Patrol script initialized");
}

fn patrolOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(PatrolState, ctx.instance) orelse return;
    if (state.waypoint_count == 0) {
        return;
    }

    if (state.wait_at_waypoint and state.wait_timer > 0.0) {
        state.wait_timer = @max(0.0, state.wait_timer - dt);
        return;
    }

    const current_position = ctx.getPosition() orelse return;
    var target = state.waypoints[state.current_waypoint];
    var to_target = vec3.sub(target, current_position);
    var distance = vec3.length(to_target);

    while (distance <= state.arrival_threshold) {
        if (state.wait_at_waypoint) {
            state.wait_timer = state.wait_time;
            return;
        }

        const previous_waypoint = state.current_waypoint;
        if (state.current_waypoint + 1 < state.waypoint_count) {
            state.current_waypoint += 1;
        } else if (state.loop) {
            state.current_waypoint = 0;
        } else {
            return;
        }

        if (state.current_waypoint == previous_waypoint) {
            return;
        }

        target = state.waypoints[state.current_waypoint];
        to_target = vec3.sub(target, current_position);
        distance = vec3.length(to_target);
    }

    const step = @min(state.speed * dt, distance);
    const direction = vec3.normalize(to_target);
    ctx.setPosition(vec3.add(current_position, vec3.scale(direction, step)));
}

fn patrolOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Patrol script destroyed");
}

fn flyCameraOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Fly camera script initialized");
}

fn flyCameraOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(FlyCameraState, ctx.instance) orelse return;

    if (ctx.getMousePosition()) |mouse_pos| {
        updateLookAngles(&state.first_mouse, &state.last_mouse_x, &state.last_mouse_y, &state.pitch, &state.yaw, state.mouse_sensitivity, mouse_pos);
    }

    const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
    const right = vec3.rightFromYaw(state.yaw);

    var movement: components.Vec3 = .{ 0.0, 0.0, 0.0 };
    if (ctx.isKeyDown(input_mod.Key.w)) movement = vec3.add(movement, forward);
    if (ctx.isKeyDown(input_mod.Key.s)) movement = vec3.sub(movement, forward);
    if (ctx.isKeyDown(input_mod.Key.d)) movement = vec3.add(movement, right);
    if (ctx.isKeyDown(input_mod.Key.a)) movement = vec3.sub(movement, right);
    if (ctx.isKeyDown(input_mod.Key.e)) movement[1] += 1.0;
    if (ctx.isKeyDown(input_mod.Key.q)) movement[1] -= 1.0;

    if (vec3.length(movement) > 0.0001) {
        const current_position = ctx.getPosition() orelse .{ 0.0, 0.0, 0.0 };
        const direction = vec3.normalize(movement);
        ctx.setPosition(vec3.add(current_position, vec3.scale(direction, state.move_speed * dt)));
    }

    ctx.setRotation(quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }));
}

fn flyCameraOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Fly camera script destroyed");
}

fn fpsControllerOnInit(ctx: *context.ScriptContext) void {
    ctx.log("FPS controller script initialized");
}

fn fpsControllerOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(FpsControllerState, ctx.instance) orelse return;

    if (ctx.getMousePosition()) |mouse_pos| {
        updateLookAngles(&state.first_mouse, &state.last_mouse_x, &state.last_mouse_y, &state.pitch, &state.yaw, state.mouse_sensitivity, mouse_pos);
    }

    var position = ctx.getPosition() orelse .{ 0.0, 0.0, 0.0 };
    const forward = vec3.forwardFromAngles(state.yaw, 0.0);
    const right = vec3.rightFromYaw(state.yaw);

    var planar: components.Vec3 = .{ 0.0, 0.0, 0.0 };
    if (ctx.isKeyDown(input_mod.Key.w)) planar = vec3.add(planar, forward);
    if (ctx.isKeyDown(input_mod.Key.s)) planar = vec3.sub(planar, forward);
    if (ctx.isKeyDown(input_mod.Key.d)) planar = vec3.add(planar, right);
    if (ctx.isKeyDown(input_mod.Key.a)) planar = vec3.sub(planar, right);

    if (vec3.length(planar) > 0.0001) {
        const direction = vec3.normalize(planar);
        position = vec3.add(position, vec3.scale(direction, state.move_speed * dt));
    }

    state.vertical_velocity += state.gravity * dt;
    if (ctx.wasKeyPressed(input_mod.Key.space) and state.is_grounded) {
        state.vertical_velocity = state.jump_velocity;
        state.is_grounded = false;
    }

    position[1] += state.vertical_velocity * dt;
    if (position[1] <= 0.0) {
        position[1] = 0.0;
        state.vertical_velocity = 0.0;
        state.is_grounded = true;
    } else {
        state.is_grounded = false;
    }

    ctx.setPosition(position);
    ctx.setRotation(quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }));
}

fn fpsControllerOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("FPS controller script destroyed");
}

fn initializeLookAnglesFromTransform(out_pitch: *f32, out_yaw: *f32, ctx: *context.ScriptContext) void {
    if (ctx.getRotation()) |rotation| {
        const euler = quat.toEuler(rotation);
        out_pitch.* = euler[0];
        out_yaw.* = euler[1];
    }
}

fn updateLookAngles(
    first_mouse: *bool,
    last_mouse_x: *f32,
    last_mouse_y: *f32,
    pitch: *f32,
    yaw: *f32,
    sensitivity: f32,
    mouse_pos: [2]f32,
) void {
    if (first_mouse.*) {
        last_mouse_x.* = mouse_pos[0];
        last_mouse_y.* = mouse_pos[1];
        first_mouse.* = false;
        return;
    }

    const delta_x = mouse_pos[0] - last_mouse_x.*;
    const delta_y = last_mouse_y.* - mouse_pos[1];
    last_mouse_x.* = mouse_pos[0];
    last_mouse_y.* = mouse_pos[1];

    yaw.* += delta_x * sensitivity;
    pitch.* = std.math.clamp(pitch.* + delta_y * sensitivity, -std.math.pi * 0.49, std.math.pi * 0.49);
}

fn castUserData(comptime T: type, data: *anyopaque) *T {
    return @ptrCast(@alignCast(data));
}

fn castInstanceState(comptime T: type, instance: *types.ScriptInstance) ?*T {
    const data = instance.user_data orelse return null;
    if (builtinKindFromTag(instance.user_data_tag) != builtinKindForState(T)) {
        return null;
    }
    return castUserData(T, data);
}

fn builtinKindFromTag(tag: u32) BuiltinKind {
    return std.meta.intToEnum(BuiltinKind, tag) catch .none;
}

fn builtinKindForState(comptime T: type) BuiltinKind {
    return switch (T) {
        RotateState => .rotate,
        PatrolState => .patrol,
        FlyCameraState => .fly_camera,
        FpsControllerState => .fps_controller,
        else => .none,
    };
}

fn castContext(comptime T: type, context_ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(context_ptr));
}

fn zigLoadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
    return ZigVM.load(castContext(ZigVM, context_ptr), resource);
}

fn zigUnloadBridge(context_ptr: *anyopaque) void {
    ZigVM.unload(castContext(ZigVM, context_ptr));
}

fn zigCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return ZigVM.createInstance(castContext(ZigVM, context_ptr), ctx);
}

fn zigDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    ZigVM.destroyInstance(castContext(ZigVM, context_ptr), instance);
}

fn zigCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return ZigVM.callInit(castContext(ZigVM, context_ptr), instance, ctx);
}

fn zigCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return ZigVM.callUpdate(castContext(ZigVM, context_ptr), instance, ctx, dt);
}

fn zigCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return ZigVM.callDestroy(castContext(ZigVM, context_ptr), instance, ctx);
}

fn zigGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return ZigVM.getError(castContext(ZigVM, context_ptr));
}

fn csharpLoadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
    return CSharpVM.load(castContext(CSharpVM, context_ptr), resource);
}

fn csharpUnloadBridge(context_ptr: *anyopaque) void {
    CSharpVM.unloadStub(castContext(CSharpVM, context_ptr));
}

fn csharpCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return CSharpVM.createInstanceStub(castContext(CSharpVM, context_ptr), ctx);
}

fn csharpDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    CSharpVM.destroyInstanceStub(castContext(CSharpVM, context_ptr), instance);
}

fn csharpCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return CSharpVM.callInitStub(castContext(CSharpVM, context_ptr), instance, ctx);
}

fn csharpCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return CSharpVM.callUpdateStub(castContext(CSharpVM, context_ptr), instance, ctx, dt);
}

fn csharpCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return CSharpVM.callDestroyStub(castContext(CSharpVM, context_ptr), instance, ctx);
}

fn csharpGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return CSharpVM.getError(castContext(CSharpVM, context_ptr));
}

test "zig vm rotate builtin updates entity rotation" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "RotateMe" });
    const entity = world.getEntity(entity_id).?;
    entity.local_transform.rotation = quat.identity();

    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "//!guava builtin=rotate axis=y speed_deg=90 local=true\n",
        .language = .zig,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callUpdate(instance, &ctx, 1.0);
    try vm.callUpdate(instance, &ctx, 1.0);

    const rotated = world.getEntity(entity_id).?.local_transform.rotation;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated[3], 0.0001);
}

test "zig vm patrol builtin moves toward next waypoint" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{
        .name = "Patrol",
        .local_transform = .{ .translation = .{ 0.0, 0.0, 0.0 } },
    });

    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "//!guava builtin=patrol speed=2.0 waypoints=0,0,0;2,0,0\n",
        .language = .zig,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callUpdate(instance, &ctx, 1.0);

    const moved = world.getEntity(entity_id).?.local_transform.translation;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), moved[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), moved[2], 0.0001);
}

test "zig vm rejects source without builtin directive" {
    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "pub fn onUpdate() void {}",
        .language = .zig,
    };
    try std.testing.expectError(types.ScriptError.CompileError, vm.load(&resource));
    try std.testing.expect(vm.getError().len != 0);
}

test "csharp vm gameplay builtin fallback updates entity rotation" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "RotateMeCs" });
    world.getEntity(entity_id).?.local_transform.rotation = quat.identity();

    var vm = CSharpVM.init(std.testing.allocator);
    defer vm.deinit();

    const resource = script_resource_mod.ScriptResource{
        .source = "//!guava builtin=rotate axis=y speed_deg=90 local=true\n",
        .language = .csharp,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callUpdate(instance, &ctx, 1.0);
    try vm.callUpdate(instance, &ctx, 1.0);

    const rotated = world.getEntity(entity_id).?.local_transform.rotation;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated[3], 0.0001);
}

test "csharp vm prefers nativeaot artifact path when present" {
    const resource = script_resource_mod.ScriptResource{
        .source = "",
        .language = .csharp,
        .source_path = "scripts/player.cs",
        .artifact_path = "build/native/player.dylib",
    };

    try std.testing.expectEqualStrings("build/native/player.dylib", resolveCSharpNativeAotPath(&resource).?);
}

test "csharp nativeaot shared library drives entity movement" {
    if (!shouldRunNativeAotIntegrationTests()) return error.SkipZigTest;

    const library_path = try publishNativeAotMoverLibrary(std.testing.allocator);
    defer std.testing.allocator.free(library_path);

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{
        .name = "NativeAotMover",
        .local_transform = .{ .translation = .{ 0.0, 0.0, 0.0 } },
    });

    var vm = CSharpVM.init(std.testing.allocator);
    defer vm.deinit();

    const resource = script_resource_mod.ScriptResource{
        .source = "",
        .language = .csharp,
        .artifact_path = library_path,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
        .delta_time = 1.0,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callInit(instance, &ctx);
    try vm.callUpdate(instance, &ctx, 1.0);

    const moved = world.getEntity(entity_id).?.local_transform.translation;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), moved[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), moved[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), moved[2], 0.0001);
}

fn shouldRunNativeAotIntegrationTests() bool {
    const flag = std.process.getEnvVarOwned(std.testing.allocator, "GUAVA_RUN_NATIVEAOT_TESTS") catch return false;
    defer std.testing.allocator.free(flag);
    return std.mem.eql(u8, flag, "1");
}

fn publishNativeAotMoverLibrary(allocator: std.mem.Allocator) ![]u8 {
    return csharp_toolchain.publishNativeAotLibraryAlloc(allocator, .{
        .project_path = "examples/csharp/nativeaot_mover/GuavaNativeAotMover.csproj",
    }) catch |err| switch (err) {
        error.DotnetNotFound, error.UnsupportedPlatform => error.SkipZigTest,
        else => err,
    };
}
